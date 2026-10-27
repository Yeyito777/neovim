# Yeyito's Neovim

Neovim 0.12.2 with my editor config built in. There are no dotfiles and no
plugin manager: `./install.sh` gives the same editor on every machine.

What's on top of upstream (`git log v0.12.2..yeyito`):

- **`conceal_compact`** (C): concealed text can take zero width, so a Markdown
  link's hidden URL doesn't wrap the line. Tests:
  `test/functional/ui/compact_{wrap,mouse}_spec.lua`.
- **`$NVIM_NOTTYFAST`** (C, backport of upstream 66149ca): skips the blocking
  terminal-background probe over slow SSH. `.zshrc` sets it for SSH sessions.
  Drop the commit when rebasing onto a release that already includes it.
- **Bundled parsers**: python cpp java bash javascript typescript tsx html css
  rust, besides upstream's c lua vim vimdoc query markdown
  (`cmake.deps/deps.txt`, pinned to nvim-treesitter's lockfile).
- **The config**: `runtime/pack/yeyito/start/yeyito/`, a package inside
  `$VIMRUNTIME`, so it loads like a plugin that ships with Neovim.

## Install / update

```sh
git clone https://github.com/Yeyito777/neovim && cd neovim   # branch yeyito
./install.sh        # builds, installs to ~/.local/opt/nvim, links ~/.local/bin/nvim
git pull && ./install.sh                                      # later
```

Needs cmake, a C compiler, gettext (macOS: `brew install cmake gettext`) and
network access for the first build (dependency tarballs). `PREFIX=` / `BIN=`
change where it goes.

Not bundled (they're separate programs): language servers (pyright,
clangd, typescript-language-server, vscode-html/css-language-server,
rust-analyzer, lua-language-server), git, latexmk, a clipboard tool. Servers
that aren't installed are skipped silently.

## Layout of the config

`runtime/pack/yeyito/start/yeyito/`:

| Path | What |
|---|---|
| `plugin/yeyito.lua` | Entry point; `nvim --clean` skips it (stock Neovim + the C patches). |
| `lua/yeyito/init.lua` | Loads the modules below, in order. |
| `colors.lua` | Terminal color level (truecolor / 256 / 16), `set_hl()` with fallbacks, the palette and theme. |
| `options.lua`, `keymaps.lua`, `commands.lua`, `autocmds.lua` | What used to be the body of `init.lua`. |
| `lsp.lua` + `servers/*.lua` | Servers and settings (was nvim-lspconfig; `servers/` are its definitions). `:LspInfo/Log/Start/Stop/Restart` alias core's `:lsp` / `:checkhealth vim.lsp`. |
| `completion.lua` | `<C-Space>` / `<Tab>` / `<CR>` on built-in completion: LSP + buffer words ranked together, file names when typing a path (was nvim-cmp + LuaSnip). |
| `treesitter.lua`, `ts_indent.lua` | Highlighting and indentation for every bundled language (was nvim-treesitter). |
| `textobjects.lua` | `af if ac ic`, `]] [[`, `<Space>u` / `<Space>i` (was nvim-treesitter-textobjects). |
| `statusline.lua` | The lualine look, cell for cell (was lualine.nvim). |
| `indent_guides.lua` | Indent guides (was indent-blankline.nvim). |
| `marks.lua` | Marks in the sign column + marks.nvim's mappings and bookmarks. |
| `markdown_links.lua`, `markdown_refresh.lua`, `strikethrough.lua`, `persist_local_marks.lua` | My Markdown and marks tools. |
| `queries/` | Highlight/indent/textobject queries for the bundled languages. |
| `overrides/queries/` | Replacements for built-in queries (Markdown); see its README. |

Vendored code: queries and `ts_indent.lua` from nvim-treesitter 42fc28ba, text
object queries from nvim-treesitter-textobjects 71385f1, server definitions from
nvim-lspconfig 107c245 (`lua/yeyito/servers/`) (all Apache-2.0).

## Editing the config

Edit the files, then `./install.sh` (Lua-only changes rebuild in seconds). To
try a change without installing: `VIMRUNTIME=$PWD/runtime build/bin/nvim`.

Machine-local tweaks, if ever needed, go in `~/.config/nvim/after/plugin/*.lua`
(it runs after the built-in config; a plain `~/.config/nvim/init.lua` runs
before it and gets overridden).

## Markdown links

Labels render cyan and underlined; the file on disk stays ordinary Markdown.
In Markdown buffers: Enter or `gx` opens the link under the cursor (Enter
elsewhere is a normal Enter), a left click on a label opens it, `<Space>me`
shows one link's source for editing, `<Space>ma` all of them
(`:MarkdownLinkToggle`, `:MarkdownLinksToggle`). Relative file links resolve
from the Markdown file's directory. `:echo has('conceal_compact')` must print 1
for hidden URLs to take no width.

## Moving to a new Neovim release

```sh
git fetch upstream --tags
git rebase --onto vX.Y.Z v0.12.2 yeyito    # conflicts can only be in the C patch
./install.sh
TEST_FILE=test/functional/ui/compact_wrap_spec.lua make functionaltest
TEST_FILE=test/functional/ui/compact_mouse_spec.lua make functionaltest
```

Then open a few files of each language (queries are pinned to the bundled
parser revisions; bump both together). `test/yeyito/` has pynvim integration
tests for the wrapping and Markdown link behavior (`NVIM_TEST_BIN=build/bin/nvim`).

## Rollback

The plugin-based setup it replaced (Oct 2026) is backed up in
`~/.local/backups/nvim-config-20261026/` and `Yeyito777/neovim-config`;
`~/.local/opt/neovim-visible-wrap` is the previous build.

## Ideas (from the old config's TODO.md)

- Auto-document `K`/`gd` results with AI.
- Keep the `K` hover window up until the cursor leaves the line.
- Try a Copilot-like completion.
- An in-editor AI chat with access to the project, file and selection.
- An underscore text object (`di_`, `da_`, `vi_`, `va_`).
