-- File sidebar, the Exocortex TUI's sidebar for files: the working directory
-- as a tree on the left, 28 columns with its border, in the same colors,
-- running the full height of the screen (the command line and messages stay
-- beside it, with ui2: see yeyito/init.lua).
--   Ctrl+S   open it focused on the current file, or close it back to the editor
--   Tab      switch focus between it and the editor while it is open (Ctrl+J
--            and Ctrl+K too, as in Exocortex; keymaps.lua)
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
-- And Exocortex's sidebar keys, for files (see yeyito/files.lua):
--   dd       delete to the trash: the row turns red, a second d deletes
--   u C-r    undo / redo the last file operation
--   Ctrl+P   new file in the folder under the cursor (anywhere: also from the
--            editor; Ctrl+Shift+O at the top of the project)
--   f        new folder      r  rename      c  duplicate
--   F        move to a folder (Tab completes)       <  move out of its folder
--   v V      select rows: d, F, f (a new folder for them) and < act on them
--   ;        or a right click: the actions menu
local M = {}

local api, uv = vim.api, vim.uv
local colors = require("yeyito.colors")
local files = require("yeyito.files")

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
-- dd: the rows waiting for the second d ({ key, paths }), shown red.
local pending ---@type { key: string, paths: table<string, true> }?
local pending_ns = api.nvim_create_namespace("yeyito.sidebar.pending")
local delete_ns = api.nvim_create_namespace("yeyito.sidebar.delete")
-- The actions menu (; or a right click) while it is open.
local menu ---@type { win: integer, buf: integer, items: table[], confirm: boolean }?

local function visual_mode()
  local mode = api.nvim_get_mode().mode
  return mode == "v" or mode == "V" or mode == "\22"
