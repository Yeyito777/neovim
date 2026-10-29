-- The AI (<leader>a, :Ai), headless:
--   VIMRUNTIME=$PWD/runtime build/bin/nvim --headless -u NORC -c 'luafile test/yeyito/test_ai.lua'
-- Its tools are run directly, then everything end to end against Exocortex's
-- fake daemon (clients/testing/fake-daemon.ts, needs bun; EXOCORTEX_DIR, else
-- ~/Workspace/exocortex or ~/Desktop/Exocortex), whose scripted model calls
-- a tool when the prompt is "tool NAME JSON".
local api = vim.api
local failures = 0
local function check(name, ok, detail)
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. ((not ok and detail ~= nil) and ("  " .. vim.inspect(detail)) or "") .. "\n")
  if not ok then
    failures = failures + 1
  end
end

local ai = require("yeyito.ai")
local files = require("yeyito.files")
local dir = vim.fs.normalize(vim.fn.tempname())
local trash = vim.fs.normalize(vim.fn.tempname())
files.trash_root = trash
vim.fn.mkdir(dir .. "/src", "p")
vim.fn.writefile({ "def main():", "    print('a')", "    print('b')", "", "main()" }, dir .. "/src/app.py")
vim.fn.writefile({ "one", "two" }, dir .. "/notes.txt")
vim.fn.writefile({ "x", "x", "x" }, dir .. "/xs.txt")
vim.cmd.cd(dir)
local function disk(path)
  return vim.fn.readfile(dir .. "/" .. path)
end
local function exists(path)
  return vim.uv.fs_lstat(dir .. "/" .. path) ~= nil
end

local function run_tools()
  local turn = { touched = {}, did = {} }
  local t = {}
  for _, tool in ipairs(ai._tools(dir, turn)) do
    t[tool.name] = function(input)
      local ok, out = pcall(tool.handler, input)
      return ok and out or nil, not ok and out or nil
    end
  end
  return t, turn
end

local t = run_tools()
vim.cmd.edit("src/app.py")
local app = api.nvim_get_current_buf()
local changed_ns = api.nvim_create_namespace("yeyito.ai.changed")

-- read_file
api.nvim_buf_set_lines(app, 4, 5, false, { "main()  # unsaved" })
local out = t.read_file({ path = "src/app.py" })
check("read_file: numbered lines, as the editor has them (unsaved too)", out and out:find("     1\tdef main():", 1, true)
  and out:find("main()  # unsaved", 1, true) ~= nil, out)
vim.cmd("silent edit!")
local _, err = t.read_file({ path = "src" })
check("read_file: a folder is an error", err and err:find("folder") ~= nil, err)
_, err = t.read_file({ path = "nope.txt" })
check("read_file: a missing file is an error", err and err:find("No file") ~= nil, err)
out = t.read_file({ path = "src/app.py", offset = 2, limit = 2 })
check("read_file: offset and limit", out and out:find("^     2\t") and out:find("(lines 2-3 of 5)", 1, true) ~= nil, out)

-- edit_file: one undo step for the request, saved, tinted
out = t.edit_file({ path = "src/app.py", old_string = "print('a')", new_string = "print('A')" })
out = t.edit_file({ path = "src/app.py", old_string = "print('b')", new_string = "print('B')\n    print('C')" })
check("edit_file: the buffer changes and is saved", disk("src/app.py")[2] == "    print('A')" and disk("src/app.py")[4] == "    print('C')"
  and not vim.bo[app].modified, disk("src/app.py"))
local marks = api.nvim_buf_get_extmarks(app, changed_ns, 0, -1, { details = true })
check("the changed lines are tinted", #marks == 2 and marks[1][2] == 1 and marks[2][2] == 2 and marks[2][4].end_row == 3,
  vim.tbl_map(function(m) return { m[2], m[4].end_row } end, marks))
api.nvim_buf_call(app, function()
  vim.cmd("silent normal! u")
end)
check("one u undoes the whole request", api.nvim_buf_get_lines(app, 1, 3, false)[1] == "    print('a')"
  and api.nvim_buf_get_lines(app, 0, -1, false)[3] == "    print('b')", api.nvim_buf_get_lines(app, 0, -1, false))
