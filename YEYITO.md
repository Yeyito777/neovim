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
- **Smooth scrolling in st** (C, `src/nvim/tui/tui.c` `glide_*`): on a
  terminal with st's app-driven smooth scrolling (mode 2032) a window's view
  scroll glides into place instead of jumping. Also `drawscreen.c`: a page
  back (CTRL-B) region-scrolls like a page forward does, so it glides too.
  See [Smooth scrolling](#smooth-scrolling).
- **Floats only block scrolls they overlap** (C, `ui_compositor.c`): a
  region scroll used to be dropped for a full repaint whenever any float was
  on screen; now only when one overlaps the scrolled area (upstream's TODO).
  Always-present floats (ui2's command line, the sidebar's foot) would
  otherwise disable smooth scrolling and make every scroll a repaint.
- **ui2 left offset** (Lua, `runtime/lua/vim/_core/ui2.lua`, `ui2/messages.lua`):
  `require('vim._core.ui2').set_col(n)` keeps the command line, messages,
  pager and dialogs right of the first `n` columns, so the file sidebar can run
  the full height. `vim._core.ui2` is compiled into the binary: rebuild after
  editing it.
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

The Python, Ruby, Perl and Node providers (for remote plugins, which this
config has none of) are off: with the Python one on, the first Python file of
a session made Neovim launch every `python3` on `$PATH` looking for pynvim
and wait for them, up to seconds on the Mac (`options.lua`).

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
| `smoothscroll.lua` | Marks which redraws are view scrolls, for the TUI to glide. |
| `sidebar.lua`, `files.lua` | The Ctrl+S file sidebar; its file operations (trash, rename/move, undo). |
| `ai.lua`, `lua/exocortex/` | `<leader>a` / `:Ai`: the AI on the Exocortex daemon; the app API client (vendored). |
| `markdown_links.lua`, `markdown_refresh.lua`, `strikethrough.lua`, `persist_local_marks.lua` | My Markdown and marks tools. |
| `queries/` | Highlight/indent/textobject queries for the bundled languages. |
| `overrides/queries/` | Replacements for built-in queries (Markdown); see its README. |

Vendored code: queries and `ts_indent.lua` from nvim-treesitter 42fc28ba, text
object queries from nvim-treesitter-textobjects 71385f1, server definitions from
nvim-lspconfig 107c245 (`lua/yeyito/servers/`) (all Apache-2.0).

## Editing the config

Edit the files, then `./install.sh` (Lua-only changes rebuild in seconds). To
try a change without installing: `VIMRUNTIME=$PWD/runtime build/bin/nvim`.

Where new code goes: Lua, in this package, by default. C only where it
clearly wins: something Lua can't reach (the TUI's smooth scrolling, the
compositor), or a hot path measured to cost real time. A C bug crashes the
editor, every C patch can conflict with the next Neovim release, and each
change needs a rebuild. Measured Oct 2026, none of the Lua was worth moving:
indent guides add 0.3 ms to a full redraw, and the freezes found were
blocking calls, which C would not have avoided.

To check that a change doesn't alter how things look, render the same file
with two builds and diff the screens cell by cell (colors included):
`test/yeyito/screendiff/shot.sh ~/.local/bin/nvim app.py before.txt`, then
`shot.sh build app.py after.txt` and `cells.py before.txt after.txt`.

Machine-local tweaks, if ever needed, go in `~/.config/nvim/after/plugin/*.lua`
(it runs after the built-in config; a plain `~/.config/nvim/init.lua` runs
before it and gets overridden).

## Smooth scrolling

The Exocortex TUI's smooth scrolling, in Neovim. When st supports it (DECRQM
`CSI ? 2032 $ p`, see `~/Config/st/docs/app-smooth-scroll.md`), the TUI turns
st's app-driven smooth scrolling on. A window whose view scrolls is then drawn
where its content was and eases into place over 100 ms, timed by st at the
display's refresh rate; inputs mid-glide add up, so holding CTRL-E or spinning
the wheel moves continuously. Nothing is sent between frames, so it stays
smooth over SSH.

What glides: the wheel and trackpad, CTRL-E/Y/D/U/F/B, `j`/`k` at the window
edge, `zz`/`zt`/`zb`, `n`/`N` and other jumps within a screen, typing past the
bottom, terminal output while following it. What doesn't: lines moving
because of an edit (`dd`, `o`, a paste), and jumps further than a screen
(`gg`, `G`), which are drawn in place; nor does the file sidebar, unless
`g:yeyito_sidebar_smooth_scroll` is on (see below). A window beside a split
(the editor next to the sidebar) glides too: st has no left/right margins, so
its rows scroll across the whole width and the other windows' columns are
drawn again in the same frame.

