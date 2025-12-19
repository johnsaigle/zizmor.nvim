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
	-- Persona to use: "regular", "pedantic", or "auditor"
	persona = "auditor",
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

-- Helper to find the best location to highlight based on feature_kind
-- KeyOnly = highlight just the key word (precise)
-- Normal = highlight the full feature (broader context)
local function get_best_location_for_diagnostic(result, current_filename)
	-- First, find the Primary location for this file
	local primary_loc = nil
	for _, loc in ipairs(result.locations or {}) do
		if loc.symbolic and loc.symbolic.kind == "Primary" then
			local workflow_file = loc.symbolic.key and loc.symbolic.key.Local and loc.symbolic.key.Local.given_path
			local diagnostic_file = workflow_file and vim.fn.fnamemodify(workflow_file, ":t") or ""
			if current_filename == diagnostic_file then
				primary_loc = loc
				break
			end
		end
	end

	if not primary_loc or not primary_loc.concrete or not primary_loc.concrete.location then
		return nil
	end

	-- Use feature_kind to determine highlight precision
	-- KeyOnly = small, precise highlight (just the problematic word)
	-- Normal = broader highlight (the whole problematic section)
	local concrete = primary_loc.concrete.location
	local annotation = primary_loc.symbolic.annotation or ""

	return {
		lnum = concrete.start_point.row,
		col = concrete.start_point.column,
		end_lnum = concrete.end_point.row,
		end_col = concrete.end_point.column,
		annotation = annotation,
		feature_kind = primary_loc.symbolic.feature_kind,
	}
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
					"-qq", -- Quiet mode: suppress banner and logging
				}

				-- Add persona if configured
				if M.config.persona then
					table.insert(args, "--persona")
					table.insert(args, M.config.persona)
				end

				-- Add extra args from config
				for _, arg in ipairs(M.config.extra_args) do
					table.insert(args, arg)
				end

				-- Add workflow directory as last argument
				table.insert(args, workflow_dir)

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
						-- Zizmor exits with code 0 even when findings exist
						-- Only treat non-zero exit as error if stdout is empty
						if obj.code ~= 0 and (not obj.stdout or obj.stdout == "") then
							vim.schedule(function()
								local err_msg = obj.stderr and obj.stderr ~= "" and obj.stderr or "Unknown error"
								vim.notify("Zizmor failed: " .. err_msg, vim.log.levels.ERROR)
							end)
							return
						end

						-- Parse JSON output
						local ok, parsed = pcall(vim.json.decode, obj.stdout)
						if not ok or not parsed then
							-- Silent failure if JSON parsing fails (empty results)
							vim.schedule(function()
								if not namespace then
									namespace = vim.api.nvim_create_namespace("zizmor")
								end
								vim.diagnostic.set(namespace, params.bufnr, {})
							end)
							return
						end

						-- Get current filename for filtering
						local current_file = vim.fn.fnamemodify(filepath, ":t")

						-- Zizmor outputs an array of findings
						-- Group by ident to avoid showing the same rule multiple times
						for _, result in ipairs(parsed) do
							-- Get the best location for this diagnostic
							local loc = get_best_location_for_diagnostic(result, current_file)

							if loc then
								-- Create unique key: ident + line + column
								local diag_key = string.format("%s:%d:%d", result.ident, loc.lnum, loc.col)

								-- Only add if we haven't seen this exact diagnostic
								if not seen[diag_key] then
									seen[diag_key] = true

									local severity = result.determinations and result.determinations.severity
									local mapped_severity = severity and M.config.severity_map[severity] or M.config.default_severity

									-- Build the diagnostic message
									local message = string.format("[%s] %s", result.ident, result.desc)
									if loc.annotation and loc.annotation ~= "" then
										message = message .. ": " .. loc.annotation
									end
									if result.url then
										message = message .. " (" .. result.url .. ")"
									end

									local diag = {
										-- Zizmor uses 0-based indexing already
										lnum = loc.lnum,
										col = loc.col,
										end_lnum = loc.end_lnum,
										end_col = loc.end_col,
										message = message,
										severity = mapped_severity,
										source = "zizmor",
										user_data = {
											rule_id = result.ident,
											url = result.url,
											confidence = result.determinations and result.determinations.confidence,
											feature_kind = loc.feature_kind,
										}
									}

									table.insert(diags, diag)
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