vim.cmd("silent write") -- the file as it started
t = run_tools()
out, err = t.edit_file({ path = "src/app.py", old_string = "print('a')", new_string = "print('Z')" })
local tinted = #api.nvim_buf_get_extmarks(app, changed_ns, 0, -1, {})
api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! x")
check("the tint goes when the user edits the line", tinted == 1 and #api.nvim_buf_get_extmarks(app, changed_ns, 0, -1, {}) == 0,
  { tinted, err })
vim.cmd("silent write")

-- the user's unsaved changes stay theirs
api.nvim_buf_set_lines(app, 0, 1, false, { "def main():  # mine" })
t = run_tools()
out, err = t.edit_file({ path = "src/app.py", old_string = "print('b')", new_string = "print('b')  # ai" })
check("unsaved changes: edited in the buffer, not saved", out and out:find("not saved", 1, true) ~= nil and vim.bo[app].modified
  and disk("src/app.py")[1] == "def main():" and api.nvim_buf_get_lines(app, 2, 3, false)[1] == "    print('b')  # ai",
  { out, err, disk("src/app.py")[1] })
vim.cmd("silent edit!")

_, err = t.edit_file({ path = "src/app.py", old_string = "nothing like this", new_string = "x" })
check("edit_file: old_string not there", err and err:find("not in") ~= nil, err)
_, err = t.edit_file({ path = "xs.txt", old_string = "x", new_string = "y" })
check("edit_file: old_string more than once", err and err:find("3 times") ~= nil, err)
t.edit_file({ path = "xs.txt", old_string = "x", new_string = "y", replace_all = true })
check("edit_file: replace_all (a file not open: loaded, saved)", vim.deep_equal(disk("xs.txt"), { "y", "y", "y" }), disk("xs.txt"))
check("a file it opened isn't listed", not vim.bo[vim.fn.bufnr(dir .. "/xs.txt")].buflisted)

-- write_file, move_path, delete_path
out = t.write_file({ path = "pkg/new.py", content = "x = 1\n" })
check("write_file: a new file (and its folder)", exists("pkg/new.py") and vim.deep_equal(disk("pkg/new.py"), { "x = 1" }), out)
local op = files.undo()
check("the sidebar's u trashes it", op and not exists("pkg/new.py") and vim.uv.fs_stat(trash .. "/files/new.py") ~= nil, op and op.label)
files.redo()
check("Ctrl+R brings it back", exists("pkg/new.py"))
t.write_file({ path = "notes.txt", content = "one\n2\nthree\n" })
check("write_file: an existing file, rewritten", vim.deep_equal(disk("notes.txt"), { "one", "2", "three" }), disk("notes.txt"))
t.move_path({ from = "notes.txt", to = "docs/notes.md" })
check("move_path", exists("docs/notes.md") and not exists("notes.txt"))
t.delete_path({ path = "docs" })
check("delete_path: to the trash", not exists("docs") and vim.uv.fs_stat(trash .. "/files/docs") ~= nil)
files.undo()
check("u in the sidebar puts it back", exists("docs/notes.md"))
check("what it did is listed for :Ai log", true)