How: `smoothscroll.lua` sends the TUI a marker (`nvim_ui_send`, never written
to the terminal) from `WinScrolled`, which fires just before the redraw. The
TUI then glides the region scroll of that window's text area: after the
scroll, in the same synchronized update, it declares the window as st's moving
rectangle (`OSC 2032 ; r`) and starts an easing term (`OSC 2032 ; m ; 0 ; ROWS*1000
; 100`). st draws the strip the shifted window uncovers from the lines its
scroll pushed out. A window that moved without a region scroll (it was
redrawn) stops any glide (`OSC 2032 ; o ; 0`). Other terminals, tmux and
`nvim --clean` are unaffected.

Tests: `python3 test/yeyito/test_smooth_scroll.py` runs the real TUI against a
fake st on a PTY and checks each frame's bytes. In a real st,
`ST_SMOOTHSCROLL_LOG=file` logs the offset of every frame drawn.

## File sidebar (Ctrl+S)

The Exocortex sidebar, for files: the working directory as a tree on the
left, 28 columns with its border, in Exocortex's colors. It runs the full
height of the screen; the editor's command line, messages, `:messages` pager
and prompts stay to its right (see [Command line and messages](#command-line-and-messages)).

- **Ctrl+S** (normal, visual and insert mode): open it focused, on the current
  file (its folders opened), or close it back to the editor.
- **Tab**, **Ctrl+J** or **Ctrl+K** (normal mode): switch focus between it
  and the editor while it is open, as in Exocortex. Without the sidebar they
  keep their meaning: Tab is CTRL-I, Ctrl+J/Ctrl+K move the line down/up (in
  visual mode they always move the selected lines). The border is blue while
  the sidebar has focus.
- In the sidebar: `j`/`k` move; **Enter**, `l` or a click opens a file in the
  editor (focus stays in the sidebar, as in Exocortex) or opens/closes a
  folder; `h`/Backspace closes the folder; `i`/`a` go back to the editor; `q`
  closes it; `R` reloads.
- It follows the filesystem: open folders are watched, so files created by the
  shell or an agent show up by themselves. `.git` is hidden; dotfiles show.
- The editor's current file is bold. `:q` in the last editor window quits
  rather than leaving the sidebar alone.

Like Exocortex's sidebar it has its own command line, in its bottom row
(beside the editor's):

- **`/`** and **`?`** search the whole project, forward and backward: the list
  is filtered, live as you type, to the files and folders whose name contains
  the text (case-insensitive; the project-relative path when it has a `/`),
  matches highlighted, the nearest match selected. Enter keeps the filter
  (shown as `/text` in the bottom row), Esc or Backspace on an empty bar goes
  back. In a git repository it searches what git sees (tracked and untracked,
  not ignored); elsewhere every folder but `.git`, nearest first, up to 50,000
  files and folders (a home directory has far more), not inside macOS's
  `~/Library` (other apps' containers there can block whoever lists them).
- The list of the project's files is built in the background (folders are
  listed off the main thread; one that takes over 2 s is skipped), so even a
  home directory never freezes the editor:
  while the first one builds the list says `searching…`, and Enter or `n`
  typed meanwhile select their match when it lands. Each `/` rebuilds it
  (the project may have changed), searching the last one until then.
- **`n`** / **`N`**: next / previous match (shows the filter again after
  `:noh`).
- Enter on a file opens it; on a folder it leaves the search and opens the
  folder in the tree.
- **`:`** is the sidebar's command line: `:noh` clears the filter and shows
  the selection in the tree; anything else runs as an Ex command in the editor
  (`:w`, `:e file`, `:q`), focus staying in the sidebar.

Exocortex's sidebar keys work on files too:

- **`dd`** deletes the file or folder under the cursor: the first `d` turns
  the row red, the second deletes (any other key lets it go). It goes to the
  system's trash (Finder's on macOS, `~/.local/share/Trash` elsewhere), so
  it can come back.
- **`u`** / **`Ctrl+R`** undo / redo the last file operation (deleting,
  renaming, moving, creating, duplicating), for as long as Neovim runs.
- **`Ctrl+P`** (from the sidebar or the editor): a new file in the folder
  under the sidebar's cursor (or the selected file's folder); it opens in the
  editor. A name ending in `/` makes a folder. **`Ctrl+Shift+O`**: at the top
  of the project, wherever the cursor is (as in Exocortex; st sends it as
  `CSI 111;6u`, which Neovim reads as `<C-S-O>`). Without the sidebar,
  `Ctrl+P` makes it in the current file's folder. Insert mode's `Ctrl+P`
  still completes.
- **`f`** new folder, **`r`** rename (from the current name), **`c`**
  duplicate (`name copy.ext`), **`F`** move into a folder of the project (Tab
  completes; empty or `/` is the top, `..` one up), **`<`** move out of its
  folder.
- **`v`** / **`V`** select rows: `dd`, `F`, `<` and `f` (a new folder, with
  the selection moved into it) act on all of them.
- **`;`** or a right click: the actions menu beside the row (Rename,
  Duplicate, Move, Copy path, Delete, which asks "You sure?"; on a folder
  also New file and New folder). `j`/`k`, Enter or a click, Esc.
- Names (new file, new folder, rename, move) are typed in a box in the
  middle of the editor, Exocortex's overlay: its title says what and where,
  Enter does it, Esc cancels. When it can't be done ("main.c exists") the
  box stays, with why in red and the name kept to fix.

A file with unsaved changes isn't deleted, renamed or moved (save it first);
open buffers follow a rename or move, with their undo history, and language
servers are told. Not carried over: Exocortex's reordering (`e`/`E`), pins,
stars and unwrap (`x`), which have no meaning for a sorted file tree.

Scrolling the sidebar jumps rather than glides. It is a feature flag,
`g:yeyito_sidebar_smooth_scroll` (off; read on every scroll, so `:let
g:yeyito_sidebar_smooth_scroll = v:true` turns it on right away, or set it in
`~/.config/nvim/init.lua`). Feature flags and their defaults are at the top of
`options.lua`.

Unlike Exocortex it does not reopen at startup (`nvim` is also the
commit-message and scratch editor). Ctrl+S in insert mode replaces 0.12's
default LSP signature help there.

Tests: `VIMRUNTIME=$PWD/runtime build/bin/nvim --headless -u NORC -c 'luafile
test/yeyito/test_sidebar.lua'` (behavior and search; `$PWD` because it `cd`s) and `python3
test/yeyito/test_sidebar_layout.py` (the real TUI on a fake st: full height,
command line and pager beside it).

## AI (`<leader>a`, `:Ai`)

The model (Sonnet 5.5; `g:yeyito_ai_model` picks another) works on the
project through Neovim, on your Exocortex daemon: it needs `exocortexd`
running (it says so when it isn't). No API keys here: the daemon's logins.

- **`<leader>a`**: a box in the middle of the editor (as the sidebar's
  names); type the request, Enter. In visual mode, about the selected lines
  (the title says how many). **`:Ai request`** does the same from the
  command line (`:ai` too; `:'<,'>Ai ...` about those lines).
- While it works the selected lines are tinted and a card in the top right
  says what it's doing (`⠋ Sonnet 5.5 · editing src/main.c`). Keep editing
  meanwhile; **Ctrl+Q** stops it (otherwise Ctrl+Q is what it was).
- Its changes land at once: edited lines are tinted green until you edit
  them, files are saved (a file with your own unsaved changes is edited but
  left for you to save), files it makes show in the sidebar.
- **Undo**: one `u` in a buffer undoes a request's edits there; `u` in the
  sidebar undoes the files it created, moved or deleted (to the trash).
- Its reply shows in the card (`code` as in Exocortex); Esc puts it away.
  **`:Ai log`** shows this session's requests, what it did and the replies.
- One conversation per project (the working directory), hidden from the
  Exocortex sidebar, kept until it has been idle an hour (a Neovim started
  meanwhile picks it up). **`:Ai new`** starts a fresh one.

Its tools: `read_file` (what the editor has, unsaved changes too),
`edit_file`, `write_file`, `move_path`, `delete_path`, all run by Neovim,
plus the daemon's shell, `glob` and `grep`; it is told to change files only
through the editor's. It is `ai.lua`, using Exocortex's app API with its
Lua client, vendored as `lua/exocortex/` (Exocortex's `docs/app-api.md`).

Tests: `VIMRUNTIME=$PWD/runtime build/bin/nvim --headless -u NORC -c
'luafile test/yeyito/test_ai.lua'` (the tools, then the whole path against
Exocortex's fake daemon: needs bun and an Exocortex checkout).

## Command line and messages

The command line and messages are ui2 (`vim._core.ui2`, upstream's
experimental replacement of the message grid, drawn in windows), which is what
lets them sit beside the sidebar. Differences from the classic command line:

- No "Press ENTER" prompts: a message longer than the command line expands it
  until the next key; when it doesn't fit, `[+N]` says how many lines are
  hidden. Enter right after it, or `g<` any time, shows it all in the pager.
- `:messages` (and long command output) opens in a pager window: scroll it,
  `q` closes it.
- Prompts (`:s///c`, confirm dialogs) appear in a dialog window above the
  command line.

`g:yeyito_ui2 = v:false` in `~/.config/nvim/init.lua` goes back to the classic
command line (the sidebar then ends above it, as before).

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

The plugin-based setup it replaced (Oct 2026) is archived on both machines in
`~/.local/backups/nvim-config-20261026/`: old config, plugins, the previous
patched build and its source changes, with a README on running it again. The
config is also on GitHub as `Yeyito777/neovim-config` (archived).

## Ideas (from the old config's TODO.md)

- Auto-document `K`/`gd` results with AI.
- Keep the `K` hover window up until the cursor leaves the line.
- Try a Copilot-like completion.
- An in-editor AI chat with access to the project, file and selection.
- An underscore text object (`di_`, `da_`, `vi_`, `va_`).
