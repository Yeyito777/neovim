local M = {}

function M.setup()
  vim.g.mapleader = " "
  vim.g.maplocalleader = " "

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