-- The card: `code` keeps its backticks together when the reply wraps.
ai._show("done", "I changed `add` in `calc.py` to return `a + b` instead of `a - b`, and gave both `add` and `mul` docstrings.")
local card_buf = ai._card.buf
local text = table.concat(api.nvim_buf_get_lines(card_buf, 1, -1, false), "\n")
local code = {}
for _, m in ipairs(api.nvim_buf_get_extmarks(card_buf, api.nvim_create_namespace("yeyito.ai.working"), 1, -1, { details = true })) do
  if m[4].hl_group == "YeyitoAiCode" then
    code[#code + 1] = api.nvim_buf_get_text(card_buf, m[2], m[3], m[2], m[4].end_col, {})[1]
  end
end
check("the card: code spans stay whole when it wraps, without backticks", not text:find("`")
  and vim.deep_equal(code, { "add", "calc.py", "a + b", "a - b", "add", "mul" }), { text, code })
ai._show("done", "I moved it into `done/exocortex-daemon-as-a-dependency-and-some-more.md`. Also `main.md`.")
text = table.concat(api.nvim_buf_get_lines(card_buf, 1, -1, false), "")
code = {}
for _, m in ipairs(api.nvim_buf_get_extmarks(card_buf, api.nvim_create_namespace("yeyito.ai.working"), 1, -1, { details = true })) do
  if m[4].hl_group == "YeyitoAiCode" then
    code[#code + 1] = api.nvim_buf_get_text(card_buf, m[2], m[3], m[2], m[4].end_col, {})[1]
  end
end
check("a code span longer than a line: broken, still highlighted, no backticks", not text:find("`")
  and table.concat(code, "", 1, #code - 1) == "done/exocortex-daemon-as-a-dependency-and-some-more.md" and code[#code] == "main.md",
  { text, code })

-- End to end, with the fake daemon.
local exo_dir
for _, d in ipairs({ os.getenv("EXOCORTEX_DIR") or "", "~/Workspace/exocortex", "~/Desktop/Exocortex" }) do
  d = vim.fn.expand(d)
  if d ~= "" and vim.uv.fs_stat(d .. "/clients/testing/fake-daemon.ts") then
    exo_dir = d
    break
  end
end
if not (exo_dir and vim.fn.executable("bun") == 1) then
  io.stdout:write("skip the fake-daemon checks: no Exocortex checkout or bun\n")
else
  local sock = vim.fn.tempname() .. ".sock"
  local ready = false
  local proc = vim.system({ "bun", exo_dir .. "/clients/testing/fake-daemon.ts", "--socket", sock }, {
    stdin = true,
    stdout = function(_, data)
      if data and data:find("ready") then
        ready = true
      end
    end,
  })
  vim.wait(10000, function()
    return ready
  end, 20)
  vim.env.EXOCORTEX_SOCKET = sock
  ai.context = false -- the scripted model reads the prompt as "tool NAME JSON"
  local done
  ai.on_done = function(kind, text)
    done = { kind = kind, text = text }
  end
  local function card_lines()
    return ai._card.buf and api.nvim_buf_get_lines(ai._card.buf, 0, -1, false) or {}
  end
  ai.ask('tool write_file {"path":"made.txt","content":"hi\\n"}')
  local saw_working = vim.wait(5000, function()
    return (card_lines()[1] or ""):find("editing made.txt", 1, true) ~= nil or done ~= nil
  end, 5)
  vim.wait(10000, function()
    return done ~= nil
  end, 10)
  check("a request: the model's tool call runs in Neovim", done and done.kind == "done" and exists("made.txt")
    and done.text == "write_file -> Created made.txt", done)
  check("the card says what it's doing, then the reply", saw_working and (card_lines()[1] or ""):find("✓") ~= nil
    and (card_lines()[2] or ""):find("Created made.txt", 1, true) ~= nil, card_lines())
  local state = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath("state") .. "/ai.json"), ""))
  -- The project as Neovim sees it (on macOS /var/folders is /private/var/folders).
  check("the project's conversation is remembered", type(state[vim.fs.normalize(vim.fn.getcwd())]) == "string", state)
  done = nil
  ai.ask("count")
  vim.wait(10000, function()
    return done ~= nil
  end, 10)
  check("follow-ups continue the conversation", done and done.text == "turns: 2", done)
  done = nil
  ai.ask("hang")
  vim.wait(3000, function()
    return (card_lines()[1] or ""):find("thinking") ~= nil
  end, 10)
  vim.wait(200)
  api.nvim_feedkeys(api.nvim_replace_termcodes("<C-q>", true, false, true), "x", false)
  vim.wait(5000, function()
    return done ~= nil
  end, 10)
  check("Ctrl+Q stops it", done and done.kind == "error" and done.text == "Stopped.", done)
  vim.cmd("Ai log")
  local log = api.nvim_buf_get_lines(0, 0, -1, false)
  check(":Ai log: requests, what it did, replies", vim.tbl_contains(log, "- created made.txt") and vim.tbl_contains(log, "turns: 2"), log)
  vim.cmd("close")
  vim.cmd("Ai new")
  done = nil
  ai.ask("count")
  vim.wait(10000, function()
    return done ~= nil
  end, 10)
  check(":Ai new starts a fresh conversation", done and done.text == "turns: 1", done)
  -- In the sidebar, whose own Esc mapping hides the key from the card.
  require("yeyito.sidebar").open()
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
  vim.wait(200)
  require("yeyito.sidebar").close()
  check("Esc puts the card away (even in the sidebar)", not (ai._card.win and api.nvim_win_is_valid(ai._card.win)))
  pcall(function()
    proc:kill("sigterm")
  end)
  proc:wait(3000)
  os.remove(sock)
