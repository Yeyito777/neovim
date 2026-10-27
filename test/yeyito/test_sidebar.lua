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
local steps = search_steps()
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
