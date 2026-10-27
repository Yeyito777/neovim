-- Marks in the sign column (and their line number highlighted), with
-- marks.nvim's default mappings:
--   m{a-zA-Z}  set mark        m,  next free a-z     m;  toggle on this line
--   dm{x}      delete mark     dm- this line's marks  dm<Space>  all a-z here
--   m] / m[    next/previous mark (wraps)              m:  preview a mark
--   m{0-9}     bookmark line in group N   dm{0-9} clear group N
--   m} / m{    next/previous bookmark of the group under the cursor
--   dm=        delete the bookmark under the cursor
-- Builtin marks . < > ^ are shown too. Deletions rewrite the ShaDa file so
-- deleted marks don't come back from it.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("yeyito.marks")
local bookmark_ns = api.nvim_create_namespace("yeyito.bookmarks")
local BUILTIN = { ".", "<", ">", "^" }

--- Letter marks of `buf` as { mark, line, col } (lowercase, then uppercase).
local function letter_marks(buf)
  local out = {}
  for _, d in ipairs(vim.fn.getmarklist(buf)) do
    local m = d.mark:sub(2, 2)
    if m:match("^%l$") then
      out[#out + 1] = { m, d.pos[2], d.pos[3] - 1 }
    end
  end
  for _, d in ipairs(vim.fn.getmarklist()) do
    local m = d.mark:sub(2, 2)
    if m:match("^%u$") and d.pos[1] == buf then
      out[#out + 1] = { m, d.pos[2], d.pos[3] - 1 }
    end
  end
  return out
end

local shown = {} ---@type table<integer, string>

local function refresh(buf, force)
  buf = buf or api.nvim_get_current_buf()
  if not api.nvim_buf_is_loaded(buf) then
    return
  end
  -- Files only: not the sidebar, ui2's cmdline/pager, help or terminals, where
  -- a sign for the last change ('.') would just push the text aside.
  if vim.bo[buf].buftype ~= "" then
    return
  end
  local marks = letter_marks(buf)
  for _, m in ipairs(BUILTIN) do
    local ok, pos = pcall(api.nvim_buf_get_mark, buf, m)
    if ok and pos[1] > 0 then
      marks[#marks + 1] = { m, pos[1], pos[2] }
    end
  end
  local signature = vim.inspect(marks)
  if not force and shown[buf] == signature then
    return
  end
  shown[buf] = signature

  -- One sign per line. marks.nvim's sign ids were byte(mark) * 100 and the
  -- higher id won, so e.g. b beats ^ beats . on a shared line.
  local top = {} ---@type table<integer, string>
  for _, m in ipairs(marks) do
    if not top[m[2]] or m[1]:byte() > top[m[2]]:byte() then
      top[m[2]] = m[1]
    end
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = api.nvim_buf_line_count(buf)
  for row, name in pairs(top) do
    if row <= lines then
      api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        sign_text = name,
        sign_hl_group = "MarkSignHL",
        number_hl_group = "MarkSignNumHL",
        priority = 10,
      })
    end
  end
end

local function after_delete()
  vim.cmd("wshada!")
  refresh(nil, true)
end

local function set_mark(char)
  vim.cmd("normal! m" .. char)
  refresh()
end

local function next_free()
  local used = {}
  for _, m in ipairs(letter_marks(api.nvim_get_current_buf())) do
    used[m[1]] = true
  end
  for b = ("a"):byte(), ("z"):byte() do
    if not used[string.char(b)] then
      return string.char(b)
    end
  end
end

local function line_marks()
  local line = api.nvim_win_get_cursor(0)[1]
  return vim.tbl_filter(function(m)
    return m[2] == line
  end, letter_marks(api.nvim_get_current_buf()))
end

local function getchar()
  local ok, c = pcall(vim.fn.getcharstr)
  return ok and c or nil
end

local function jump(forward)
  local line = api.nvim_win_get_cursor(0)[1]
  local marks = letter_marks(api.nvim_get_current_buf())
  table.sort(marks, function(a, b)
    return a[2] < b[2]
  end)
  if #marks == 0 then
    return
  end
  local target
  if forward then
    for _, m in ipairs(marks) do
      if m[2] > line then
        target = m
        break
      end
    end
    target = target or marks[1]
  else
    for i = #marks, 1, -1 do
      if marks[i][2] < line then
        target = marks[i]
        break
      end
    end
    target = target or marks[#marks]
  end
  api.nvim_win_set_cursor(0, { target[2], target[3] })
end

local function preview()
  local char = getchar()
  if not char then
    return
  end
  local pos
  if char == "\r" then
    local line = api.nvim_win_get_cursor(0)[1]
    for _, m in ipairs(letter_marks(api.nvim_get_current_buf())) do
      if m[2] > line and (not pos or m[2] < pos[2]) then
        pos = { 0, m[2], m[3] + 1 }
      end
    end
  else
    pos = vim.fn.getpos("'" .. char)
  end
  if not pos or pos[2] == 0 then
    return
  end
  local buf = pos[1] ~= 0 and pos[1] or api.nvim_get_current_buf()
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.5)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " mark " .. char .. " ",
  })
  api.nvim_win_set_cursor(win, { pos[2], math.max(pos[3] - 1, 0) })
  vim.cmd("normal! zz")
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      pcall(api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  api.nvim_create_autocmd("WinLeave", {
    once = true,
    callback = function()
      pcall(api.nvim_win_close, win, true)
      pcall(vim.keymap.del, "n", "q", { buffer = buf })
      pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
    end,
  })
end

-- Bookmarks: extmarks (they move with edits) labelled with their group digit.
local function bookmarks(group)
  local out = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(0, bookmark_ns, 0, -1, { details = true })) do
    if not group or mark[4].sign_text:sub(1, 1) == group then
      out[#out + 1] = mark
    end
  end
  return out
end

local function bookmark_at_cursor()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  for _, mark in ipairs(bookmarks()) do
    if mark[2] == row then
      return mark
    end
  end
end

local function set_bookmark(group)
  local existing = bookmark_at_cursor()
  if existing then
    api.nvim_buf_del_extmark(0, bookmark_ns, existing[1])
  end
  api.nvim_buf_set_extmark(0, bookmark_ns, api.nvim_win_get_cursor(0)[1] - 1, 0, {
    sign_text = group,
    sign_hl_group = "MarkSignHL",
    number_hl_group = "MarkSignNumHL",
    priority = 10,
  })
end

local function jump_bookmark(forward)
  local here = bookmark_at_cursor()
  if not here then
    return
  end
  local list = bookmarks(here[4].sign_text:sub(1, 1))
  table.sort(list, function(a, b)
    return a[2] < b[2]
  end)
  for i, mark in ipairs(list) do
    if mark[1] == here[1] then
      local target = list[forward and (i % #list) + 1 or ((i - 2) % #list) + 1]
      api.nvim_win_set_cursor(0, { target[2] + 1, target[3] })
      return
    end
  end
end

function M.setup()
  vim.api.nvim_set_hl(0, "MarkSignHL", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "MarkSignNumHL", { link = "CursorLineNr", default = true })

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc })
  end
  map("m", function()
    local char = getchar()
    if char and char:match("^[%a%.<>%^'`%[%]]$") then
      set_mark(char)
    end
  end, "Set mark")
  map("m,", function()
    local char = next_free()
    if char then
      set_mark(char)
    end
  end, "Set next free mark")
  map("m;", function()
    local marks = line_marks()
    if #marks > 0 then
      for _, m in ipairs(marks) do
        vim.cmd("delmarks " .. m[1])
      end
      after_delete()
    else
      local char = next_free()
      if char then
        set_mark(char)
      end
    end
  end, "Toggle mark on this line")
  map("dm", function()
    local char = getchar()
    if char and char:match("^[%a%.<>%^%[%]]$") then
      pcall(vim.cmd, "delmarks " .. char)
      after_delete()
    end
  end, "Delete mark")
  map("dm-", function()
    for _, m in ipairs(line_marks()) do
      vim.cmd("delmarks " .. m[1])
    end
    after_delete()
  end, "Delete marks on this line")
  map("dm<Space>", function()
    vim.cmd("delmarks!")
    after_delete()
  end, "Delete all lowercase marks in buffer")
  map("m]", function()
    jump(true)
  end, "Next mark")
  map("m[", function()
    jump(false)
  end, "Previous mark")
  map("m:", preview, "Preview mark")
  for i = 0, 9 do
    local group = tostring(i)
    map("m" .. group, function()
      set_bookmark(group)
    end, "Bookmark line in group " .. group)
    map("dm" .. group, function()
      for _, mark in ipairs(bookmarks(group)) do
        api.nvim_buf_del_extmark(0, bookmark_ns, mark[1])
      end
    end, "Delete bookmark group " .. group)
  end
  map("m}", function()
    jump_bookmark(true)
  end, "Next bookmark in group")
  map("m{", function()
    jump_bookmark(false)
  end, "Previous bookmark in group")
  map("dm=", function()
    local mark = bookmark_at_cursor()
    if mark then
      api.nvim_buf_del_extmark(0, bookmark_ns, mark[1])
    end
  end, "Delete bookmark")

  local group = api.nvim_create_augroup("yeyito.marks", { clear = true })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      refresh(args.buf, true)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      shown[args.buf] = nil
    end,
  })
  -- Marks also move or appear without a mapping (edits, :mark, '. and '^);
  -- poll the current buffer like marks.nvim did.
  local timer = vim.uv.new_timer()
  timer:start(150, 150, vim.schedule_wrap(function()
    refresh()
  end))
end

return M
