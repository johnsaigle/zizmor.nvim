local M = {}

local namespace = nil

-- Default configuration
local defaults = {
	-- Enable the plugin by default
	enabled = true,
	severity_map = {
		High = vim.diagnostic.severity.ERROR,
		Medium = vim.diagnostic.severity.WARN,
		Low = vim.diagnostic.severity.INFO,
		Informational = vim.diagnostic.severity.HINT,
	},
	-- Default severity if not specified
	default_severity = vim.diagnostic.severity.WARN,
	-- Additional zizmor CLI arguments
	extra_args = {},
	-- Filetypes to scan
	filetypes = { "yaml", "yml" },
}

M.config = vim.deepcopy(defaults)

-- Debug function to print current config.
function M.print_config()
	local config_lines = { "Current zizmor.nvim configuration:" }
	for k, v in pairs(M.config) do
		if type(v) == "table" then
			table.insert(config_lines, string.format("%s: %s", k, vim.inspect(v)))
		else
			table.insert(config_lines, string.format("%s: %s", k, tostring(v)))
		end
	end
	vim.notify(table.concat(config_lines, "\n"), vim.log.levels.INFO)
end

function M.clear_diagnostics()
	if not namespace then
		namespace = vim.api.nvim_create_namespace("zizmor")
	end

	-- Get all buffers
	local bufs = vim.api.nvim_list_bufs()
	for _, buf in ipairs(bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.diagnostic.reset(namespace, buf)
		end
	end
end

-- Function to toggle the plugin. Clears current diagnostics.
function M.toggle()
	if not namespace then
		namespace = vim.api.nvim_create_namespace("zizmor")
	end

	-- Toggle the enabled state
	M.config.enabled = not M.config.enabled
	if not M.config.enabled then
		-- Clear all diagnostics when disabling
		M.clear_diagnostics()
		vim.notify("Zizmor diagnostics disabled", vim.log.levels.INFO)
	else
		vim.notify("Zizmor diagnostics enabled", vim.log.levels.INFO)
		M.zizmor()
	end
end

-- Check if a file is a GitHub Actions workflow file
local function is_workflow_file(filepath)
	return filepath:match("%.github/workflows/.*%.ya?ml$") ~= nil
end

-- Check if we've already seen this diagnostic to avoid duplicates
-- Zizmor can output the same finding multiple times with different locations
local function create_diagnostic_key(result)
	-- Use ident + primary location to deduplicate
	-- This follows the clippy pattern where the same error can appear in multiple locations
	local primary_loc = nil
	for _, loc in ipairs(result.locations or {}) do
		if loc.symbolic and loc.symbolic.kind == "Primary" then
			primary_loc = loc
			break
		end
	end

	if primary_loc and primary_loc.concrete and primary_loc.concrete.location then
		local loc = primary_loc.concrete.location.start_point
		return string.format("%s:%d:%d", result.ident, loc.row, loc.column)
	end

	-- Fallback: just use the ident
	return result.ident
end

-- Run zizmor and populate diagnostics with the results.
function M.zizmor()
	-- Load and setup null-ls integration
	local null_ls_ok, null_ls = pcall(require, "null-ls")
	if not null_ls_ok then
		vim.notify("null-ls is required for zizmor.nvim", vim.log.levels.ERROR)
		return
	end

	-- Refresh diagnostics
	M.clear_diagnostics()

	local zizmor_generator = {
		method = null_ls.methods.DIAGNOSTICS,
		filetypes = M.config.filetypes,
		generator = {
			-- Configure when to run the diagnostics
			runtime_condition = function()
				return M.config.enabled
			end,
			-- Run on file open and after saves
			on_attach = function(_, bufnr)
				vim.api.nvim_buf_attach(bufnr, false, {
					on_load = function()
						if M.config.enabled then
							null_ls.generator()(
								{ bufnr = bufnr }
							)
						end
					end
				})
			end,
			fn = function(params)
				-- Only process workflow files
				local filepath = params.bufname or vim.api.nvim_buf_get_name(params.bufnr)
				if not is_workflow_file(filepath) then
					return {}
				end

				-- Get zizmor executable path
				local cmd = vim.fn.exepath("zizmor")
				if cmd == "" then
					vim.notify("zizmor executable not found in PATH", vim.log.levels.ERROR)
					return {}
				end

				-- Build command arguments
				-- We scan the workflow directory, not individual files
				local workflow_dir = vim.fn.fnamemodify(filepath, ":h")
				local args = {
					"--format=json",
					workflow_dir,
				}

				-- Add extra args from config
				for _, arg in ipairs(M.config.extra_args) do
					table.insert(args, 1, arg)
				end

				-- Create async system command
				local full_cmd = vim.list_extend({ cmd }, args)

				-- Track seen diagnostics to avoid duplicates
				local seen = {}
				local diags = {}

				-- Run zizmor asynchronously
				vim.system(
					full_cmd,
					{
						text = true,
						cwd = vim.fn.getcwd(),
						env = vim.env,
					},
					function(obj)
						if obj.code ~= 0 and obj.stderr and obj.stderr ~= "" then
							vim.schedule(function()
								vim.notify("Zizmor error: " .. obj.stderr, vim.log.levels.ERROR)
							end)
							return
						end

						local ok, parsed = pcall(vim.json.decode, obj.stdout)
						if not ok or not parsed then
							return
						end

						-- Zizmor outputs an array of findings
						for _, result in ipairs(parsed) do
							-- Create a unique key for this diagnostic
							local diag_key = create_diagnostic_key(result)

							-- Only process if we haven't seen this exact diagnostic
							if not seen[diag_key] and result.locations and #result.locations > 0 then
								seen[diag_key] = true

								-- Find the primary location
								for _, location in ipairs(result.locations) do
									if location.symbolic and location.symbolic.kind == "Primary"
									   and location.concrete and location.concrete.location then

										local concrete_loc = location.concrete.location.start_point
										local end_point = location.concrete.location.end_point

										-- Get the workflow file path
										local workflow_file = nil
										if location.symbolic.key and location.symbolic.key.Local then
											workflow_file = location.symbolic.key.Local.given_path
										end

										-- Only add diagnostic if it's for the current file
										local current_file = vim.fn.fnamemodify(filepath, ":t")
										local diagnostic_file = workflow_file and vim.fn.fnamemodify(workflow_file, ":t") or ""

										if current_file == diagnostic_file then
											local severity = result.determinations and result.determinations.severity
											local mapped_severity = severity and M.config.severity_map[severity] or M.config.default_severity

											-- Build the diagnostic message
											local message = string.format("[%s] %s", result.ident, result.desc)
											if location.symbolic.annotation then
												message = message .. ": " .. location.symbolic.annotation
											end
											if result.url then
												message = message .. " (" .. result.url .. ")"
											end

											local diag = {
												-- Zizmor uses 0-based indexing already
												lnum = concrete_loc.row,
												col = concrete_loc.column,
												end_lnum = end_point.row,
												end_col = end_point.column,
												message = message,
												severity = mapped_severity,
												source = "zizmor",
												user_data = {
													rule_id = result.ident,
													url = result.url,
													confidence = result.determinations and result.determinations.confidence,
												}
											}

											table.insert(diags, diag)
										end

										-- Only process the first Primary location
										break
									end
								end
							end
						end

						-- Schedule the diagnostic updates
						vim.schedule(function()
							if not namespace then
								namespace = vim.api.nvim_create_namespace("zizmor")
							end
							vim.diagnostic.set(namespace, params.bufnr, diags)
						end)
					end
				)
				return {}
			end
		}
	}

	null_ls.register(zizmor_generator)
end

-- Setup function to initialize the plugin
function M.setup(opts)
	if opts then
		for k, v in pairs(opts) do
			M.config[k] = v
		end
	end

	if M.config.enabled then
		M.zizmor()
	end
end

return M
