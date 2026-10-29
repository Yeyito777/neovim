-- File sidebar (Ctrl+S), headless:
--   VIMRUNTIME=runtime build/bin/nvim --headless -u NORC -c 'luafile test/yeyito/test_sidebar.lua'
local api = vim.api
local failures = 0
local function check(name, ok, detail)
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. ((not ok and detail) and ("  " .. vim.inspect(detail)) or "") .. "\n")
  if not ok then
    failures = failures + 1
  end
end
local function keys(k)
  api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "mx", false)
end

vim.g.yeyito_sidebar_counts = false -- folder rows compared as they are; counts get their own checks

local function run()
-- A project: dirs before files, case-insensitive, .git hidden, dotfiles shown.
local dir = vim.fs.normalize(vim.fn.tempname())
for _, d in ipairs({ "src/core", "docs", ".git", "Zeta" }) do
  vim.fn.mkdir(dir .. "/" .. d, "p")
end
for _, f in ipairs({ "README.md", "b.txt", ".env", "src/main.c", "src/core/util.c", "docs/guide.md" }) do
  vim.fn.writefile({ "x" }, dir .. "/" .. f)
end
vim.cmd.cd(dir)
vim.cmd.edit("src/core/util.c")
local editor = api.nvim_get_current_win()

require("yeyito.sidebar") -- loaded by the built-in config (plugin/yeyito.lua)
check("config loaded", vim.g.loaded_yeyito == true)
check("Ctrl+S is mapped", vim.fn.maparg("<C-s>", "n") ~= "")

keys("<C-s>")
local side = api.nvim_get_current_win()
local sbuf = api.nvim_get_current_buf()
local function lines()
  return api.nvim_buf_get_lines(sbuf, 0, -1, true)
