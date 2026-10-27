-- File sidebar, the Exocortex TUI's sidebar for files: the working directory
-- as a tree on the left, 28 columns with its border, in the same colors,
-- running the full height of the screen (the command line and messages stay
-- beside it, with ui2: see yeyito/init.lua).
--   Ctrl+S   open it focused on the current file, or close it back to the editor
--   Tab      switch focus between it and the editor while it is open
-- In the sidebar: j/k move; Enter, l or a click opens a file in the editor
-- (focus stays here, as in Exocortex) or opens/closes a folder; h/Backspace
-- closes the folder; i/a go back to the editor; q closes; R reloads. The
-- tree follows the filesystem as files appear and go, and the editor's
-- current file is shown bold.
-- Like Exocortex's sidebar it has its own command line, in its bottom row:
--   / ?      search forward/backward: the list is filtered to the files and
--            folders of the whole project whose name matches (the path when
--            the search has a /), live as you type; Enter keeps the filter,
--            Esc goes back
--   n N      next/previous match
--   :        sidebar command: :noh clears the filter and shows the selection in
--            the tree; anything else runs as an Ex command in the editor
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

-- Search: the list is filtered to `query` while `filter` is on (until :noh).
local search = {
  query = "", ---@type string Last search entered with Enter.
  direction = "forward", ---@type "forward"|"backward"
  filter = false,
  -- Every file and folder of the project, in tree order: the last complete
  -- build, for `index_root`. A fresh one builds in the background (`job`)
  -- each time a search starts; until it lands, searches use this one.
  index = nil, ---@type table[]?
  by_path = nil, ---@type table<string, table>? path -> index entry
  index_root = nil, ---@type string?
  job = nil, ---@type table?
  -- Enter or n with no index yet: { from, direction } to select from once it lands.
  pending = nil, ---@type table?
  memo = nil, ---@type table? the last matches(): { index, query, list }
}
-- The sidebar's own command line while it is open: { mode = "search"|"command",
-- direction, saved = the selection it started from, win, buf, shown = the
-- input the list is filtered to }.
local bar ---@type table?
-- The strip below the sidebar's list (its status line and the command line
-- rows), so the sidebar runs to the bottom of the screen.
local foot = { win = nil, buf = nil } ---@type { win: integer?, buf: integer? }
local foot_ns = api.nvim_create_namespace("yeyito.sidebar.foot")
local match_ns = api.nvim_create_namespace("yeyito.sidebar.match")

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

-- Tree order (folders first, case-insensitive) for project-relative entries
-- with `rel` and `dir`.
local function parts_of(e)
  e.parts = e.parts or vim.split(e.rel, "/", { plain = true })
  return e.parts
end

