Queries here replace Neovim's built-in ones for the same language (installed
with `vim.treesitter.query.set()` in `lua/yeyito/treesitter.lua`). They can't
live in `queries/`: this package comes after `$VIMRUNTIME` on the runtime path,
so a plain file there would lose to the built-in query.