end
check("Ctrl+S opens it focused", side ~= editor and vim.bo[sbuf].filetype == "yeyito-sidebar")
check("28 columns with the border", api.nvim_win_get_width(side) == 27, api.nvim_win_get_width(side))
check("on the left", api.nvim_win_get_position(side)[2] == 0)
check("header is the folder name", vim.wo[side].winbar:find(vim.fn.fnamemodify(dir, ":t"), 1, true) ~= nil)
check("reveals the current file", api.nvim_get_current_line() == "      util.c", api.nvim_get_current_line())
check("tree order: dirs first, .git hidden", vim.deep_equal(lines(), {
  "  📁 docs/",
  "  📂 src/",
  "    📂 core/",
  "      util.c",
  "    main.c",
  "  📁 Zeta/",
  "  .env",
  "  b.txt",
  "  README.md",
}), lines())
check("current file is bold", #api.nvim_buf_get_extmarks(sbuf, api.nvim_create_namespace("yeyito.sidebar"), 0, -1, {}) == 1)
check("selected row has the marker", #api.nvim_buf_get_extmarks(sbuf, api.nvim_create_namespace("yeyito.sidebar.marker"), { 3, 0 }, { 3, -1 }, {}) == 1)
check("no terminal cursor in the sidebar", vim.o.guicursor:find("YeyitoSidebarCursor", 1, true) ~= nil)
check("border focused", vim.wo[side].winhighlight:find("WinSeparator:YeyitoSidebarBorderFocused", 1, true) ~= nil)

keys("gg<CR>")
check("Enter opens a folder", lines()[2] == "    guide.md", lines())
keys("<CR>")
check("Enter again closes it", lines()[2] == "  📂 src/", lines())
keys("G")
keys("<CR>")
check("Enter on a file opens it in the editor", vim.fs.basename(api.nvim_buf_get_name(api.nvim_win_get_buf(editor))) == "README.md")
check("focus stays in the sidebar, as in Exocortex", api.nvim_get_current_win() == side)
keys("3Gh")
check("h closes the parent folder", lines()[2] == "  📂 src/" and lines()[3] == "    📁 core/", lines())

keys("<Tab>")
check("Tab goes to the editor", api.nvim_get_current_win() == editor)
check("cursor back to normal", vim.o.guicursor:find("YeyitoSidebarCursor", 1, true) == nil)
check("border unfocused", vim.wo[side].winhighlight:find("WinSeparator:YeyitoSidebarBorder,", 1, true) ~= nil
  or vim.wo[side].winhighlight:find("WinSeparator:YeyitoSidebarBorder$") ~= nil)
keys("<Tab>")
check("Tab goes back to the sidebar", api.nvim_get_current_win() == side)
keys("<C-j>")
check("Ctrl+J: to the editor", api.nvim_get_current_win() == editor)
keys("<C-k>")
check("Ctrl+K: back to the sidebar", api.nvim_get_current_win() == side)
keys("<C-k>")
check("Ctrl+K from the sidebar: to the editor (either one switches)", api.nvim_get_current_win() == editor)
keys("<C-j>")

-- Files that appear on disk show up by themselves.
vim.fn.writefile({ "x" }, dir .. "/new.txt")
vim.wait(2000, function()
  return vim.tbl_contains(lines(), "  new.txt")
end)
check("new files appear live", vim.tbl_contains(lines(), "  new.txt"), lines())

keys("<C-s>")
check("Ctrl+S closes it back to the editor", api.nvim_get_current_win() == editor and not api.nvim_win_is_valid(side))
keys("ihello<C-s>")
check("Ctrl+S works from insert mode", api.nvim_get_mode().mode == "n" and vim.bo.filetype == "yeyito-sidebar")
keys("<C-s>")

-- Without the sidebar, Tab keeps its meaning (newer jump).
vim.cmd.edit(dir .. "/b.txt")
vim.cmd.edit(dir .. "/.env")
keys("<C-o>")
keys("<Tab>")
check("Tab without the sidebar is CTRL-I", vim.fs.basename(api.nvim_buf_get_name(0)) == ".env", api.nvim_buf_get_name(0))
-- Without it, Ctrl+J / Ctrl+K move the line, as before.
vim.cmd.enew()
api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
keys("gg<C-j>")
check("Ctrl+J without the sidebar moves the line down", vim.deep_equal(api.nvim_buf_get_lines(0, 0, -1, false), { "two", "one", "three" }))
keys("<C-k>")
check("Ctrl+K moves it back up", vim.deep_equal(api.nvim_buf_get_lines(0, 0, -1, false), { "one", "two", "three" }))
vim.cmd("bwipeout!")

-- :q in the last editor window does not leave the sidebar alone.
vim.cmd("tabnew")
keys("<C-s><Tab>")
check("before :q: sidebar + editor", #api.nvim_tabpage_list_wins(0) == 2, #api.nvim_tabpage_list_wins(0))
vim.cmd("quit")
check(":q in the last editor window closes the tab with its sidebar", #api.nvim_list_tabpages() == 1, #api.nvim_list_tabpages())

end

-- The sidebar's own command line: / ? n N :noh, Ex commands for the editor.
-- Typing into the bar needs Nvim's main loop (feedkeys "x!" would block in
-- its insert mode), so these steps run one after another on a timer: each
-- queues keys, the next one checks what they did.
local function search_steps()
  local steps = {}
  local function step(fn)
    steps[#steps + 1] = fn
  end
  local function send(k)
    api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "m", false)
  end
  local S = {}
  local function lines()
    return api.nvim_buf_get_lines(S.buf, 0, -1, true)
  end
  local function selected()
    local row = api.nvim_win_get_cursor(S.side)[1]
    return vim.trim(api.nvim_buf_get_lines(S.buf, row - 1, row, true)[1])
  end

  step(function()
    local dir = vim.fs.normalize(vim.fn.tempname())
    for _, d in ipairs({ "src/core", "docs" }) do
      vim.fn.mkdir(dir .. "/" .. d, "p")
    end
    for _, f in ipairs({ "README.md", "src/main.c", "src/core/util.c", "docs/guide.md" }) do
      vim.fn.writefile({ "x" }, dir .. "/" .. f)
    end
    vim.cmd("tabnew")
    vim.cmd.cd(dir)
    vim.cmd.edit("src/main.c")
    S.editor = api.nvim_get_current_win()
    keys("<C-s>")
    S.side, S.buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    send("/")
  end)
  step(function()
    local bar = api.nvim_get_current_win()
    check("/ opens the sidebar's bar", bar ~= S.side and api.nvim_win_get_config(bar).relative ~= ""
      and api.nvim_get_mode().mode == "i", api.nvim_get_mode())
    check("bar is in the bottom row, in the sidebar's columns",
      api.nvim_win_get_position(bar)[1] == vim.o.lines - 1 and api.nvim_win_get_position(bar)[2] == 0
      and api.nvim_win_get_width(bar) == 27, { api.nvim_win_get_position(bar), api.nvim_win_get_width(bar) })
    send("ma")
  end)
  step(function()
    check("typing filters the whole project live", vim.deep_equal(lines(), { "  src/main.c" }), lines())
    send("<CR>")
  end)
  step(function()
    check("Enter keeps the filter, back in the sidebar", api.nvim_get_current_win() == S.side
      and api.nvim_get_mode().mode == "n" and vim.deep_equal(lines(), { "  src/main.c" }), { lines(), api.nvim_get_mode() })
    send("/u<CR>")
  end)
  step(function()
    check("matches in folders, dirs-first tree order", vim.deep_equal(lines(), { "  docs/guide.md", "  src/core/util.c" }), lines())
    check("selects the next match after where it started (wrapping)", selected() == "docs/guide.md", selected())
    send("n")
  end)
  step(function()
    check("n: next match", selected() == "src/core/util.c", selected())
    send("n")
  end)
  step(function()
    check("n wraps", selected() == "docs/guide.md", selected())
    send("N")
  end)
  step(function()
    check("N: previous match", selected() == "src/core/util.c", selected())
    send("?gui<CR>")
  end)
  step(function()
    check("? searches backward", selected() == "docs/guide.md" and vim.deep_equal(lines(), { "  docs/guide.md" }), lines())
    send("/zzz")
  end)
  step(function()
    check("no matches", vim.deep_equal(lines(), { "  no matches" }), lines())
    send("<Esc>")
  end)
  step(function()
    check("Esc goes back to the last search and selection", vim.deep_equal(lines(), { "  docs/guide.md" })
      and api.nvim_get_current_win() == S.side and api.nvim_get_mode().mode == "n", { lines(), api.nvim_get_mode() })
    send("/<BS>")
  end)
  step(function()
    check("Backspace on an empty bar closes it", api.nvim_get_current_win() == S.side and api.nvim_get_mode().mode == "n")
    send(":noh<CR>")
  end)
  step(function()
    check(":noh: the tree again, on the selection", vim.tbl_contains(lines(), "    guide.md") and selected() == "guide.md",
      { lines(), selected() })
    send("/core<CR>")
  end)
  step(function()
    check("folders are found", vim.deep_equal(lines(), { "  📁 src/core/" }), lines())
    send("<CR>")
  end)
  step(function()
    check("Enter on a found folder opens it in the tree", selected() == "📂 core/" and vim.tbl_contains(lines(), "      util.c"),
      { lines(), selected() })
    send(":e README.md<CR>")
  end)
  step(function()
    local name = api.nvim_buf_get_name(api.nvim_win_get_buf(S.editor))
    check(": runs Ex commands in the editor", vim.fs.basename(name) == "README.md", name)
    check("focus stays in the sidebar", api.nvim_get_current_win() == S.side)
    vim.cmd("tabclose")
    -- A new project: its index builds in the background when / opens, so
    -- this Enter comes before it lands.
    local dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir .. "/docs", "p")
    for _, f in ipairs({ "README.md", "docs/guide.md", "new\nline.txt" }) do
      vim.fn.writefile({ "x" }, dir .. "/" .. f)
    end
    S.locked = dir .. "/locked" -- can't be listed: the search goes on without it
    vim.fn.mkdir(S.locked)
    vim.uv.fs_chmod(S.locked, 0)
    vim.cmd("tabnew")
    vim.cmd.cd(dir)
    vim.cmd.edit("README.md")
    keys("<C-s>")
    S.side, S.buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    S.tree = lines()
    send("/gui<CR>")
  end)
  step(function()
    check("a newline in a name shows as ?", vim.tbl_contains(S.tree, "  new?line.txt"), S.tree)
    check("Enter before the index is built: the match once it lands", vim.deep_equal(lines(), { "  docs/guide.md" })
      and selected() == "docs/guide.md", { lines(), selected() })
    vim.uv.fs_chmod(S.locked, 448) -- 0700, so Nvim can delete its temp dir
    vim.cmd("tabclose")
  end)
  return steps
end
local ok, err = pcall(run)
if not ok then
  io.stdout:write("ERROR " .. tostring(err) .. "\n")
  failures = failures + 1
end
-- Exocortex's sidebar keys, for files: dd, u / Ctrl+R, r, Ctrl+P, f, F, <,
-- c, visual selections and the ; menu. The trash is a temporary folder here.
local function file_steps()
  local steps = {}
  local function step(fn)
    steps[#steps + 1] = fn
  end
  local function send(k)
    api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "m", false)
  end
  local S = {}
  local function lines()
    return api.nvim_buf_get_lines(S.buf, 0, -1, true)
  end
  local function selected()
    local row = api.nvim_win_get_cursor(S.side)[1]
    return vim.trim(api.nvim_buf_get_lines(S.buf, row - 1, row, true)[1])
  end
  local function select(name)
    api.nvim_set_current_win(S.side)
    for i, line in ipairs(lines()) do
      if vim.trim(line) == name then
        api.nvim_win_set_cursor(S.side, { i, 0 })
        return
      end
    end
    error("no row " .. name)
  end
  local function exists(rel)
    return vim.uv.fs_lstat(S.dir .. "/" .. rel) ~= nil
  end
  local function editor_file()
    return vim.fs.basename(api.nvim_buf_get_name(api.nvim_win_get_buf(S.editor)))
  end
  local function modal_frame()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_config(win).zindex == 220 then
        return win
      end
    end
  end
  local function pending_rows()
    return #api.nvim_buf_get_extmarks(S.buf, api.nvim_create_namespace("yeyito.sidebar.delete"), 0, -1, {})
  end

  step(function()
    S.dir = vim.fs.normalize(vim.fn.tempname())
    S.trash = vim.fs.normalize(vim.fn.tempname())
    require("yeyito.files").trash_root = S.trash
    for _, d in ipairs({ "src", "docs" }) do
      vim.fn.mkdir(S.dir .. "/" .. d, "p")
    end
    for _, f in ipairs({ "README.md", "notes.txt", "src/main.c", "docs/guide.md" }) do
      vim.fn.writefile({ "x" }, S.dir .. "/" .. f)
    end
    vim.cmd("tabnew")
    vim.cmd.cd(S.dir)
    vim.cmd.edit("notes.txt")
    S.editor = api.nvim_get_current_win()
    keys("<C-s>")
    S.side, S.buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    send(":noh<CR>") -- the search steps' filter
  end)
  step(function()
    select("notes.txt")
    send("d")
  end)
  step(function()
    check("d: the row waits, red", pending_rows() == 1 and vim.wo[S.side].winhighlight:find("CursorLine:YeyitoSidebarSelDelete", 1, true) ~= nil
      and exists("notes.txt"), vim.wo[S.side].winhighlight)
    send("j")
  end)
  step(function()
    check("another key lets it go", pending_rows() == 0 and exists("notes.txt"))
    select("notes.txt")
    send("dd")
  end)
  step(function()
    check("dd: to the trash", not exists("notes.txt") and not vim.tbl_contains(lines(), "  notes.txt")
      and vim.uv.fs_stat(S.trash .. "/files/notes.txt") ~= nil, lines())
    local info = table.concat(vim.fn.readfile(S.trash .. "/info/notes.txt.trashinfo"), "\n")
    -- The project as its cwd (on macOS /var/folders is /private/var/folders).
    check("with its .trashinfo", info:find("Path=" .. vim.fn.getcwd() .. "/notes.txt", 1, true) ~= nil, info)
    check("its buffer is closed", editor_file() ~= "notes.txt" and vim.fn.bufexists(S.dir .. "/notes.txt") == 0, editor_file())
    send("u")
  end)
  step(function()
    check("u: back, selected, shown again", exists("notes.txt") and selected() == "notes.txt"
      and vim.uv.fs_stat(S.trash .. "/files/notes.txt") == nil and editor_file() == "notes.txt", { selected(), editor_file() })
    send("<C-r>")
  end)
  step(function()
    check("Ctrl+R: deleted again", not exists("notes.txt"))
    send("u")
  end)
  step(function()
    select("notes.txt")
    send("r")
  end)
  step(function()
    local bar = api.nvim_get_current_win()
    check("r: Rename: with the name", api.nvim_get_mode().mode == "i"
      and api.nvim_buf_get_lines(api.nvim_win_get_buf(bar), 0, 1, true)[1] == "notes.txt")
    send("<C-u>todo.txt<CR>")
  end)
  step(function()
    check("renamed, selected", exists("todo.txt") and not exists("notes.txt") and selected() == "todo.txt", lines())
    check("its buffer follows", editor_file() == "todo.txt" and not vim.bo[api.nvim_win_get_buf(S.editor)].modified, editor_file())
    send("u")
  end)
  step(function()
    check("u: the old name again", exists("notes.txt") and not exists("todo.txt") and editor_file() == "notes.txt")
    select("📁 docs/")
    send("<C-p>")
  end)
  step(function()
    send("new.md<CR>")
  end)
  step(function()
    check("Ctrl+P: a new file in the folder under the cursor, open in the editor",
      exists("docs/new.md") and api.nvim_get_current_win() == S.editor and editor_file() == "new.md", editor_file())
    api.nvim_set_current_win(S.side)
    send("u")
  end)
  step(function()
    check("u: gone again (it was empty)", not exists("docs/new.md"))
    select("📁 src/")
    send("f")
  end)
  step(function()
    send("lib<CR>")
  end)
  step(function()
    check("f: a new folder in the one under the cursor", vim.fn.isdirectory(S.dir .. "/src/lib") == 1 and selected() == "📂 lib/", selected())
    select("notes.txt") -- and README.md below it
    send("Vj")
  end)
  step(function()
    send("F")
  end)
  step(function()
    send("src/l<Tab><CR>")
  end)
  step(function()
    check("v + F: the selection moves (Tab completes the folder)", exists("src/lib/README.md") and exists("src/lib/notes.txt")
      and not exists("README.md") and editor_file() == "notes.txt", lines())
    send("u")
  end)
  step(function()
    check("u: both back", exists("README.md") and exists("notes.txt") and not exists("src/lib/notes.txt"))
    select("notes.txt")
    send("Vj")
  end)
  step(function()
    send("f")
  end)
  step(function()
    send("box<CR>")
  end)
  step(function()
    check("v + f: a new folder around the selection", exists("box/README.md") and exists("box/notes.txt"), lines())
    send("u")
  end)
  step(function()
    check("one u undoes both", exists("README.md") and exists("notes.txt") and not exists("box"))
    select("main.c")
    send("<")
  end)
  step(function()
    check("<: out of its folder", exists("main.c") and not exists("src/main.c") and selected() == "main.c", lines())
    send("u")
  end)
  step(function()
    select("README.md")
    send("c")
  end)
  step(function()
    check("c: a copy beside it, selected", exists("README copy.md") and selected() == "README copy.md", lines())
    send("u")
  end)
  step(function()
    check("u: the copy goes", not exists("README copy.md") and exists("README.md"))
    select("README.md")
    send(";")
  end)
  step(function()
    local menu = api.nvim_get_current_win()
    local labels = vim.tbl_map(vim.trim, api.nvim_buf_get_lines(api.nvim_win_get_buf(menu), 0, -1, true))
    check(";: the actions menu beside the row", api.nvim_win_get_config(menu).relative == "editor"
      and api.nvim_win_get_config(menu).col == 28 and vim.deep_equal(labels, { "▸ Rename", "Duplicate", "Move", "Copy path", "Delete" }), labels)
    send("4j<CR>")
  end)
  step(function()
    local menu = api.nvim_get_current_win()
    local line = vim.trim(api.nvim_buf_get_lines(api.nvim_win_get_buf(menu), 4, 5, true)[1])
    check("Delete asks first", line == "▸ You sure?" and exists("README.md"), line)
    send("<CR>")
  end)
  step(function()
    check("then deletes", not exists("README.md") and api.nvim_get_current_win() == S.side)
    send("u")
  end)
  step(function()
    select("📂 src/")
    send(";")
  end)
  step(function()
    local labels = vim.tbl_map(vim.trim, api.nvim_buf_get_lines(0, 0, -1, true))
    check("a folder's menu starts with New file / New folder", labels[1] == "▸ New file" and labels[2] == "New folder", labels)
    send("<Esc>")
  end)
  step(function()
    check("Esc closes it", api.nvim_get_current_win() == S.side)
    select("notes.txt")
    send("r")
  end)
  step(function()
    local frame = modal_frame()
    local cfg = frame and api.nvim_win_get_config(frame)
    local middle = cfg and cfg.col + (cfg.width + 2) / 2
    check("the name prompt: a box in the middle of the editor, right of the sidebar", cfg ~= nil
      and math.abs(middle - (28 + (vim.o.columns - 28) / 2)) <= 1
      and math.abs(cfg.row + 2.5 - vim.o.lines / 2) <= 1
      and api.nvim_buf_get_lines(api.nvim_win_get_buf(frame), 0, 1, true)[1] == " Rename notes.txt", cfg)
    send("<C-u>README.md<CR>")
  end)
  step(function()
    local frame = modal_frame()
    local frame_lines = frame and api.nvim_buf_get_lines(api.nvim_win_get_buf(frame), 0, -1, true) or {}
    check("a name that exists: asked again, with why and the text kept", api.nvim_get_mode().mode == "i"
      and api.nvim_get_current_line() == "README.md" and frame_lines[2] == " README.md exists"
      and exists("notes.txt"), frame_lines)
    send("<Esc>")
  end)
  step(function()
    check("Esc: gone, back in the sidebar", modal_frame() == nil and api.nvim_get_current_win() == S.side)
    api.nvim_buf_set_lines(api.nvim_win_get_buf(S.editor), 0, -1, true, { "edited" })
    select("notes.txt")
    send("dd")
  end)
  step(function()
    check("unsaved changes: not deleted", exists("notes.txt"))
    api.nvim_win_call(S.editor, function()
      vim.cmd("edit!")
    end)
    require("yeyito.sidebar").close()
    api.nvim_set_current_win(S.editor)
    send("<C-p>")
  end)
  step(function()
    vim.wait(2000, function()
      return modal_frame() ~= nil
    end, 10)
    local frame = modal_frame()
    local cfg = frame and api.nvim_win_get_config(frame)
    check("Ctrl+P without the sidebar: the box in the middle of the screen",
      cfg ~= nil and math.abs(cfg.col + (cfg.width + 2) / 2 - vim.o.columns / 2) <= 1, cfg)
    send("docs/fresh.md<CR>")
  end)
  step(function()
    check("and the file opens", exists("docs/fresh.md") and vim.fs.basename(api.nvim_buf_get_name(0)) == "fresh.md",
      api.nvim_buf_get_name(0))
    require("yeyito.files").trash_root = nil
    vim.fn.delete(S.dir, "rf")
    vim.fn.delete(S.trash, "rf")
    vim.cmd("tabclose")
  end)
  return steps
end

-- e / E / Ctrl+E reorder a folder and keep it; closed folders show their
-- file counts.
local function order_steps()
  local steps = {}
  local function step(fn)
    steps[#steps + 1] = fn
  end
  local function send(k)
    api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "m", false)
  end
  local S = {}
  local sidebar = require("yeyito.sidebar")
  local function lines()
    return vim.tbl_map(vim.trim, api.nvim_buf_get_lines(S.buf, 0, -1, true))
  end
  local function selected()
    local row = api.nvim_win_get_cursor(S.side)[1]
    return vim.trim(api.nvim_buf_get_lines(S.buf, row - 1, row, true)[1])
  end
  local function select(name)
    api.nvim_set_current_win(S.side)
    for i, line in ipairs(lines()) do
      if line == name then
        api.nvim_win_set_cursor(S.side, { i, 0 })
        return
      end
    end
    error("no row " .. name)
  end
  step(function()
    S.dir = vim.fs.normalize(vim.fn.tempname())
    S.order = vim.fn.tempname() .. "-order.json"
    sidebar._order_file(S.order)
    vim.fn.mkdir(S.dir .. "/lib/deep", "p")
    for _, f in ipairs({ "a.txt", "b.txt", "c.txt", "lib/x.txt", "lib/deep/y.txt" }) do
      vim.fn.writefile({ "x" }, S.dir .. "/" .. f)
    end
    vim.cmd("tabnew")
    vim.cmd.cd(S.dir)
    vim.cmd.edit("a.txt")
    keys("<C-s>")
    S.side, S.buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    select("c.txt")
    send("e")
  end)
  step(function()
    check("e: up one in its folder", vim.deep_equal(lines(), { "📁 lib/", "a.txt", "c.txt", "b.txt" }) and selected() == "c.txt", lines())
    send("e<C-e>")
  end)
  step(function()
    check("Ctrl+E: to the top (above folders too)", vim.deep_equal(lines(), { "c.txt", "📁 lib/", "a.txt", "b.txt" }), lines())
    local saved = vim.json.decode(table.concat(vim.fn.readfile(S.order), ""))
    check("the order is kept on disk", vim.deep_equal(saved[vim.fs.normalize(vim.fn.getcwd())], { "c.txt", "lib", "a.txt", "b.txt" }), saved)
    send("E")
  end)
  step(function()
    check("E: down one", vim.deep_equal(lines(), { "📁 lib/", "c.txt", "a.txt", "b.txt" }) and selected() == "c.txt", lines())
    select("a.txt")
    send("Vj")
  end)
  step(function()
    send("e")
  end)
  step(function()
    check("v + e: the selection moves together, still selected", vim.deep_equal(lines(), { "📁 lib/", "a.txt", "b.txt", "c.txt" })
      and api.nvim_get_mode().mode == "V" and vim.fn.line("v") == 2 and vim.fn.line(".") == 3, { lines(), api.nvim_get_mode() })
    send("<Esc>")
  end)
  step(function()
    select("c.txt")
    send("<C-e>")
  end)
  step(function()
    vim.fn.writefile({ "x" }, S.dir .. "/bb.txt")
    send("R")
  end)
  step(function()
    check("a new file goes where the sort puts it, after its neighbour", vim.deep_equal(lines(), { "c.txt", "📁 lib/", "a.txt", "b.txt", "bb.txt" }), lines())
    sidebar._order_file(S.order) -- read again from the file
    sidebar.close()
    keys("<C-s>")
    S.side, S.buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    check("the order comes back (from disk)", vim.deep_equal(lines(), { "c.txt", "📁 lib/", "a.txt", "b.txt", "bb.txt" }), lines())
    select("c.txt")
    send("r")
  end)
  step(function()
    send("<C-u>z.txt<CR>")
  end)
  step(function()
    check("a renamed file keeps its place", lines()[1] == "z.txt", lines())
    vim.g.yeyito_sidebar_counts = true
    send("R")
  end)
  step(function()
    vim.wait(3000, function()
      return vim.tbl_contains(lines(), "📁 lib/ 2")
    end, 20)
    check("a closed folder shows how many files it holds (all the way down)", vim.tbl_contains(lines(), "📁 lib/ 2"), lines())
    select("📁 lib/ 2")
    send("<CR>")
  end)
  step(function()
    vim.wait(3000, function()
      return vim.tbl_contains(lines(), "📁 deep/ 1")
    end, 20)
    check("an open folder doesn't (its files are listed)", vim.tbl_contains(lines(), "📂 lib/")
      and vim.tbl_contains(lines(), "📁 deep/ 1"), lines())
    vim.g.yeyito_sidebar_counts = false
    sidebar._order_file(nil)
    vim.fn.delete(S.dir, "rf")
    os.remove(S.order)
    vim.cmd("tabclose")
  end)
  return steps
end

local steps = search_steps()
vim.list_extend(steps, file_steps())
vim.list_extend(steps, order_steps())
local function next_step(i)
  if i > #steps then
    io.stdout:write(failures .. " failure(s)\n")
    vim.cmd(failures == 0 and "qa!" or "cq!")
    return
  end
  local step_ok, step_err = pcall(steps[i])
  if not step_ok then
    io.stdout:write("ERROR step " .. i .. ": " .. tostring(step_err) .. "\n")
    failures = failures + 1
  end
  vim.defer_fn(function()
    next_step(i + 1)
  end, 150)
end
next_step(1)
