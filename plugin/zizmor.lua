-- zizmor.nvim - GitHub Actions security diagnostics for Neovim
-- This file is automatically loaded by Neovim when the plugin is installed

-- Prevent loading the plugin multiple times
if vim.g.loaded_zizmor then
  return
end
vim.g.loaded_zizmor = 1

-- Create user commands
vim.api.nvim_create_user_command("ZizmorToggle", function()
  require("zizmor").toggle()
end, { desc = "Toggle zizmor diagnostics" })

vim.api.nvim_create_user_command("ZizmorConfig", function()
  require("zizmor").print_config()
end, { desc = "Print zizmor configuration" })

vim.api.nvim_create_user_command("ZizmorClear", function()
  require("zizmor").clear_diagnostics()
end, { desc = "Clear zizmor diagnostics" })
