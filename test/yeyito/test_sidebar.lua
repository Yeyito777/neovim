-- File sidebar (Ctrl+S), headless:
--   VIMRUNTIME=runtime build/bin/nvim --headless -l test/yeyito/test_sidebar.lua
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

local ok, err = pcall(run)
if not ok then
  io.stdout:write("ERROR " .. tostring(err) .. "\n")
  failures = failures + 1
end
io.stdout:write(failures .. " failure(s)\n")
vim.cmd(failures == 0 and "qa!" or "cq!")
