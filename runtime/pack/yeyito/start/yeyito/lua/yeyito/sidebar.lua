-- File sidebar, the Exocortex TUI's sidebar for files: the working directory
-- as a tree on the left, 28 columns with its border, in the same colors.
--   Ctrl+S   open it focused on the current file, or close it back to the editor
--   Tab      switch focus between it and the editor while it is open
-- In the sidebar: j/k move; Enter, l or a click opens a file in the editor
-- (focus stays here, as in Exocortex) or opens/closes a folder; h/Backspace
-- closes the folder; i/a go back to the editor; q closes; R reloads. The
-- tree follows the filesystem as files appear and go, and the editor's
-- current file is shown bold.
local M = {}

local api, uv = vim.api, vim.uv
local colors = require("yeyito.colors")

local WIDTH = 28 -- with the border column, as in Exocortex
local INDENT = "  "
local FILETYPE = "yeyito-sidebar"
local ns = api.nvim_create_namespace("yeyito.sidebar")
local marker_ns = api.nvim_create_namespace("yeyito.sidebar.marker")

local root ---@type string?
local buf ---@type integer?
local expanded = {} ---@type table<string, true>
local children = {} ---@type table<string, {name: string, path: string, dir: boolean}[]>
local rows = {} ---@type {name: string, path: string, dir: boolean, depth: integer}[]
local watchers = {} ---@type table<string, uv.uv_fs_event_t>
local main_win = {} ---@type table<integer, integer> tabpage -> editor window files open in
local saved_guicursor ---@type string?

local function sidebar_win(tab)
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab or 0)) do
    if buf and api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

local function is_editor_win(win)
  return api.nvim_win_get_config(win).relative == "" and api.nvim_win_get_buf(win) ~= buf
end

--- The window files open in: the last editor window used in this tab page.
local function editor_win()
  local tab = api.nvim_get_current_tabpage()
  local win = main_win[tab]
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) == tab and is_editor_win(win) then
    return win
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if is_editor_win(w) then
      return w
    end
  end
end

-- ── Tree ──────────────────────────────────────────────────────────────────