local function tree_less(a, b)
  local ap, bp = parts_of(a), parts_of(b)
  for i = 1, math.min(#ap, #bp) do
    local pa, pb = ap[i], bp[i]
    if pa ~= pb then
      local da, db = i < #ap or a.dir, i < #bp or b.dir
      if da ~= db then
        return da
      end
      local la, lb = pa:lower(), pb:lower()
      if la ~= lb then
        return la < lb
      end
      return pa < pb
    end
  end
  return #ap < #bp
end

--- `a` comes before `b` in the tree: by their places in the index when both
--- are in it.
local function before(a, b)
  local ia, ib = search.by_path and search.by_path[a.path], search.by_path and search.by_path[b.path]
  if ia and ib then
    return ia.order < ib.order
  end
  return tree_less(a, b)
end

local function entry(path, dir)
  local rel = path:sub(#root + 2)
  local parts = vim.split(rel, "/", { plain = true })
  return { rel = rel, name = parts[#parts], path = path, dir = dir, parts = parts, depth = 0 }
end

-- ── Search index ──────────────────────────────────────────────────────────
-- Built in slices between keystrokes, so a big folder (a home directory
-- has hundreds of thousands of files) never freezes the editor.

local INDEX_MAX = 50000 -- entries, in a folder that isn't a git repository
local SLICE = 8e6 -- ns of index work per turn of the main loop
local SCANS = 4 -- folders being listed at once, off the main thread
local SCAN_TIMEOUT = 2000 -- ms a folder may take to list before it is skipped
-- Not searched into: macOS's app data, hidden by Finder. Other apps' folders
-- in it (Group Containers) can block whoever lists them indefinitely.
local SKIP = uv.os_uname().sysname == "Darwin" and uv.os_homedir() .. "/Library" or nil

local index_ready ---@type fun()

local function add_kid(kids, parent, name, dir)
  local items = kids[parent]
  if not items then
    items = {}
    kids[parent] = items
  end
  items[#items + 1] = { name = name, lname = name:lower(), dir = dir }
end

--- git's view of the project: tracked and untracked files, not ignored ones.
local function from_git(out, kids, check)
  local seen = {}
  for rel in out:gmatch("[^%z]+") do
    local parent, start = "", 1
    while true do
      local slash = rel:find("/", start, true)
      if not slash then
        break
      end
      local dir = rel:sub(1, slash - 1)
      if not seen[dir] then
        seen[dir] = true
        add_kid(kids, parent, rel:sub(start, slash - 1), true)
      end
      parent, start = dir, slash + 1
    end
    local name = rel:sub(start)
    if name ~= "" and not seen[rel] then
      seen[rel] = true
      add_kid(kids, parent, name, false)
    end
    check()
  end
end

--- Outside a repository: the folders breadth first, so with more than
--- INDEX_MAX entries the ones nearest the root are the ones kept. They are
--- listed off the main thread, SCANS at a time, so a folder that is slow to
--- open (on a network or in the cloud) never blocks the editor: after
--- SCAN_TIMEOUT it is skipped. What they hold is taken in slices of the main
--- loop (a folder can hold 30,000 files). `done` runs once it is all in `kids`.
local function walk(job, kids, done)
  local prefix = job.root == "/" and "/" or job.root .. "/"
  local queue, head, count, busy, finished = { "" }, 1, 0, 0, false
  local listed = {} ---@type { rel: string, handle: uv.uv_fs_t }[] folders whose entries aren't taken yet
  local taking = false
  local next_folders
  local function take()
    taking = false
    if search.job ~= job then
      return
    end
    local deadline = uv.hrtime() + SLICE
    while listed[1] and count < INDEX_MAX and uv.hrtime() < deadline do
      local folder = listed[1]
      local name, kind = uv.fs_scandir_next(folder.handle)
      if not name then
        table.remove(listed, 1)
      elseif name ~= ".git" then
        local rel = folder.rel
        local path = rel == "" and name or rel .. "/" .. name
        local is_dir = kind == "directory"
        if kind ~= "directory" and kind ~= "file" then -- a link, or a filesystem that doesn't say
          local stat = uv.fs_stat(prefix .. path)
          is_dir = stat ~= nil and stat.type == "directory"
        end
        add_kid(kids, rel, name, is_dir)
        count = count + 1
        -- Not into linked folders: they can loop.
        if is_dir and kind ~= "link" and prefix .. path ~= SKIP then
          queue[#queue + 1] = path
        end
      end
    end
    if count >= INDEX_MAX then
      listed = {}
    end
    next_folders()
  end
  next_folders = function()
    if search.job ~= job or finished then
      return
    end
    while busy < SCANS and queue[head] and count < INDEX_MAX do
      local rel = queue[head]
      head = head + 1
      busy = busy + 1
      local settled = false
      local timer = uv.new_timer()
      timer:start(SCAN_TIMEOUT, 0, function()
        timer:close()
        if not settled then
          settled, busy = true, busy - 1
          next_folders()
        end
      end)
      uv.fs_scandir(prefix .. rel, function(_, handle)
        if settled then
          return -- too late: skipped
        end
        settled, busy = true, busy - 1
        timer:stop()
        timer:close()
        if handle then
          listed[#listed + 1] = { rel = rel, handle = handle }
        end
        next_folders()
      end)
    end
    if listed[1] then
      if not taking then
        taking = true
        vim.defer_fn(take, 1) -- a timer, so keys typed meanwhile go first
      end
    elseif busy == 0 and (not queue[head] or count >= INDEX_MAX) then
      finished = true
      vim.schedule(done)
    end
  end
  next_folders()
end

--- The entries in tree order: each folder's contents sorted as the tree
--- sorts them, after the folder.
local function emit(dir, kids, check)
  local function less(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    if a.lname ~= b.lname then
      return a.lname < b.lname
    end
    return a.name < b.name
  end
  -- A merge sort, which can stop between runs (table.sort can't stop halfway
  -- through a folder of 30,000 files, and is no faster with a Lua comparator).
  local function sorted(items)
    local n = #items
    local src, dst, width = items, {}, 1
    while width < n do
      for i = 1, n, 2 * width do
        local mid, hi = math.min(i + width, n + 1), math.min(i + 2 * width, n + 1)
        local a, b = i, mid
        for k = i, hi - 1 do
          if b >= hi or (a < mid and not less(src[b], src[a])) then
            dst[k], a = src[a], a + 1
          else
            dst[k], b = src[b], b + 1
          end
        end
        check()
      end
      src, dst, width = dst, src, width * 2
    end
    return src
  end
  local list, by_path = {}, {}
  local prefix = dir == "/" and "/" or dir .. "/"
  local stack = { { rel = "", i = 0, items = sorted(kids[""] or {}) } }
  while #stack > 0 do
    local top = stack[#stack]
    top.i = top.i + 1
    local k = top.items[top.i]
    if not k then
      stack[#stack] = nil
    else
      local rel = top.rel == "" and k.name or top.rel .. "/" .. k.name
      local e = { rel = rel, name = k.name, lname = k.lname, path = prefix .. rel, dir = k.dir, depth = 0, order = #list + 1 }
      list[#list + 1] = e
      by_path[e.path] = e
      if k.dir and kids[rel] then
        stack[#stack + 1] = { rel = rel, i = 0, items = sorted(kids[rel]) }
      end
      check()
    end
  end
  return list, by_path
end

--- Build the index of the root anew in the background (unless that is
--- already happening); `index_ready` runs when it lands.
local function start_index()
  if search.job and search.job.root == root then
    return
  end
  local job = { root = root }
  search.job = job
  local kids = {}
  local deadline = 0
  local function check()
    if uv.hrtime() > deadline then
      coroutine.yield()
    end
  end
  -- In slices on the main loop: git's list into folders, then tree order.
  local co = coroutine.create(function(git_out)
    if git_out then
      from_git(git_out, kids, check)
    end
    return emit(job.root, kids, check)
  end)
  local function resume(git_out)
    if search.job ~= job then
      return -- superseded or cancelled
    end
    deadline = uv.hrtime() + SLICE
    local ok, list, by_path = coroutine.resume(co, git_out)
    if not ok then
      search.job = nil
      vim.notify("sidebar search index: " .. tostring(list), vim.log.levels.WARN)
    elseif coroutine.status(co) ~= "dead" then
      vim.defer_fn(resume, 1) -- a timer, so keys typed meanwhile go first
    else
      search.job = nil
      search.index, search.by_path, search.index_root, search.memo = list, by_path, job.root, nil
      index_ready()
    end
  end
  local function no_git()
    walk(job, kids, resume)
  end
  local cmd = { "git", "-C", job.root, "ls-files", "-z", "--cached", "--others", "--exclude-standard" }
  local ok = pcall(vim.system, cmd, {}, function(res)
    vim.schedule(function()
      if res.code == 0 then
        resume(res.stdout or "")
      elseif search.job == job then
        no_git()
      end
    end)
  end)
  if not ok then -- no git
    vim.schedule(no_git)
  end
end

--- The index of the root, if one has been built.
local function current_index()
  return search.index_root == root and search.index or nil
end

--- Entries matching `query`: case-insensitive, in the name, or in the
--- project-relative path when the query has a /. Empty while there is no
--- index yet (it starts building).
local function matches(query)
  local index = current_index()
  if not index then
    start_index()
    return {}
  end
  local memo = search.memo
  if memo and memo.index == index and memo.query == query then
    return memo.list
  end
  local lq, by_path = query:lower(), query:find("/", 1, true)
  local out = {}
  for _, e in ipairs(index) do
    local hay = e.lname
    if by_path then
      hay = e.lrel or e.rel:lower()
      e.lrel = hay
    end
    if hay:find(lq, 1, true) then
      out[#out + 1] = e
    end
  end
  search.memo = { index = index, query = query, list = out }
  return out
end

--- The match after (or before) `from` in tree order, wrapping; `from` is an
--- entry or nil (start from the top or bottom).
local function next_match(list, from, direction)
  if #list == 0 then
    return nil
  end
  if direction == "forward" then
    for _, e in ipairs(list) do
      if not from or before(from, e) then
        return e
      end
    end
    return list[1]
  end
  for i = #list, 1, -1 do
    if not from or before(list[i], from) then
      return list[i]
    end
  end
  return list[#list]
end

--- The filter shown now: what is typed in an open search bar, else the last
--- search until :noh.
local function active_query()
  if bar and bar.mode == "search" and bar.buf and api.nvim_buf_is_valid(bar.buf) then
    local input = api.nvim_buf_get_lines(bar.buf, 0, 1, false)[1] or ""
    if input ~= "" then
      return input
    end
  end
  return search.filter and search.query ~= "" and search.query or nil
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
  local query = active_query()
  if query then
    rows = matches(query)
    return
  end
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

-- Columns of "…" ('ambiwidth'), read again by each render.
local ellipsis = 1

--- Printable ASCII: as many columns as bytes. (A byte loop: LuaJIT compiles
--- it, but not a pattern with a character class, which costs 50x more.)
local function plain(text)
  for i = 1, #text do
    local c = text:byte(i)
    if c < 32 or c > 126 then
      return false
    end
  end
  return true
end

local function truncate(text, width)
  local ascii = plain(text)
  if ascii and #text <= width then
    return text
  end
  if ascii then
    return text:sub(1, width - ellipsis) .. "…"
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local out, used = {}, ellipsis
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    used = used + vim.fn.strdisplaywidth(char)
    if used > width then
      break
    end
    out[#out + 1] = char
  end
  return table.concat(out) .. "…"
end

--- Keep the end of `text` (the file name) when it is too wide.
local function truncate_left(text, width)
  local ascii = plain(text)
  if ascii and #text <= width then
    return text
  end
  if ascii then
    return "…" .. text:sub(#text - (width - ellipsis) + 1)
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local chars = vim.fn.split(text, "\\zs")
  local out, used = {}, ellipsis
  for i = #chars, 1, -1 do
    used = used + vim.fn.strdisplaywidth(chars[i])
    if used > width then
      break
    end
    table.insert(out, 1, chars[i])
  end
  return "…" .. table.concat(out)
end

--- A name as it can be shown: a newline or other control character in it
--- (a buffer line can't hold a newline) is a "?".
local function printable(name)
  return not plain(name) and name:find("%c") and (name:gsub("%c", "?")) or name
end

local function label(row)
  if row.rel then -- a search match: its path in the project
    return (row.dir and "📁 " or "") .. truncate_left(printable(row.rel) .. (row.dir and "/" or ""), WIDTH - 3 - (row.dir and 3 or 0))
  end
  if row.dir then
    return (expanded[row.path] and "📂 " or "📁 ") .. printable(row.name) .. "/"
  end
  return printable(row.name)
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

-- Matches are highlighted like a search in the editor, on the rows being
-- drawn: a filter with thousands of matches costs a screenful.
local shown_query ---@type string? the filter shown, lowercased
local function highlight_matches()
  api.nvim_set_decoration_provider(match_ns, {
    on_win = function(_, _, b)
      return b == buf and shown_query ~= nil
    end,
    on_line = function(_, _, b, row)
      if not rows[row + 1] then
        return -- "no matches"
      end
      local line = (api.nvim_buf_get_lines(b, row, row + 1, false)[1] or ""):lower()
      local from = 1
      while true do
        local s, e = line:find(shown_query, from, true)
        if not s then
          break
        end
        api.nvim_buf_set_extmark(b, match_ns, row, s - 1, {
          end_col = e,
          hl_group = "YeyitoSidebarMatch",
          priority = 300,
          ephemeral = true,
        })
        from = e + 1
      end
    end,
  })
end

local function render(keep_path)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local win = sidebar_win()
  keep_path = keep_path or (win and (cursor_row(win) or {}).path)
  ellipsis = vim.fn.strdisplaywidth("…")
  build()
  local lines = {}
  local target
  for i, row in ipairs(rows) do
    local line = row.line -- a search match keeps its line: the index doesn't change under it
    if row.rel and not line then
      line = "  " .. label(row) -- sized to fit already
      row.line = line
    elseif not line then
      local indent = "  " .. INDENT:rep(row.depth)
      line = indent .. truncate(label(row), WIDTH - 1 - #indent)
    end
    lines[i] = line
    if row.path == keep_path then
      target = i
    end
  end
  local query = active_query()
  if query and #rows == 0 then
    lines = { current_index() and "  no matches" or "  searching…" }
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  shown_query = query and query:lower() or nil
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
  if active_query() then
    render(path)
    return
  end
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

function M.reveal(path)
  reveal(path)
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
  if row.rel and row.dir then
    -- A folder found by a search: leave the search, open it in the tree.
    search.filter = false
    expanded[row.path] = true
    M.reveal(row.path)
    M.update_foot()
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
  if not row or row.rel then
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

-- ── Below the list: foot strip and the sidebar's command line ─────────────

local function ui2()
  local mod = package.loaded["vim._core.ui2"]
  return mod and mod.msg and mod or nil -- enabled
end

local function focused()
  local win = api.nvim_get_current_win()
  return win == sidebar_win() or (bar ~= nil and win == bar.win)
end

local function close_foot()
  if foot.win and api.nvim_win_is_valid(foot.win) then
    api.nvim_win_close(foot.win, true)
  end
  foot.win = nil
end

--- Cover the rows below the list (the sidebar's status line and the command
--- line rows) in the sidebar's colors, border included, and keep the command
--- line and messages to the right of it.
local function update_foot()
  local side = sidebar_win()
  local u = ui2()
  if u then
    u.set_col(side and WIDTH or 0)
  end
  if not (side and u) then
    close_foot()
    return
  end
  local info = vim.fn.getwininfo(side)[1]
  local top = info.winrow - 1 + info.winbar + info.height
  local height = vim.o.lines - top
  if height < 1 then
    close_foot()
    return
  end
  if not (foot.buf and api.nvim_buf_is_valid(foot.buf)) then
    foot.buf = api.nvim_create_buf(false, true)
    vim.bo[foot.buf].bufhidden = "hide"
  end
  local lines = {}
  for i = 1, height do
    lines[i] = (" "):rep(WIDTH - 1) .. "│"
  end
  -- The last search stays on show while the list is filtered, like the
  -- editor's command line shows it.
  if search.filter and search.query ~= "" and not bar then
    local text = " " .. (search.direction == "forward" and "/" or "?") .. search.query
    text = truncate(text, WIDTH - 2)
    lines[height] = text .. (" "):rep(WIDTH - 1 - vim.fn.strdisplaywidth(text)) .. "│"
  end
  api.nvim_buf_set_lines(foot.buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(foot.buf, foot_ns, 0, -1)
  local border = focused() and "YeyitoSidebarBorderFocused" or "YeyitoSidebarBorder"
  for i, line in ipairs(lines) do
    api.nvim_buf_set_extmark(foot.buf, foot_ns, i - 1, #line - #"│", { end_col = #line, hl_group = border })
  end
  local cfg = { relative = "editor", row = top, col = 0, width = WIDTH, height = height }
  if foot.win and api.nvim_win_is_valid(foot.win) and api.nvim_win_get_tabpage(foot.win) == api.nvim_get_current_tabpage() then
    api.nvim_win_set_config(foot.win, cfg)
  else
    close_foot()
    -- zindex 200 (the message layer) is the lowest that may cover the
    -- command line rows; ui2's windows are right of the sidebar, never under.
    cfg.style, cfg.focusable, cfg.mouse, cfg.zindex, cfg.noautocmd = "minimal", false, false, 200, true
    foot.win = api.nvim_open_win(foot.buf, false, cfg)
    vim.wo[foot.win].winhighlight = "Normal:YeyitoSidebar"
    vim.wo[foot.win].signcolumn = "no"
  end
end

M.update_foot = function()
  update_foot()
end

local function selected_entry()
  local win = sidebar_win()
  local row = win and cursor_row(win)
  if not row then
    return nil
  end
  return row.rel and row or entry(row.path, row.dir)
end

--- Close the sidebar's command line; `cancel` puts the selection back.
local function close_bar(cancel)
  if not bar then
    return
  end
  local b = bar
  bar = nil
  if b.win and api.nvim_win_is_valid(b.win) then
    api.nvim_win_close(b.win, true)
  end
  vim.cmd.stopinsert()
  if b.showmode ~= nil then
    vim.o.showmode = b.showmode
  end
  local side = sidebar_win()
  if side then
    api.nvim_set_current_win(side)
    render(cancel and b.saved and b.saved.path or nil)
  end
  update_foot()
end

--- Typing in the search bar: filter to what is typed and select the nearest match.
local function live_search()
  if not (bar and bar.mode == "search") then
    return
  end
  local input = api.nvim_buf_get_lines(bar.buf, 0, 1, false)[1] or ""
  if input == bar.shown then
    return -- several edits queued this; the first one showed it
  end
  bar.shown = input
  local target = bar.saved and bar.saved.path
  if input ~= "" then
    local hit = next_match(matches(input), bar.saved, bar.direction)
    target = hit and hit.path or target
  end
  render(target)
end

--- A new index landed: show the search again with it.
index_ready = function()
  local pending = search.pending
  search.pending = nil
  if not sidebar_win() then
    return
  end
  if bar and bar.mode == "search" then
    bar.shown = nil
    live_search()
  elseif search.filter then
    -- Enter or n waited for it: select the match they would have.
    local hit = pending and next_match(matches(search.query), pending.from, pending.direction)
    render(hit and hit.path or nil)
    update_foot()
  end
end

local function run_command(cmd)
  cmd = vim.trim(cmd)
  if cmd == "" then
    return
  end
  if cmd == "noh" or cmd == "nohl" or cmd == "nohlsearch" then
    local sel = selected_entry()
    search.filter = false
    if sel then
      reveal(sel.path)
    else
      render()
    end
    update_foot()
    return
  end
  -- Anything else is an Ex command for the editor (:w, :e file, :q, ...).
  local side, editor = sidebar_win(), editor_win()
  if editor then
    api.nvim_set_current_win(editor)
  end
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    -- Just "E492: Not an editor command: ...", as the editor's : shows it.
    err = tostring(err)
    vim.notify(err:match("(E%d+:.*)$") or err, vim.log.levels.ERROR)
  end
  if side and api.nvim_win_is_valid(side) and editor and api.nvim_get_current_win() == editor then
    api.nvim_set_current_win(side)
  end
end

local function submit_bar()
  if not bar then
    return
  end
  local b = bar
  local input = api.nvim_buf_get_lines(b.buf, 0, 1, false)[1] or ""
  if b.mode == "command" then
    close_bar(false)
    -- After the bar's insert mode has ended: leaving it clears the command
    -- line, which would take the command's messages with it.
    vim.schedule(function()
      run_command(input)
    end)
    return
  end
  if input == "" then
    close_bar(true)
    return
  end
  search.query, search.direction, search.filter = input, b.direction, true
  if not current_index() then
    search.pending = { from = b.saved, direction = b.direction }
  end
  local hit = next_match(matches(input), b.saved, b.direction)
  close_bar(false)
  render(hit and hit.path or (b.saved and b.saved.path))
  update_foot()
end

--- Open the sidebar's command line in its bottom row: "search" (/ or ?) or "command" (:).
function M.open_bar(mode, direction)
  local side = sidebar_win()
  if not side then
    return
  end
  close_bar(true)
  if mode == "search" then
    start_index() -- the project may have changed since the last search
  end
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  bar = { mode = mode, direction = direction or search.direction, saved = selected_entry(), buf = b, showmode = vim.o.showmode }
  local prompt = mode == "command" and ":" or (bar.direction == "forward" and "/" or "?")
  bar.win = api.nvim_open_win(b, true, {
    relative = "editor",
    row = vim.o.lines - 1,
    col = 0,
    width = WIDTH - 1,
    height = 1,
    style = "minimal",
    zindex = 201, -- over the foot, in the command line row
    noautocmd = true,
  })
  vim.wo[bar.win].winhighlight = "Normal:YeyitoSidebarBar"
  vim.wo[bar.win].wrap = false
  vim.wo[bar.win].signcolumn = "no" -- "minimal" makes it auto: no mark signs here
  local pns = api.nvim_create_namespace("yeyito.sidebar.prompt")
  api.nvim_buf_set_extmark(b, pns, 0, 0, {
    virt_text = { { prompt, "YeyitoSidebarPrompt" }, { " ", "YeyitoSidebarBar" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
  local placeholder ---@type integer?
  local function show_placeholder()
    local empty = (api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") == ""
    if empty and not placeholder then
      placeholder = api.nvim_buf_set_extmark(b, pns, 0, 0, {
        virt_text = { { mode == "command" and "command" or "search", "YeyitoSidebarPlaceholder" } },
        virt_text_pos = "eol",
      })
    elseif not empty and placeholder then
      api.nvim_buf_del_extmark(b, pns, placeholder)
      placeholder = nil
    end
  end
  show_placeholder()
  api.nvim_buf_attach(b, false, {
    on_lines = function()
      vim.schedule(function()
        if bar and bar.buf == b and api.nvim_buf_is_valid(b) then
          show_placeholder()
          live_search()
        end
      end)
    end,
  })
  local function imap(lhs, rhs, opts)
    vim.keymap.set("i", lhs, rhs, vim.tbl_extend("force", { buffer = b, nowait = true }, opts or {}))
  end
  imap("<CR>", submit_bar)
  imap("<Esc>", function()
    close_bar(true)
  end)
  imap("<C-c>", function()
    close_bar(true)
  end)
  imap("<BS>", function()
    if (api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") == "" then
      vim.schedule(function()
        close_bar(true)
      end)
      return ""
    end
    return "<BS>"
  end, { expr = true })
  imap("<Tab>", "")
  imap("<C-s>", function()
    close_bar(true)
    M.close()
  end)
  api.nvim_create_autocmd("WinLeave", {
    buffer = b,
    once = true,
    callback = function()
      vim.schedule(function()
        if bar and bar.buf == b then
          close_bar(true)
        end
      end)
    end,
  })
  -- The bar's insert mode is not the editor's: no "-- INSERT --" beside it.
  vim.o.showmode = false
  update_foot()
  vim.cmd.startinsert()
end

--- n / N: the next / previous match of the last search (shows the filter again).
function M.search_next(reverse)
  if search.query == "" then
    return
  end
  search.filter = true
  local direction = search.direction
  if reverse then
    direction = direction == "forward" and "backward" or "forward"
  end
  if not current_index() then
    search.pending = { from = selected_entry(), direction = direction }
  end
  local hit = next_match(matches(search.query), selected_entry(), direction)
  render(hit and hit.path)
  update_foot()
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
  map("/", function()
    M.open_bar("search", "forward")
  end, "Search the project, forward")
  map("?", function()
    M.open_bar("search", "backward")
  end, "Search the project, backward")
  map(":", function()
    M.open_bar("command")
  end, "Sidebar command (:noh), or an Ex command for the editor")
  map("n", function()
    M.search_next(false)
  end, "Next match")
  map("N", function()
    M.search_next(true)
  end, "Previous match")
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
  update_foot()
end

--- Close it, back to the editor.
function M.close()
  close_bar(true)
  search.job = nil -- no index work while it's closed
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
  set(0, "YeyitoSidebarMatch", { fg = colors.palette.bg, bg = "#fce094" })
  set(0, "YeyitoSidebarBar", { fg = "#ffffff", bg = "#030814" })
  set(0, "YeyitoSidebarPrompt", { fg = "#1d9bf0", bg = "#030814" })
  set(0, "YeyitoSidebarPlaceholder", { fg = "#646464", bg = "#030814" })
  api.nvim_set_hl(0, "YeyitoSidebarCursor", { blend = 100, bg = "#030814", fg = "#030814" })
end

function M.setup()
  highlights()
  highlight_matches()
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
        update_foot()
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
        search.job = nil -- the next search indexes the new root
        refresh()
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      if tonumber(args.match) == sidebar_win() then
        vim.schedule(function()
          update_foot()
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
  -- The rows below the list follow the layout.
  api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
    group = group,
    callback = function()
      update_foot()
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "cmdheight", "laststatus" },
    callback = function()
      vim.schedule(update_foot)
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
