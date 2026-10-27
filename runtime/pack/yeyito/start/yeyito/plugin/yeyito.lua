-- The built-in config. `nvim --clean` skips it: stock Neovim (plus the
-- fork's C patches), useful for telling a config problem from a core one.
-- Neovim's own test suite (NVIM_TEST=1) gets stock behavior too.
if vim.g.loaded_yeyito or vim.list_contains(vim.v.argv, "--clean") or vim.env.NVIM_TEST then
  return
end
vim.g.loaded_yeyito = true

require("yeyito").setup()