local function scan(dir)
  local list = {}
  local handle = uv.fs_scandir(dir)
  while handle do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name ~= ".git" then
      local path = vim.fs.joinpath(dir, name)
      local is_dir = kind == "directory"
      if kind == "link" then
        local stat = uv.fs_stat(path)
        is_dir = stat ~= nil and stat.type == "directory"
      end
      list[#list + 1] = { name = name, path = path, dir = is_dir }
    end
  end
  table.sort(list, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then
      return la < lb
    end
    return a.name < b.name
  end)
  children[dir] = list
  return list
end

local refresh

-- Folders on screen are watched, so files the shell or an agent creates show up.
local function watch(dir)
  if watchers[dir] then
    return
  end
  local handle = uv.new_fs_event()
  if not handle then
    return
  end
  local ok = pcall(handle.start, handle, dir, {}, function()
    vim.schedule(function()
      children[dir] = nil
      refresh(true)
    end)
  end)
  if ok then
    watchers[dir] = handle
  else
    handle:close()
  end
end

local function unwatch_all()
  for dir, handle in pairs(watchers) do
    handle:stop()
    handle:close()
    watchers[dir] = nil
  end
end

local function build()
  rows = {}
  local watched = { [root] = true }
  local function walk(dir, depth)
    for _, entry in ipairs(children[dir] or scan(dir)) do
      rows[#rows + 1] = { name = entry.name, path = entry.path, dir = entry.dir, depth = depth }
      if entry.dir and expanded[entry.path] then
        watched[entry.path] = true
        walk(entry.path, depth + 1)
      end
    end
  end
  walk(root, 0)
  for dir, handle in pairs(watchers) do
    if not watched[dir] then
      handle:stop()
      handle:close()
      watchers[dir] = nil
    end
  end
  for dir in pairs(watched) do
    watch(dir)
  end
end

-- ── Drawing ───────────────────────────────────────────────────────────────

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. char .. "…") > width then
      break
    end
    out = out .. char
  end
  return out .. "…"
end

local function label(row)
  if row.dir then
    return (expanded[row.path] and "📂 " or "📁 ") .. row.name .. "/"
  end
  return row.name
end

local function cursor_row(win)
  return rows[api.nvim_win_get_cursor(win)[1]]
end

--- "▸ " on the selected row, as Exocortex marks its selection.
local function draw_marker()
  local win = sidebar_win()
  if not (buf and win) then
    return
  end
  api.nvim_buf_clear_namespace(buf, marker_ns, 0, -1)
  local line = api.nvim_win_get_cursor(win)[1]
  if rows[line] then
    api.nvim_buf_set_extmark(buf, marker_ns, line - 1, 0, {
      virt_text = { { "▸ ", "YeyitoSidebarMarker" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
end

--- The editor's current file is bold.
local function draw_current()
  if not buf then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local win = editor_win()
  local current = win and vim.fs.normalize(api.nvim_buf_get_name(api.nvim_win_get_buf(win))) or ""
  for i, row in ipairs(rows) do
    if not row.dir and row.path == current then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #api.nvim_buf_get_lines(buf, i - 1, i, true)[1], hl_group = "YeyitoSidebarCurrent" })
    end
  end
end

local function header()
  local name = vim.fn.fnamemodify(root, ":t")
  if name == "" then
    name = root
  end
  return "%#YeyitoSidebarHeader# " .. truncate(name, WIDTH - 3):gsub("%%", "%%%%")
end

local function render(keep_path)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local win = sidebar_win()
  keep_path = keep_path or (win and (cursor_row(win) or {}).path)
  build()
  local lines = {}
  local target
  for i, row in ipairs(rows) do
    local indent = "  " .. INDENT:rep(row.depth)
    lines[i] = indent .. truncate(label(row), WIDTH - 1 - #indent)
    if row.path == keep_path then
      target = i
    end
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if win then
    vim.wo[win].winbar = header()
    if target then
      api.nvim_win_set_cursor(win, { target, 0 })
    end
  end
  draw_current()
  draw_marker()
end

local refresh_timer ---@type uv.uv_timer_t?

--- Re-read the tree. `soon`: debounce bursts of filesystem events.
function refresh(soon)
  if not sidebar_win() then
    return
  end
  if not soon then
    children = {}
    render()
    return
  end
  refresh_timer = refresh_timer or uv.new_timer()
  refresh_timer:stop()
  refresh_timer:start(100, 0, vim.schedule_wrap(function()
    render()
  end))
end

--- Expand the folders down to `path` and select it.
local function reveal(path)
  if not (root and path and path ~= "" and vim.startswith(path, root .. "/")) then
    return
  end
  local dir = vim.fs.dirname(path)
  while dir and dir ~= root and #dir > #root do
    expanded[dir] = true
    dir = vim.fs.dirname(dir)
  end
  render(path)
end

-- ── Actions ───────────────────────────────────────────────────────────────

local function focus_editor()
  local win = editor_win()
  if win then
    api.nvim_set_current_win(win)
  end
end

local function open_file(path)
  local win = editor_win()
  if not win then
    vim.cmd("botright vnew")
    win = api.nvim_get_current_win()
    main_win[api.nvim_get_current_tabpage()] = win
  end
  api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  draw_current()
end

local function activate()
  local win = sidebar_win()
  local row = win and cursor_row(win)
  if not row then
    return
  end
  if row.dir then
    expanded[row.path] = not expanded[row.path] or nil
    render(row.path)
  else
    open_file(row.path)
  end
end

local function collapse()
  local win = sidebar_win()
  local row = win and cursor_row(win)
  if not row then
    return
  end
  if row.dir and expanded[row.path] then
    expanded[row.path] = nil
    render(row.path)
    return
  end
  local parent = vim.fs.dirname(row.path)
  if parent ~= root and expanded[parent] then
    expanded[parent] = nil
    render(parent)
  end
end

local function set_focused_look(win, focused)
  vim.wo[win].winhighlight = table.concat({
    "Normal:YeyitoSidebar",
    "NormalNC:YeyitoSidebar",
    "CursorLine:YeyitoSidebarSel",
    "EndOfBuffer:YeyitoSidebarEnd",
    "StatusLine:YeyitoSidebarStatus",
    "StatusLineNC:YeyitoSidebarStatus",
    "WinBar:YeyitoSidebarHeader",
    "WinBarNC:YeyitoSidebarHeader",
    "WinSeparator:" .. (focused and "YeyitoSidebarBorderFocused" or "YeyitoSidebarBorder"),
  }, ",")
  -- No terminal cursor in the sidebar: the selected row is the cursor.
  if focused and not saved_guicursor then
    saved_guicursor = vim.o.guicursor
    vim.o.guicursor = saved_guicursor .. ",n-v:block-YeyitoSidebarCursor"
  elseif not focused and saved_guicursor then
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
end

local function get_buf()
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "sidebar://files")
  vim.bo[buf].filetype = FILETYPE
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].undolevels = -1
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", activate, "Open file / open or close folder")
  map("l", activate, "Open file / open or close folder")
  map("<LeftRelease>", function()
    -- A click on a row; not the header, the border or the end of a drag.
    local pos = vim.fn.getmousepos()
    if pos.winid == sidebar_win() and pos.line > 0 and pos.winrow > 1 then
      activate()
    end
  end, "Open file / open or close folder")
  map("h", collapse, "Close folder")
  map("<BS>", collapse, "Close folder")
  map("i", focus_editor, "Back to the editor")
  map("a", focus_editor, "Back to the editor")
  map("q", function()
    M.close()
  end, "Close the sidebar")
  map("R", function()
    refresh()
  end, "Reload the tree")
  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local win = api.nvim_get_current_win()
      if api.nvim_win_get_cursor(win)[2] ~= 0 then
        api.nvim_win_set_cursor(win, { api.nvim_win_get_cursor(win)[1], 0 })
      end
      draw_marker()
    end,
  })
  return buf
end

-- ── Open / close ──────────────────────────────────────────────────────────

--- Open the sidebar focused, on the editor's current file.
function M.open()
  local current = api.nvim_get_current_win()
  if is_editor_win(current) then
    main_win[api.nvim_get_current_tabpage()] = current
  end
  root = vim.fs.normalize(vim.fn.getcwd())
  local file = vim.fs.normalize(api.nvim_buf_get_name(0))
  local win = sidebar_win()
  if not win then
    win = api.nvim_open_win(get_buf(), true, { split = "left", win = -1, width = WIDTH - 1 })
    local wo = vim.wo[win]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.statuscolumn = ""
    wo.colorcolumn = ""
    wo.cursorline = true
    wo.wrap = false
    wo.list = false
    wo.spell = false
    wo.foldenable = false
    wo.winfixwidth = true
    wo.winfixbuf = true
    wo.fillchars = "eob: "
    wo.statusline = "%#YeyitoSidebarStatus#"
    set_focused_look(win, true)
  else
    api.nvim_set_current_win(win)
  end
  children = {}
  render()
  reveal(file)
end

--- Close it, back to the editor.
function M.close()
  local win = sidebar_win()
  if not win then
    return
  end
  if api.nvim_get_current_win() == win then
    focus_editor()
  end
  if #vim.tbl_filter(is_editor_win, api.nvim_tabpage_list_wins(0)) == 0 then
    vim.cmd("botright vnew")
  end
  api.nvim_win_close(win, false)
end

function M.toggle()
  if sidebar_win() then
    M.close()
  else
    M.open()
  end
end

--- Tab: switch between the sidebar and the editor; without the sidebar, Tab
--- keeps its usual meaning (CTRL-I, newer jump).
function M.tab()
  local win = sidebar_win()
  if not win then
    vim.cmd(("normal! %d\t"):format(vim.v.count1))
  elseif api.nvim_get_current_win() == win then
    focus_editor()
  else
    api.nvim_set_current_win(win)
  end
end

local function highlights()
  local set = colors.set_hl
  set(0, "YeyitoSidebar", { fg = "#646464", bg = "#030814" })
  set(0, "YeyitoSidebarSel", { fg = "#ffffff", bg = "#0f193c" })
  set(0, "YeyitoSidebarMarker", { fg = "#ffffff" })
  set(0, "YeyitoSidebarCurrent", { fg = "#ffffff", bold = true })
  set(0, "YeyitoSidebarHeader", { fg = "#ffffff", bg = "#030814", bold = true })
  set(0, "YeyitoSidebarEnd", { fg = "#030814", bg = "#030814" })
  set(0, "YeyitoSidebarStatus", { fg = "#030814", bg = "#030814" })
  set(0, "YeyitoSidebarBorder", { fg = "#555555", bg = colors.palette.bg })
  set(0, "YeyitoSidebarBorderFocused", { fg = "#1c94e5", bg = colors.palette.bg })
  api.nvim_set_hl(0, "YeyitoSidebarCursor", { blend = 100, bg = "#030814", fg = "#030814" })
end

function M.setup()
  highlights()
  vim.keymap.set("n", "<C-s>", M.toggle, { desc = "File sidebar: open focused / close" })
  vim.keymap.set("x", "<C-s>", "<Esc><Cmd>lua require('yeyito.sidebar').toggle()<CR>", { desc = "File sidebar: open focused / close" })
  vim.keymap.set("i", "<C-s>", "<Esc><Cmd>lua require('yeyito.sidebar').toggle()<CR>", { desc = "File sidebar: open focused / close" })
  vim.keymap.set("n", "<Tab>", M.tab, { desc = "Switch between the file sidebar and the editor" })

  local group = api.nvim_create_augroup("yeyito.sidebar", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      local side = sidebar_win()
      if side then
        set_focused_look(side, win == side)
      end
      if is_editor_win(win) then
        main_win[api.nvim_get_current_tabpage()] = win
      end
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      if sidebar_win() and api.nvim_get_current_buf() ~= buf then
        draw_current()
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "ShellCmdPost" }, {
    group = group,
    callback = function()
      refresh(true)
    end,
  })
  api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      if sidebar_win() then
        root = vim.fs.normalize(vim.fn.getcwd())
        expanded = {}
        refresh()
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      if tonumber(args.match) == sidebar_win() then
        vim.schedule(function()
          if not sidebar_win() then
            unwatch_all()
            if saved_guicursor then
              vim.o.guicursor = saved_guicursor
              saved_guicursor = nil
            end
          end
        end)
      end
    end,
  })
  -- :q in the last editor window quits instead of leaving the sidebar alone.
  api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local side = sidebar_win()
      local win = api.nvim_get_current_win()
      if side and win ~= side then
        local editors = vim.tbl_filter(is_editor_win, api.nvim_tabpage_list_wins(0))
        if #editors == 1 and editors[1] == win then
          api.nvim_win_close(side, true)
        end
      end
    end,
  })
end

return M
