-- File operations for the sidebar: to the trash and back, rename and move
-- (open buffers follow), copy, new files and folders, and an undo/redo stack
-- of them. Each returns true, or nil and a short reason.
local M = {}

local api, uv = vim.api, vim.uv

local mac = uv.os_uname().sysname == "Darwin"

--- Something is at `path`. Anything but "no such file" counts: macOS won't
--- let us look around in its Trash, and a name we can't check isn't free.
local function taken(path)
  local stat, err = uv.fs_lstat(path)
  return stat ~= nil or not tostring(err):find("^ENOENT")
end
M.taken = taken

local function name_of(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function split_ext(name, dir)
  if not dir then
    local stem, ext = name:match("^(.+)(%.[^.]+)$")
    if stem then
      return stem, ext
    end
  end
  return name, ""
end

--- A free path in `dir` for `name`: "name", else "stem 2.ext", "stem 3.ext"...;
--- `suffix` (" copy") goes after the stem.
local function free_path(dir, name, is_dir, suffix, also_taken)
  local stem, ext = split_ext(name, is_dir)
  for n = 1, 1000 do
    local candidate = stem .. (suffix or "") .. (n > 1 and " " .. n or "") .. ext
    if not taken(dir .. "/" .. candidate) and not (also_taken and also_taken(candidate)) then
      return dir .. "/" .. candidate
    end
  end
end

-- ── Buffers ───────────────────────────────────────────────────────────────

--- Loaded file buffers of `path` or of the files under it.
local function buffers_under(path)
  local out, prefix = {}, path .. "/"
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local name = vim.fs.normalize(api.nvim_buf_get_name(b))
      if name == path or vim.startswith(name, prefix) then
        out[#out + 1] = b
      end
    end
  end
  return out
end

--- Why `path` can't be deleted, renamed or moved now: a buffer of it (or of
--- a file in it) has unsaved changes.
function M.unsaved(path)
  for _, b in ipairs(buffers_under(path)) do
    if vim.bo[b].modified then
      return vim.fn.fnamemodify(api.nvim_buf_get_name(b), ":~:.") .. " has unsaved changes"
    end
  end
end

--- Close the buffers of `path` (or under it) before it goes: windows showing
--- one show their alternate file, or an empty buffer. Returns what they
--- showed, to show it again on undo.
local function close_buffers(path)
  local shown = {}
  for _, b in ipairs(buffers_under(path)) do
    for _, win in ipairs(vim.fn.win_findbuf(b)) do
      shown[#shown + 1] = { win = win, file = api.nvim_buf_get_name(b) }
      api.nvim_win_call(win, function()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= b and vim.bo[alt].buflisted and vim.bo[alt].buftype == "" then
          vim.cmd("silent buffer " .. alt)
        else
          vim.cmd("silent enew")
        end
      end)
    end
    pcall(api.nvim_buf_delete, b, { force = true })
  end
  return shown
end

local function show_again(shown)
  for _, s in ipairs(shown or {}) do
    if api.nvim_win_is_valid(s.win) and uv.fs_stat(s.file) then
      api.nvim_win_call(s.win, function()
        vim.cmd("silent edit " .. vim.fn.fnameescape(s.file))
      end)
    end
  end
end

-- ── Trash ─────────────────────────────────────────────────────────────────

--- Where deleted files go instead of the system's trash, in the
--- freedesktop layout (for tests).
M.trash_root = nil ---@type string?

--- The system's trash: Finder's on macOS, the freedesktop one elsewhere
--- (files/ and info/, so file managers can put things back).
local function trash_dirs()
  if M.trash_root then
    return M.trash_root .. "/files", M.trash_root .. "/info"
  end
  if mac then
    return uv.os_homedir() .. "/.Trash", nil
  end
  local data = os.getenv("XDG_DATA_HOME")
  if not data or data == "" then
    data = uv.os_homedir() .. "/.local/share"
  end
  return data .. "/Trash/files", data .. "/Trash/info"
end

local function percent_encode(path)
  return (path:gsub("[^%w%-%._~/]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

local function move(from, to)
  local ok, err = uv.fs_rename(from, to)
  if ok then
    return true
  end
  if tostring(err):find("^EXDEV") then -- another filesystem: mv copies
    local res = vim.system({ "mv", "--", from, to }):wait()
    if res.code == 0 then
      return true
    end
    err = vim.trim(res.stderr or "")
  end
  return nil, err
end

--- Move `path` to the trash. Returns what `restore` needs.
local function trash(path, is_dir)
  local files, info_dir = trash_dirs()
  vim.fn.mkdir(files, "p")
  if info_dir then
    vim.fn.mkdir(info_dir, "p")
  end
  local target = free_path(files, name_of(path), is_dir, nil, info_dir and function(candidate)
    return taken(info_dir .. "/" .. candidate .. ".trashinfo")
  end)
  if not target then
    return nil, "no free name for " .. name_of(path) .. " in the trash"
  end
  local info
  if info_dir then
    info = info_dir .. "/" .. name_of(target) .. ".trashinfo"
    local f = io.open(info, "w")
    if f then
      f:write("[Trash Info]\nPath=", percent_encode(path), "\nDeletionDate=", os.date("%Y-%m-%dT%H:%M:%S"), "\n")
      f:close()
    end
  end
  local ok, err = move(path, target)
  if not ok then
    if info then
      os.remove(info)
    end
    return nil, err
  end
  return { path = path, trashed = target, info = info }
end

local function restore(t)
  if taken(t.path) then
    return nil, name_of(t.path) .. " exists again"
  end
  vim.fn.mkdir(vim.fs.dirname(t.path), "p")
  local ok, err = move(t.trashed, t.path)
  if not ok then
    return nil, err
  end
  if t.info then
    os.remove(t.info)
  end
  return true
end

-- ── Undo ──────────────────────────────────────────────────────────────────

local done, undone = {}, {} ---@type table[], table[]

--- Remember an operation: { label, undo = fn, redo = fn, before = path to
--- show after undo, after = path to show after redo }. undo/redo return
--- true, or nil and a reason.
local function record(op)
  done[#done + 1] = op
  if #done > 100 then
    table.remove(done, 1)
  end
  undone = {}
end

--- Undo the last operation (u). Returns it, or nil and a reason.
function M.undo()
  local op = done[#done]
  if not op then
    return nil, "Nothing to undo"
  end
  local ok, err = op.undo()
  if not ok then
    return nil, err
  end
  done[#done] = nil
  undone[#undone + 1] = op
  return op
end

--- Redo the last undone operation (Ctrl+R).
function M.redo()
  local op = undone[#undone]
  if not op then
    return nil, "Nothing to redo"
  end
  local ok, err = op.redo()
  if not ok then
    return nil, err
  end
  undone[#undone] = nil
  done[#done + 1] = op
  return op
end

--- Make the last `n` operations one: one u undoes them all.
function M.combine(n, text)
  if n < 2 or #done < n then
    return
  end
  local ops = {}
  for i = #done - n + 1, #done do
    ops[#ops + 1] = done[i]
  end
  for _ = 1, n do
    done[#done] = nil
  end
  record({
    label = text or ops[#ops].label,
    before = ops[1].before,
    after = ops[#ops].after,
    undo = function()
      for i = #ops, 1, -1 do
        local ok, err = ops[i].undo()
        if not ok then
          return nil, err
        end
      end
      return true
    end,
    redo = function()
      for _, op in ipairs(ops) do
        local ok, err = op.redo()
        if not ok then
          return nil, err
        end
      end
      return true
    end,
  })
end

local function label(verb, paths)
  return verb .. " " .. (#paths == 1 and name_of(paths[1]) or #paths .. " items")
end

-- ── Operations ────────────────────────────────────────────────────────────

--- Move `items` ({ path, dir }) to the trash; u brings them back. Returns
--- the paths that went, and why the others didn't.
function M.delete(items)
  for _, item in ipairs(items) do
    local why = M.unsaved(item.path)
    if why then
      return nil, why
    end
  end
  local trashed, shown, paths = {}, {}, {}
  local function put_back()
    for i = #trashed, 1, -1 do
      local ok, err = restore(trashed[i])
      if not ok then
        return nil, err
      end
    end
    show_again(shown)
    return true
  end
  local failed
  for _, item in ipairs(items) do
    local closed = close_buffers(item.path)
    local t, err = trash(item.path, item.dir)
    if not t then
      show_again(closed)
      failed = err
      break -- the ones that went are an operation of their own
    end
    vim.list_extend(shown, closed)
    trashed[#trashed + 1] = t
    paths[#paths + 1] = item.path
  end
  if #trashed == 0 then
    return nil, failed
  end
  record({
    label = label("delete", paths),
    before = paths[1],
    undo = put_back,
    redo = function()
      for _, t in ipairs(trashed) do
        local why = M.unsaved(t.path)
        if why then
          return nil, why
        end
      end
      for i, t in ipairs(trashed) do
        shown = {}
        vim.list_extend(shown, close_buffers(t.path))
        local again, err = trash(t.path, items[i] and items[i].dir)
        if not again then
          return nil, err
        end
        trashed[i] = again
      end
      return true
    end,
  })
  return paths, failed
end

local function rename(from, to)
  if from == to then
    return true
  end
  if taken(to) then
    return nil, name_of(to) .. " exists"
  end
  if vim.startswith(to, from .. "/") then
    return nil, "a folder can't go inside itself"
  end
  local why = M.unsaved(from)
  if why then
    return nil, why
  end
  vim.fn.mkdir(vim.fs.dirname(to), "p")
  local stat = uv.fs_lstat(from)
  if stat and stat.type == "link" then -- the link itself, not what it points to
    return move(from, to)
  end
  -- Open buffers follow (keeping their undo history) and language servers
  -- are told; it writes the buffers, which have no unsaved changes here.
  local ok, err = pcall(vim._with, { silent = true }, function() -- its :saveas says "written"
    vim.lsp.util.rename(from, to)
  end)
  if not ok or taken(from) or not taken(to) then
    return nil, err and tostring(err):gsub("^.-:%d+: ", "") or ("couldn't move " .. name_of(from))
  end
  return true
end

--- Rename or move `pairs` ({ from, to }), all or nothing; u moves them back.
function M.move(moves, verb)
  for i, m in ipairs(moves) do
    local ok, err = rename(m.from, m.to)
    if not ok then
      for j = i - 1, 1, -1 do
        rename(moves[j].to, moves[j].from)
      end
      return nil, err
    end
  end
  local paths = vim.tbl_map(function(m)
    return m.from
  end, moves)
  record({
    label = label(verb or "move", paths),
    before = moves[1].from,
    after = moves[1].to,
    undo = function()
      for i = #moves, 1, -1 do
        local ok, err = rename(moves[i].to, moves[i].from)
        if not ok then
          return nil, err
        end
      end
      return true
    end,
    redo = function()
      for _, m in ipairs(moves) do
        local ok, err = rename(m.from, m.to)
        if not ok then
          return nil, err
        end
      end
      return true
    end,
  })
  return true
end

--- The first folder on the way to `path` that doesn't exist yet.
local function first_missing(path)
  local missing
  local dir = vim.fs.dirname(path)
  while dir and not taken(dir) do
    missing = dir
    local up = vim.fs.dirname(dir)
    if up == dir then
      break
    end
    dir = up
  end
  return missing
end

--- Remove what `create` made, if it's still empty.
local function uncreate(path, is_dir, missing)
  local stat = uv.fs_stat(path)
  if stat then
    if is_dir then
      local ok = uv.fs_rmdir(path)
      if not ok then
        return nil, name_of(path) .. " isn't empty any more"
      end
    elseif stat.size > 0 then
      return nil, name_of(path) .. " isn't empty any more"
    else
      local why = M.unsaved(path)
      if why then
        return nil, why
      end
      close_buffers(path)
      os.remove(path)
    end
  end
  -- The folders made on the way, while empty.
  local dir = vim.fs.dirname(path)
  while missing and dir and #dir >= #missing and uv.fs_rmdir(dir) do
    dir = vim.fs.dirname(dir)
  end
  return true
end

local function make(path, is_dir)
  if is_dir then
    return vim.fn.mkdir(path, "p") == 1 or nil, "couldn't create " .. name_of(path)
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd, err = uv.fs_open(path, "wx", 420) -- 0644, and not over an existing file
  if not fd then
    return nil, err
  end
  uv.fs_close(fd)
  return true
end

--- Create an empty file or a folder (and the folders on the way); u removes
--- it while it's still empty.
function M.create(path, is_dir)
  if taken(path) then
    return nil, name_of(path) .. " exists"
  end
  local missing = first_missing(path)
  local ok, err = make(path, is_dir)
  if not ok then
    return nil, err
  end
  record({
    label = (is_dir and "new folder " or "new file ") .. name_of(path),
    after = path,
    undo = function()
      return uncreate(path, is_dir, missing)
    end,
    redo = function()
      if taken(path) then
        return nil, name_of(path) .. " exists"
      end
      return make(path, is_dir)
    end,
  })
  return true
end

--- Something else made `path` (the AI): u moves it to the trash, Ctrl+R puts
--- it back.
function M.created(path, is_dir, text)
  local trashed
  record({
    label = text or ((is_dir and "new folder " or "new file ") .. name_of(path)),
    after = path,
    undo = function()
      local why = M.unsaved(path)
      if why then
        return nil, why
      end
      close_buffers(path)
      local t, err = trash(path, is_dir)
      if not t then
        return nil, err
      end
      trashed = t
      return true
    end,
    redo = function()
      if not trashed then
        return nil, name_of(path) .. " is gone"
      end
      return restore(trashed)
    end,
  })
end

--- Where a copy of `path` goes: "name copy.ext", "name copy 2.ext"...
function M.copy_path(path, is_dir)
  return free_path(vim.fs.dirname(path), name_of(path), is_dir, " copy")
end

local function copy(from, to, is_dir, done_cb)
  if taken(to) then
    return done_cb(name_of(to) .. " exists")
  end
  if not is_dir then
    local ok, err = uv.fs_copyfile(from, to, { excl = true })
    return done_cb(not ok and err or nil)
  end
  vim.system({ "cp", "-R", "--", from, to }, {}, vim.schedule_wrap(function(res)
    done_cb(res.code ~= 0 and vim.trim(res.stderr or "") or nil)
  end))
end

--- Copy `from` next to itself (a folder with what's in it, in the
--- background); `done_cb(copy_path)` or `done_cb(nil, reason)`. u trashes
--- the copy.
function M.duplicate(from, is_dir, done_cb)
  local to = M.copy_path(from, is_dir)
  if not to then
    return done_cb(nil, "no free name for a copy of " .. name_of(from))
  end
  copy(from, to, is_dir, function(err)
    if err then
      return done_cb(nil, err)
    end
    local trashed
    record({
      label = "duplicate " .. name_of(from),
      before = from,
      after = to,
      undo = function()
        local why = M.unsaved(to)
        if why then
          return nil, why
        end
        close_buffers(to)
        local t, e = trash(to, is_dir)
        trashed = t
        return t and true, e
      end,
      redo = function()
        if not trashed then
          return nil, "the copy is gone"
        end
        return restore(trashed)
      end,
    })
    done_cb(to)
  end)
end

return M
