-- The editor config, built into this Neovim fork (loaded by
-- plugin/yeyito.lua). Each module replaces what used to be a plugin or a
-- section of ~/.config/nvim/init.lua.
local M = {}

function M.setup()
  require("yeyito.colors").setup() -- color level, 'termguicolors', theme
  require("yeyito.options").setup() -- leader, options, diagnostics display
  require("yeyito.treesitter").setup() -- was nvim-treesitter
  require("yeyito.textobjects").setup() -- was nvim-treesitter-textobjects
  require("yeyito.lsp").setup() -- was nvim-lspconfig
  require("yeyito.statusline").setup() -- was lualine.nvim
  require("yeyito.completion").setup() -- was nvim-cmp + LuaSnip
  require("yeyito.markdown_refresh").setup()
  require("yeyito.persist_local_marks")
  require("yeyito.keymaps").setup()
  require("yeyito.strikethrough").setup()
  require("yeyito.commands").setup()
  require("yeyito.autocmds").setup()
  -- Markdown links: colored labels, click/Enter to open, Space m e / Space m a to edit.
  require("yeyito.markdown_links").setup()
end

return M