end

-- The request box: all of Vim. Typing needs the main loop, so these run as
-- timed steps (feedkeys "x!" would block in insert mode).
local steps = {}
local function step(fn)
  steps[#steps + 1] = fn
end
local function send(k)
  api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "m", false)
end
local function box()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).zindex == 220 then
      return win
    end
  end
end
local function badge()
  local frame = box()
  if not frame then
    return nil
  end
  local ns = api.nvim_create_namespace("yeyito.sidebar.modal")
  for _, m in ipairs(api.nvim_buf_get_extmarks(api.nvim_win_get_buf(frame), ns, 0, 0, { details = true })) do
    if m[4].virt_text then
      return vim.trim(m[4].virt_text[1][1])
    end
  end
end
local function field()
  return table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end
local asked
step(function()
  vim.cmd.edit(dir .. "/src/app.py")
  ai.open(nil)
  send("fix this")
end)
step(function()
  check("the box opens in insert mode, saying so", api.nvim_get_mode().mode == "i" and badge() == "INSERT", badge())
  send("<Esc>")
end)
step(function()
  check("Esc: normal mode, still in the box", box() ~= nil and api.nvim_get_mode().mode == "n" and badge() == "NORMAL", badge())
  send("0cwrename<Esc>")
end)
step(function()
  check("vim edits (cw)", field() == "rename this", field())
  send("v")
end)
step(function()
  check("visual mode shows", badge() == "VISUAL", badge())
  send("<Esc>osecond line<Esc>")
end)
step(function()
  local frame = box()
  check("o adds a line, and the box grows", field() == "rename this\nsecond line" and api.nvim_win_get_height(0) == 2
    and frame and api.nvim_win_get_height(frame) == 4, field())
  send("<Esc>")
end)
step(function()
  check("Esc in normal mode closes it", box() == nil)
  ai.open(nil)
end)
step(function()
  check("the next box starts from what was typed", field() == "rename this\nsecond line", field())
  ai.ask = function(text)
    asked = text
  end
  send("<Esc><CR>")
end)
step(function()
  check("Enter in normal mode sends it (all of it)", asked == "rename this\nsecond line" and box() == nil, asked)
  ai.open(nil)
end)
step(function()
  check("then the box starts empty", field() == "", field())
  send("one<S-CR>two<CR>")
end)
step(function()
  check("Shift+Enter adds a line; Enter in insert mode sends", asked == "one\ntwo", asked)
end)

local function next_step(i)
  if i > #steps then
    files.trash_root = nil
    vim.fn.delete(dir, "rf")
    vim.fn.delete(trash, "rf")
    io.stdout:write(failures .. " failure(s)\n")
    vim.cmd(failures == 0 and "qa!" or "cq!")
    return
  end
  local ok, e = pcall(steps[i])
  if not ok then
    io.stdout:write("ERROR step " .. i .. ": " .. tostring(e) .. "\n")
    failures = failures + 1
  end
  vim.defer_fn(function()
    next_step(i + 1)
  end, 150)
end
next_step(1)
