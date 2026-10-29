-- The editor config, built into this Neovim fork (loaded by
-- plugin/yeyito.lua). Each module replaces what used to be a plugin or a
-- section of ~/.config/nvim/init.lua.
local M = {}

function M.setup()
  require("yeyito.colors").setup() -- color level, 'termguicolors', theme
  require("yeyito.options").setup() -- leader, options, diagnostics display
  if vim.g.yeyito_ui2 then
    -- Command line and messages drawn in windows (vim._core.ui2), so they
    -- can stay beside the file sidebar.
    require("vim._core.ui2").enable({})
  end
  require("yeyito.marks").setup() -- was marks.nvim
  require("yeyito.indent_guides").setup() -- was indent-blankline.nvim
  require("yeyito.treesitter").setup() -- was nvim-treesitter
  require("yeyito.textobjects").setup() -- was nvim-treesitter-textobjects
  require("yeyito.lsp").setup() -- was nvim-lspconfig
  require("yeyito.statusline").setup() -- was lualine.nvim
  require("yeyito.smoothscroll").setup() -- glides scrolls in st (mode 2032)
  require("yeyito.sidebar").setup() -- Ctrl+S file sidebar, as in Exocortex
  require("yeyito.completion").setup() -- was nvim-cmp + LuaSnip
  require("yeyito.markdown_refresh").setup()
  require("yeyito.persist_local_marks")
  require("yeyito.keymaps").setup()
  require("yeyito.strikethrough").setup()
  require("yeyito.commands").setup()
  require("yeyito.autocmds").setup()
  -- Markdown links: colored labels, click/Enter to open, Space m e / Space m a to edit.
  require("yeyito.markdown_links").setup()
  -- <leader>a / :Ai: the AI edits the project through Neovim (Exocortex daemon).
  require("yeyito.ai").setup()
end

return M
