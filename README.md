# zizmor.nvim

A Neovim plugin for integrating [zizmor](https://github.com/zizmorcore/zizmor) GitHub Actions security diagnostics into Neovim.

## Features

- Real-time security diagnostics for GitHub Actions workflows
- Integrates with Neovim's native diagnostic system
- Uses `null-ls.nvim` for seamless LSP integration
- Deduplicates diagnostics (zizmor can report the same finding multiple times)
- Configurable severity mapping
- Only scans `.github/workflows/*.{yml,yaml}` files

## Requirements

- Neovim >= 0.8.0
- [zizmor](https://github.com/zizmorcore/zizmor) installed and available in PATH
- [null-ls.nvim](https://github.com/nvimtools/none-ls.nvim) or [none-ls.nvim](https://github.com/nvimtools/none-ls.nvim)
- [sast-nvim](https://github.com/johnsaigle/sast-nvim) (optional, for future adapter support)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-username/zizmor.nvim",
  dependencies = {
    "nvimtools/none-ls.nvim",
  },
  ft = { "yaml" },
  config = function()
    require("zizmor").setup()
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "your-username/zizmor.nvim",
  requires = { "nvimtools/none-ls.nvim" },
  config = function()
    require("zizmor").setup()
  end,
}
```

## Configuration

Default configuration:

```lua
require("zizmor").setup({
  -- Enable the plugin by default
  enabled = true,
  
  -- Severity mapping from zizmor to Neovim diagnostics
  severity_map = {
    High = vim.diagnostic.severity.ERROR,
    Medium = vim.diagnostic.severity.WARN,
    Low = vim.diagnostic.severity.INFO,
    Informational = vim.diagnostic.severity.HINT,
  },
  
  -- Default severity if not specified
  default_severity = vim.diagnostic.severity.WARN,
  
  -- Persona: "regular", "pedantic", or "auditor"
  -- auditor = show all findings (recommended)
  persona = "auditor",
  
  -- Additional zizmor CLI arguments
  extra_args = {},
  
  -- Filetypes to scan
  filetypes = { "yaml", "yml" },
})
```

## Usage

The plugin automatically runs when you open GitHub Actions workflow files (`.github/workflows/*.yml` or `.github/workflows/*.yaml`).

### Commands

- **Toggle diagnostics**: Call `require("zizmor").toggle()` to enable/disable diagnostics
- **View config**: Call `require("zizmor").print_config()` to see the current configuration
- **Clear diagnostics**: Call `require("zizmor").clear_diagnostics()` to clear all diagnostics

### Example Keymaps

```lua
vim.keymap.set("n", "<leader>zt", function()
  require("zizmor").toggle()
end, { desc = "Toggle zizmor diagnostics" })

vim.keymap.set("n", "<leader>zc", function()
  require("zizmor").print_config()
end, { desc = "Show zizmor config" })
```

## How It Works

1. When you open a workflow file, the plugin runs `zizmor --format=json --persona auditor -qq <workflow-dir>`
2. The `-qq` flag suppresses the banner and logging output (quiet mode)
3. Parses the JSON output and extracts findings for the current file
4. For each finding, identifies the "Primary" location (the main issue)
5. Uses `feature_kind` to determine highlight precision:
   - `KeyOnly` → Just highlight the problematic word
   - `Normal` → Highlight the relevant section
6. Deduplicates by rule ID + location to show each issue once
7. Displays diagnostics using Neovim's native diagnostic system

## Smart Highlighting & Deduplication

Zizmor can report the same finding multiple times with different location kinds (Primary, Related, Hidden). This plugin uses smart logic to avoid excessive highlighting:

**Deduplication:**
- Groups findings by rule ID + location to show each issue once
- Only uses "Primary" locations (ignores "Related" and "Hidden")
- Filters to only show diagnostics for the current file

**Precise Highlighting:**
- Uses zizmor's `feature_kind` field to determine highlight precision
- `KeyOnly` findings → Highlights just the problematic word (e.g., "lint")
- `Normal` findings → Highlights the relevant code section
- **File-level warnings** → Only highlights the first line (not the entire file)
  - Examples: `concurrency-limits`, `excessive-permissions` at workflow level
  - These warnings apply to the whole workflow, not a specific line
  - Highlighting just the first line makes them visible without obscuring code

## Example Output

When you open `.github/workflows/ci.yml`, you might see:

```
[artipacked] credential persistence through GitHub Actions artifacts: does not set persist-credentials: false (https://docs.zizmor.sh/audits/#artipacked)
[excessive-permissions] overly broad permissions: default permissions used due to no permissions: block (https://docs.zizmor.sh/audits/#excessive-permissions)
```

## Troubleshooting

### Zizmor not found

Make sure `zizmor` is installed and available in your PATH:

```bash
# Install zizmor
pip install zizmor

# Or via cargo
cargo install zizmor

# Verify it's in PATH
which zizmor
```

### No diagnostics showing

1. Make sure you're editing a file in `.github/workflows/`
2. Check that the file has a `.yml` or `.yaml` extension
3. Run `:checkhealth` to verify null-ls is loaded
4. Check if zizmor runs successfully: `zizmor --format=json -qq .github/workflows/`
5. Try toggling the plugin: `:ZizmorToggle` twice to reset

### null-ls not found

Install null-ls or none-ls:

```lua
-- Using lazy.nvim
{
  "nvimtools/none-ls.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
}
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT

## Credits

- [zizmor](https://github.com/zizmorcore/zizmor) - The GitHub Actions security scanner
- [sast-nvim](https://github.com/johnsaigle/sast-nvim) - Library structure inspiration
- [clippy.nvim](https://github.com/johnsaigle/clippy.nvim) - Deduplication pattern reference
