local M = {}

-- Feature flags. Set one in ~/.config/nvim/init.lua (runs first) or at any
-- time with :let g:NAME = v:true; each is read when it applies.
local flags = {
  -- The Ctrl+S file sidebar glides when it scrolls, like the editor does.
  yeyito_sidebar_smooth_scroll = false,
  -- Neovim's Lua command line and messages (ui2, experimental in 0.12): what
  -- lets the command line sit beside the sidebar instead of under it. Off:
  -- the classic command line and hit-enter prompts. Read at startup.
  yeyito_ui2 = true,
}

function M.setup()
  for name, default in pairs(flags) do
    if vim.g[name] == nil then
      vim.g[name] = default
    end
  end

  vim.g.mapleader = " "
  vim.g.maplocalleader = " "

  -- No remote plugins, so no language providers. With them, the first Python
  -- buffer's ftplugin (`has('python3')`) runs every python3 on $PATH in turn
  -- to look for pynvim while the editor waits: 0.3-0.6 s on the Mac, seconds
  -- when those Pythons aren't in the disk cache.
  vim.g.loaded_python3_provider = 0
  vim.g.loaded_ruby_provider = 0
  vim.g.loaded_perl_provider = 0
  vim.g.loaded_node_provider = 0

  -- Mark configuration
  vim.opt.signcolumn = "yes"
  vim.opt.fillchars:append({ msgsep = " " })
  vim.opt.number = true
  vim.opt.relativenumber = true
  vim.opt.cursorline = true

  vim.opt.tabstop = 2
  vim.opt.softtabstop = 2
  vim.opt.shiftwidth = 2
  vim.opt.expandtab = true

  vim.opt.undolevels = 10000
  vim.opt.undoreload = 100000
  vim.opt.undofile = true
  vim.opt.undodir = vim.fn.stdpath("data") .. "/undo"
  vim.opt.shortmess:append("I")

  -- Keep deletes/changes on Vim's internal registers, not the system clipboard.
  vim.opt.clipboard = ""

  vim.opt.ignorecase = true
  vim.opt.smartcase = true

  -- Auto-reload files changed outside of Neovim (see autocmds.lua)
  vim.o.autoread = true

  -- Show LSP diagnostics
  vim.diagnostic.config({
    virtual_text = {
      spacing = 0,
      prefix = ">",
    },
    signs = false,
    underline = true,
    update_in_insert = false,
    severity_sort = true,
  })
end

return M