end

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
    local red = pending and pending.paths[rows[line].path]
    api.nvim_buf_set_extmark(buf, marker_ns, line - 1, 0, {
      virt_text = { { "▸ ", red and "YeyitoSidebarDelete" or "YeyitoSidebarMarker" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
  -- A visual selection's rows, as Exocortex shows them: the whole row in
  -- the selection's color (there is no CursorLine in visual mode), "│ " on
  -- the ones the cursor isn't on.
  if api.nvim_get_current_win() == win and visual_mode() then
    local from, to = vim.fn.line("v"), line
    if from > to then
      from, to = to, from
    end
    for i = from, to do
      if rows[i] then
        local red = pending and pending.paths[rows[i].path]
        api.nvim_buf_set_extmark(buf, marker_ns, i - 1, 0, {
          virt_text = i ~= line and { { "│ ", red and "YeyitoSidebarDelete" or "YeyitoSidebarVisualMarker" } } or nil,
          virt_text_pos = i ~= line and "overlay" or nil,
          hl_mode = "combine",
          line_hl_group = "YeyitoSidebarVisual",
        })
      end
    end
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
  return win == sidebar_win() or (bar ~= nil and win == bar.win) or (menu ~= nil and win == menu.win)
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
  -- The selected row's CursorLine has a foreground, over any highlight on the
  -- row: while it waits for the second d of dd, a red one.
  local row = rows[api.nvim_win_get_cursor(win)[1]]
  local red = pending and row and pending.paths[row.path]
  vim.wo[win].winhighlight = table.concat({
    "Normal:YeyitoSidebar",
    "NormalNC:YeyitoSidebar",
    "CursorLine:" .. (red and "YeyitoSidebarSelDelete" or "YeyitoSidebarSel"),
    "Visual:YeyitoSidebarVisual",
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

-- ── File operations: Exocortex's sidebar keys, for files ──────────────────

local function fail(err)
  if err then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

--- A path as the sidebar shows it: in the project, or from home.
local function rel(path)
  if path == root then
    return "."
  end
  return vim.startswith(path, root .. "/") and path:sub(#root + 2) or vim.fn.fnamemodify(path, ":~")
end

local function leave_visual()
  if visual_mode() then
    vim.cmd([[execute "normal! \<Esc>"]])
  end
end

--- The rows waiting for a second d are red, as in Exocortex.
local function draw_pending()
  local win = sidebar_win()
  if not (buf and win) then
    return
  end
  api.nvim_buf_clear_namespace(buf, delete_ns, 0, -1)
  if pending then
    for i, row in ipairs(rows) do
      if pending.paths[row.path] then
        api.nvim_buf_set_extmark(buf, delete_ns, i - 1, 0, { end_row = i, hl_group = "YeyitoSidebarDelete", priority = 5000 }) -- over the current file's white
      end
    end
  end
  set_focused_look(win, focused())
  draw_marker()
end

local function clear_pending()
  if pending then
    pending = nil
    vim.on_key(nil, pending_ns)
    draw_pending()
  end
end

local function set_pending(key, items)
  local paths = {}
  for _, item in ipairs(items) do
    paths[item.path] = true
  end
  pending = { key = key, paths = paths }
  -- Any other key lets it go, as in Exocortex.
  vim.on_key(function(_, typed)
    if typed ~= "d" and typed ~= "D" then
      vim.schedule(clear_pending)
    end
  end, pending_ns)
  draw_pending()
end

--- Without what's inside a folder that is itself in the list.
local function outermost(items)
  local dirs = {}
  for _, item in ipairs(items) do
    if item.dir then
      dirs[item.path] = true
    end
  end
  return vim.tbl_filter(function(item)
    local dir = vim.fs.dirname(item.path)
    while #dir > #root do
      if dirs[dir] then
        return false
      end
      dir = vim.fs.dirname(dir)
    end
    return true
  end, items)
end

--- What an operation acts on: the selected rows in visual mode, else the cursor's.
local function targets()
  local win = sidebar_win()
  if not win then
    return {}
  end
  if visual_mode() and api.nvim_get_current_win() == win then
    local from, to = vim.fn.line("v"), vim.fn.line(".")
    if from > to then
      from, to = to, from
    end
    local items = {}
    for i = from, to do
      items[#items + 1] = rows[i]
    end
    return outermost(items)
  end
  local row = cursor_row(win)
  return row and { row } or {}
end

--- The tree after an operation, with `select` selected (its folders opened).
local function after_change(select)
  children = {} -- read again
  if active_query() then
    start_index() -- the filtered list comes from the index: it shows the change when the new one lands
    render(select)
  elseif select and vim.startswith(select, root .. "/") then
    reveal(select)
  else
    render()
  end
  update_foot()
end

--- The folder new files and folders go in: the one under the cursor, or the
--- selected file's.
local function cursor_folder()
  local win = sidebar_win()
  local row = win and cursor_row(win)
  if not row then
    return root
  end
  return row.dir and row.path or vim.fs.dirname(row.path)
end

--- `input` as a path: as is when absolute, from home with ~, else in `dir`.
local function path_in(dir, input)
  if input:match("^[/~]") then
    return vim.fs.normalize(vim.fn.fnamemodify(input, ":p"))
  end
  return vim.fs.normalize(vim.fs.joinpath(dir, input))
end

local function delete_items(items)
  clear_pending()
  local paths, err = files.delete(items)
  if paths then
    after_change()
  end
  fail(err)
end

--- d: the first one marks the rows (red), the second deletes them.
local function delete_key()
  local items = targets()
  if #items == 0 then
    return
  end
  local key = table.concat(vim.tbl_map(function(item)
    return item.path
  end, items), "\n")
  if not (pending and pending.key == key) then
    set_pending(key, items)
    return
  end
  leave_visual()
  delete_items(items)
end

local function undo(redo)
  clear_pending()
  local op, err = (redo and files.redo or files.undo)()
  if not op then
    return fail(err)
  end
  after_change(redo and op.after or op.before)
  vim.notify((redo and "Redo: " or "Undo: ") .. op.label)
end

-- ── Name prompt: a box in the middle of the editor, as Exocortex's ───────

local modal ---@type { frame: integer, input: integer, origin: integer, showmode: boolean }?
local modal_ns = api.nvim_create_namespace("yeyito.sidebar.modal")

local function close_modal()
  local m = modal
  modal = nil
  if not m then
    return
  end
  vim.cmd.stopinsert()
  for _, win in ipairs({ m.input, m.frame }) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  vim.o.showmode = m.showmode
  if api.nvim_win_is_valid(m.origin) then
    api.nvim_set_current_win(m.origin)
  end
end

--- Ask for a name in a box in the middle of the editor, Exocortex's
--- overlay: its title, a line for what went wrong, and the text to type.
--- Enter submits, Esc cancels. `opts` = { title, text (to start from),
--- placeholder, error, complete(text) -> candidates for Tab,
--- on_submit(text) -> nil when done, or why not: it asks again with that }.
local function prompt(opts)
  close_modal()
  local origin = api.nvim_get_current_win()
  -- Centred in the editor's part of the screen, right of the sidebar.
  local left = sidebar_win() and WIDTH or 0
  local area = vim.o.columns - left
  local width = math.max(20, math.min(56, area - 4))
  local row = math.max(0, math.floor((vim.o.lines - 5) / 2))
  local col = left + math.max(0, math.floor((area - width - 2) / 2))
  local fbuf = api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  local title = " " .. opts.title
  api.nvim_buf_set_lines(fbuf, 0, -1, false, { title, opts.error and " " .. opts.error or "", "" })
  if opts.error then
    api.nvim_buf_set_extmark(fbuf, modal_ns, 1, 0, { end_row = 2, hl_group = "YeyitoSidebarDelete" })
  end
  api.nvim_buf_set_extmark(fbuf, modal_ns, 2, 0, { line_hl_group = "YeyitoSidebarField" })
  local border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }
  local frame = api.nvim_open_win(fbuf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 3,
    style = "minimal",
    border = border,
    focusable = false,
    zindex = 220,
    noautocmd = true,
  })
  vim.wo[frame].winhighlight = "Normal:YeyitoSidebarMenu,FloatBorder:YeyitoSidebarMenuBorder"
  -- The text field: its own window on the box's last line.
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  if opts.text then
    api.nvim_buf_set_lines(b, 0, -1, false, { opts.text })
  end
  local input = api.nvim_open_win(b, true, {
    relative = "editor",
    row = row + 3,
    col = col + 2,
    width = width - 2,
    height = 1,
    style = "minimal",
    zindex = 221,
    noautocmd = true,
  })
  vim.wo[input].winhighlight = "Normal:YeyitoSidebarField"
  vim.wo[input].wrap = false
  vim.wo[input].signcolumn = "no"
  modal = { frame = frame, input = input, origin = origin, showmode = vim.o.showmode }
  vim.o.showmode = false -- no "-- INSERT --": it's a text field
  local placeholder ---@type integer?
  local function show_placeholder()
    local empty = (api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") == ""
    if empty and not placeholder and opts.placeholder then
      placeholder = api.nvim_buf_set_extmark(b, modal_ns, 0, 0, {
        virt_text = { { opts.placeholder, "YeyitoSidebarFieldPlaceholder" } },
        virt_text_pos = "overlay",
      })
    elseif not empty and placeholder then
      api.nvim_buf_del_extmark(b, modal_ns, placeholder)
      placeholder = nil
    end
  end
  show_placeholder()
  api.nvim_buf_attach(b, false, {
    on_lines = function()
      vim.schedule(function()
        if api.nvim_buf_is_valid(b) then
          show_placeholder()
        end
      end)
    end,
  })
  local function imap(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = b, nowait = true })
  end
  imap("<CR>", function()
    local text = api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
    close_modal()
    -- Once out of the text field's insert mode.
    vim.schedule(function()
      local err = opts.on_submit(text)
      if err then
        prompt(vim.tbl_extend("force", opts, { text = text, error = err }))
      end
    end)
  end)
  imap("<Esc>", close_modal)
  imap("<C-c>", close_modal)
  -- Tab / Shift+Tab: the candidates for what is typed, in turn.
  local cycle ---@type { items: string[], i: integer }?
  local function complete(step)
    if not opts.complete then
      return
    end
    local text = api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
    if not (cycle and cycle.items[cycle.i] == text) then
      cycle = { items = opts.complete(text), i = 0 }
    end
    if #cycle.items == 0 then
      return
    end
    cycle.i = cycle.i == 0 and (step > 0 and 1 or #cycle.items) or (cycle.i - 1 + step) % #cycle.items + 1
    local pick = cycle.items[cycle.i]
    api.nvim_buf_set_lines(b, 0, 1, false, { pick })
    api.nvim_win_set_cursor(input, { 1, #pick })
  end
  imap("<Tab>", function()
    complete(1)
  end)
  imap("<S-Tab>", function()
    complete(-1)
  end)
  -- A click elsewhere cancels it.
  api.nvim_create_autocmd("WinLeave", {
    buffer = b,
    once = true,
    callback = function()
      vim.schedule(function()
        if modal and modal.input == input then
          close_modal()
        end
      end)
    end,
  })
  vim.cmd.startinsert({ bang = true }) -- after the text it starts from
end

--- The name prompt, for other modules (the AI's request box).
M.prompt = prompt

--- Files changed outside the sidebar (the AI): show `path` (selected), if it is open.
function M.changed(path)
  if sidebar_win() then
    after_change(path)
  end
end

local function in_folder(dir)
  return dir == root and "" or " in " .. rel(dir) .. "/"
end

--- Create the file (or folder: a name ending in /) `input` names in `dir`;
--- a file opens in the editor, which gets the focus. Returns why not.
local function create(dir, input, as_dir)
  input = vim.trim(input)
  if input == "" then
    return
  end
  local is_dir = as_dir or input:sub(-1) == "/"
  local path = path_in(dir, input)
  local ok, err = files.create(path, is_dir)
  if not ok then
    return err
  end
  if is_dir then
    expanded[path] = true
  end
  if sidebar_win() then
    after_change(path)
    if not is_dir then
      open_file(path)
      focus_editor()
    end
  elseif not is_dir then
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
end

local function new_file_in(dir)
  prompt({
    title = "New file" .. in_folder(dir),
    placeholder = "name (a / at the end: a folder)",
    on_submit = function(input)
      return create(dir, input)
    end,
  })
end

--- Ctrl+P: a new file in the folder under the sidebar's cursor (`top`, as
--- Ctrl+Shift+O: at the top of the project). Without the sidebar, in the
--- current file's folder.
function M.new_file(top)
  if sidebar_win() then
    clear_pending()
    leave_visual()
    new_file_in(top and root or cursor_folder())
    return
  end
  local name = api.nvim_buf_get_name(0)
  local dir = vim.fs.normalize(vim.fn.getcwd())
  if not top and name ~= "" and vim.bo.buftype == "" then
    dir = vim.fs.dirname(vim.fs.normalize(name))
  end
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  prompt({
    title = "New file" .. (dir == cwd and "" or " in " .. vim.fn.fnamemodify(dir, ":~:.") .. "/"),
    placeholder = "name (a / at the end: a folder)",
    on_submit = function(input)
      return create(dir, input)
    end,
  })
end

--- f: a new folder where the cursor is; with rows selected, around them
--- (they move into it, one u undoes both).
local function new_folder_in(dir, items)
  prompt({
    title = (items and #items > 0) and ("New folder for " .. (#items == 1 and vim.fs.basename(items[1].path) or #items .. " items"))
      or "New folder" .. in_folder(dir),
    placeholder = "name",
    on_submit = function(input)
      input = vim.trim(input)
      if input == "" then
        return
      end
      local path = path_in(dir, input)
      local ok, err = files.create(path, true)
      if not ok then
        return err
      end
      expanded[path] = true
      local select = path
      if items and #items > 0 then
        local moves = vim.tbl_map(function(item)
          return { from = item.path, to = path .. "/" .. vim.fs.basename(item.path) }
        end, items)
        local moved, merr = files.move(moves, "move")
        if moved then
          files.combine(2, "new folder " .. vim.fs.basename(path))
          select = moves[1].to
        end
        fail(merr)
      end
      after_change(select)
    end,
  })
end

local function new_folder()
  clear_pending()
  local items = visual_mode() and targets() or nil
  leave_visual()
  new_folder_in(items and items[1] and vim.fs.dirname(items[1].path) or cursor_folder(), items)
end

local function rename_item(row)
  if not row then
    return
  end
  clear_pending()
  local name = vim.fs.basename(row.path)
  prompt({
    title = "Rename " .. name,
    text = name,
    placeholder = "name",
    on_submit = function(input)
      input = vim.trim(input)
      if input == "" or input == name then
        return
      end
      local to = path_in(vim.fs.dirname(row.path), input)
      local ok, err = files.move({ { from = row.path, to = to } }, "rename")
      if not ok then
        return err
      end
      after_change(to)
    end,
  })
end

--- Folders of the project starting with `text`, for Tab when moving.
local function complete_folder(text)
  local out = {}
  for _, dir in ipairs(vim.fn.getcompletion(root .. "/" .. text:gsub("^/", ""), "dir")) do
    if vim.startswith(dir, root .. "/") then
      out[#out + 1] = dir:sub(#root + 2)
    end
  end
  return out
end

--- F: move into a folder of the project (empty or / for its top, .. for
--- one up from where they are, ~ from home).
local function move_items(items)
  if #items == 0 then
    return
  end
  clear_pending()
  prompt({
    title = "Move " .. (#items == 1 and vim.fs.basename(items[1].path) or #items .. " items") .. " to",
    placeholder = "folder (Tab completes; empty: the top)",
    complete = complete_folder,
    on_submit = function(input)
      input = vim.trim(input)
      local from = vim.fs.dirname(items[1].path)
      local dest
      if input == "" or input == "/" then
        dest = root
      elseif input:match("^%.%.?/") or input == ".." or input:match("^~") then
        dest = path_in(from, input)
      else
        dest = path_in(root, (input:gsub("^/", "")))
      end
      local stat = uv.fs_stat(dest)
      if not (stat and stat.type == "directory") then
        return "No folder " .. rel(dest)
      end
      local moves = {}
      for _, item in ipairs(items) do
        local to = dest .. "/" .. vim.fs.basename(item.path)
        if to ~= item.path then
          moves[#moves + 1] = { from = item.path, to = to }
        end
      end
      if #moves == 0 then
        return
      end
      local ok, err = files.move(moves, "move")
      if not ok then
        return err
      end
      after_change(moves[1].to)
    end,
  })
end

--- <: out of the folder they are in, into the one above it.
local function move_out()
  local items = targets()
  leave_visual()
  clear_pending()
  local moves = {}
  for _, item in ipairs(items) do
    local dir = vim.fs.dirname(item.path)
    if #dir > #root then
      moves[#moves + 1] = { from = item.path, to = vim.fs.dirname(dir) .. "/" .. vim.fs.basename(item.path) }
    end
  end
  if #moves == 0 then
    return
  end
  local ok, err = files.move(moves, "move")
  if not ok then
    return fail(err)
  end
  after_change(moves[1].to)
end

--- c: a copy beside it ("name copy.ext"), selected.
local function duplicate(row)
  if not row then
    return
  end
  clear_pending()
  files.duplicate(row.path, row.dir, function(to, err)
    if not to then
      return fail(err)
    end
    after_change(to)
  end)
end

local function copy_path(row)
  if not pcall(vim.fn.setreg, "+", row.path) then
    vim.fn.setreg('"', row.path)
  end
  vim.notify("Copied " .. vim.fn.fnamemodify(row.path, ":~"))
end

-- ── Actions menu (; or a right click), as Exocortex's ─────────────────────

local menu_ns = api.nvim_create_namespace("yeyito.sidebar.menu")

local function close_menu()
  local m = menu
  menu = nil
  if m and api.nvim_win_is_valid(m.win) then
    api.nvim_win_close(m.win, true)
  end
  local side = sidebar_win()
  if m and side and api.nvim_get_current_win() ~= side then
    api.nvim_set_current_win(side)
  end
end

local function draw_menu()
  local m = menu
  if not m then
    return
  end
  local line = api.nvim_win_get_cursor(m.win)[1]
  local width = api.nvim_win_get_width(m.win)
  local lines = {}
  for i, item in ipairs(m.items) do
    local text = (i == line and "▸ " or "  ") .. (item.danger and m.confirm and i == line and "You sure?" or item.label)
    lines[i] = text .. (" "):rep(width - vim.fn.strdisplaywidth(text))
  end
  vim.bo[m.buf].modifiable = true
  api.nvim_buf_set_lines(m.buf, 0, -1, false, lines)
  vim.bo[m.buf].modifiable = false
  api.nvim_buf_clear_namespace(m.buf, menu_ns, 0, -1)
  for i, item in ipairs(m.items) do
    if item.danger then
      api.nvim_buf_set_extmark(m.buf, menu_ns, i - 1, 0, { end_row = i, hl_group = "YeyitoSidebarDelete" })
    end
  end
end

local function menu_activate()
  local m = menu
  if not m then
    return
  end
  local item = m.items[api.nvim_win_get_cursor(m.win)[1]]
  if not item then
    return
  end
  if item.danger and not m.confirm then
    m.confirm = true -- Delete asks "You sure?" first
    draw_menu()
    return
  end
  close_menu()
  item.fn()
end

local function menu_items(row)
  local items = {}
  local function add(label, fn, danger)
    items[#items + 1] = { label = label, fn = fn, danger = danger }
  end
  if row.dir then
    add("New file", function()
      new_file_in(row.path)
    end)
    add("New folder", function()
      new_folder_in(row.path)
    end)
  end
  add("Rename", function()
    rename_item(row)
  end)
  add("Duplicate", function()
    duplicate(row)
  end)
  add("Move", function()
    move_items({ row })
  end)
  add("Copy path", function()
    copy_path(row)
  end)
  add("Delete", function()
    delete_items({ row })
  end, true)
  return items
end

--- The actions for the selected row, in a box beside it.
function M.open_menu()
  local side = sidebar_win()
  local row = side and cursor_row(side)
  if not row then
    return
  end
  clear_pending()
  leave_visual()
  close_menu()
  local items = menu_items(row)
  local width = vim.fn.strdisplaywidth("You sure?")
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(item.label))
  end
  width = width + 3 -- "▸ " and a space
  -- Its top border on the row, as Exocortex places it, and on the screen.
  local top = vim.fn.screenpos(side, api.nvim_win_get_cursor(side)[1], 1).row - 1
  top = math.max(0, math.min(top, vim.o.lines - #items - 2))
  local mbuf = api.nvim_create_buf(false, true)
  vim.bo[mbuf].bufhidden = "wipe"
  local win = api.nvim_open_win(mbuf, true, {
    relative = "editor",
    row = top,
    col = WIDTH,
    width = width,
    height = #items,
    style = "minimal",
    border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
    zindex = 210,
  })
  vim.wo[win].winhighlight = "Normal:YeyitoSidebarMenu,FloatBorder:YeyitoSidebarMenuBorder,CursorLine:YeyitoSidebarMenuSel"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  menu = { win = win, buf = mbuf, items = items, confirm = false }
  set_focused_look(side, true) -- no terminal cursor in it either
  draw_menu()
  local function mmap(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = mbuf, nowait = true, silent = true })
  end
  mmap("<CR>", menu_activate)
  mmap("<Esc>", close_menu)
  mmap("q", close_menu)
  mmap(";", close_menu)
  mmap("<LeftRelease>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == win and pos.line > 0 then
      api.nvim_win_set_cursor(win, { pos.line, 0 })
      menu_activate()
    end
  end)
  local line = 1
  api.nvim_create_autocmd("CursorMoved", {
    buffer = mbuf,
    callback = function()
      local cur = api.nvim_win_get_cursor(win)
      if cur[2] ~= 0 then
        api.nvim_win_set_cursor(win, { cur[1], 0 })
      end
      if menu and cur[1] ~= line then
        line = cur[1]
        menu.confirm = false
        draw_menu()
      end
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    buffer = mbuf,
    once = true,
    callback = function()
      vim.schedule(function()
        if menu and menu.buf == mbuf then
          close_menu()
        end
      end)
    end,
  })
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
  -- Exocortex's sidebar keys, for files.
  map("d", delete_key, "Delete (to the trash): press twice")
  map("D", delete_key, "Delete (to the trash): press twice")
  map("u", function()
    undo(false)
  end, "Undo the last file operation")
  map("<C-r>", function()
    undo(true)
  end, "Redo the last undone file operation")
  map("r", function()
    rename_item(cursor_row(api.nvim_get_current_win()))
  end, "Rename")
  map("c", function()
    duplicate(cursor_row(api.nvim_get_current_win()))
  end, "Duplicate")
  map("f", new_folder, "New folder")
  map("F", function()
    move_items(targets())
  end, "Move to a folder")
  map("<", move_out, "Move out of its folder")
  map(";", M.open_menu, "Actions menu")
  map("J", "j", "Next row")
  map("K", "k", "Previous row")
  map("<Esc>", clear_pending, "Cancel")
  local function xmap(lhs, fn, desc)
    vim.keymap.set("x", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  xmap("d", delete_key, "Delete the selected rows (to the trash): press twice")
  xmap("D", delete_key, "Delete the selected rows (to the trash): press twice")
  xmap("f", new_folder, "New folder for the selected rows")
  xmap("F", function()
    local items = targets()
    leave_visual()
    move_items(items)
  end, "Move the selected rows to a folder")
  xmap("<", move_out, "Move the selected rows out of their folder")
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
  api.nvim_create_autocmd("ModeChanged", {
    buffer = buf,
    callback = function()
      if not visual_mode() then
        clear_pending() -- the rows it marked were the selection
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

--- The sidebar is open in this tab page.
function M.is_open()
  return sidebar_win() ~= nil
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
  -- dd's first d, Delete in the menu: st's red, as Exocortex's error color.
  set(0, "YeyitoSidebarDelete", { fg = colors.palette.red })
  set(0, "YeyitoSidebarSelDelete", { fg = colors.palette.red, bg = "#0f193c" })
  set(0, "YeyitoSidebarVisual", { bg = "#0f193c" })
  set(0, "YeyitoSidebarVisualMarker", { fg = "#646464" })
  set(0, "YeyitoSidebarMenu", { fg = "#ffffff", bg = "#030814" })
  set(0, "YeyitoSidebarMenuSel", { bg = "#0f193c" })
  set(0, "YeyitoSidebarMenuBorder", { fg = "#1d9bf0", bg = "#030814" })
  -- The name prompt's text field: the selected row's colour, as Exocortex's overlays mark theirs.
  set(0, "YeyitoSidebarField", { fg = "#ffffff", bg = "#0f193c" })
  set(0, "YeyitoSidebarFieldPlaceholder", { fg = "#646464", bg = "#0f193c" })
  api.nvim_set_hl(0, "YeyitoSidebarCursor", { blend = 100, bg = "#030814", fg = "#030814" })
end

function M.setup()
  highlights()
  highlight_matches()
  vim.keymap.set("n", "<C-s>", M.toggle, { desc = "File sidebar: open focused / close" })
  vim.keymap.set("x", "<C-s>", "<Esc><Cmd>lua require('yeyito.sidebar').toggle()<CR>", { desc = "File sidebar: open focused / close" })
  vim.keymap.set("i", "<C-s>", "<Esc><Cmd>lua require('yeyito.sidebar').toggle()<CR>", { desc = "File sidebar: open focused / close" })
  vim.keymap.set("n", "<Tab>", M.tab, { desc = "Switch between the file sidebar and the editor" })
  vim.keymap.set("n", "<C-p>", function()
    M.new_file(false)
  end, { desc = "New file (in the folder under the sidebar's cursor)" })
  vim.keymap.set("n", "<C-S-o>", function()
    M.new_file(true)
  end, { desc = "New file at the top of the project" })
  -- A right click on a sidebar row opens its actions menu; elsewhere, as usual.
  vim.keymap.set("n", "<RightMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= 0 and pos.winid == sidebar_win() and pos.line > 0 and rows[pos.line] then
      vim.schedule(function()
        api.nvim_set_current_win(pos.winid)
        api.nvim_win_set_cursor(pos.winid, { pos.line, 0 })
        M.open_menu()
      end)
      return ""
    end
    return "<RightMouse>"
  end, { expr = true, desc = "Sidebar: actions menu" })

  local group = api.nvim_create_augroup("yeyito.sidebar", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      local side = sidebar_win()
      if side then
        set_focused_look(side, focused())
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
