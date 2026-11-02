-- AI in the editor, on the user's Exocortex daemon (its app API; the client is
-- lua/exocortex, vendored from Exocortex). The model works on the project
-- through Neovim itself: it reads and edits buffers, creates, moves and
-- deletes files, and has a shell; edits are saved, undoable with one u, and
-- the language servers and the sidebar see them.
--   <leader>a        ask, in a box in the middle of the editor (visual mode:
--                    about the selected text)
--   :Ai [request]    the same from the command line (:ai too; with a range,
--                    about those lines); :Ai new  a fresh conversation;
--                    :Ai log  the conversation so far;
--                    :Ai clear  no more green on the lines it changed
--   Ctrl+Q           stop it while it works (the next queued request then runs)
--   Esc              in normal mode: put its reply away, then the green block
--                    under the cursor
-- One conversation per project (the working directory), hidden from the
-- Exocortex sidebar, kept until it has been idle an hour. Asking while it works
-- queues the request for when the running one ends, as in Exocortex.
-- All the Neovims in a folder share that conversation through the daemon, as
-- Exocortex's TUIs do: each runs the requests asked in it, and all of them show
-- the work, the reply and the changes. Ctrl+Q and :Ai new reach all of them.
local M = {}

local api, uv = vim.api, vim.uv
local exo = require("exocortex")
local files = require("yeyito.files")

local APP = "nvim"
local IDLE_TTL = 60 * 60 * 1000
local FOLLOW_CHECK = 2000 -- how often to ask the daemon if another Neovim's request still runs
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local READ_LIMIT = 2000 -- lines read_file returns at once

local changed_ns = api.nvim_create_namespace("yeyito.ai.changed")
local working_ns = api.nvim_create_namespace("yeyito.ai.working")

M.context = true -- each request carries the editor's state (tests turn it off)

local client ---@type table? the connection to the daemon
local connecting ---@type function[]? callbacks waiting for it
local convs = {} ---@type table<string, table> project -> conversation
local busy = {} ---@type table<string, table> project -> the running turn
local foreign = {} ---@type table<string, table> project -> another Neovim's running turn
local queue = {} ---@type table<string, table[]> project -> requests waiting for it to end
local applying = false -- our own buffer changes: they keep the green tint
local draft ---@type string? a request closed without sending, for the next box

-- ── Paths ─────────────────────────────────────────────────────────────────

local function project()
  return vim.fs.normalize(vim.fn.getcwd())
end

local function resolve(root, path)
  path = vim.trim(path or "")
  if path:match("^~") then
    path = vim.fn.fnamemodify(path, ":p")
  elseif not path:match("^/") then
    path = root .. "/" .. path
  end
  return vim.fs.normalize(path)
end

local function rel(root, path)
  return vim.startswith(path, root .. "/") and path:sub(#root + 2) or vim.fn.fnamemodify(path, ":~")
end

--- The loaded buffer of `path`, read again first if the file changed on disk
--- and the buffer has no changes of its own (the shell may have written it).
local function loaded_buffer(path)
  local b = vim.fn.bufnr(path)
  if b > 0 and api.nvim_buf_is_loaded(b) then
    if not vim.bo[b].modified then
      pcall(vim.cmd, "silent! checktime " .. b)
    end
    return b
  end
end

-- ── Changed lines: a green tint until the user edits them ─────────────────

local watched = {} ---@type table<integer, true>

local function watch(buf)
  if watched[buf] then
    return
  end
  watched[buf] = true
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, _, last_new)
      if applying then
        return
      end
      for _, m in ipairs(api.nvim_buf_get_extmarks(b, changed_ns, { first, 0 }, { math.max(first, last_new), 0 }, { overlap = true })) do
        pcall(api.nvim_buf_del_extmark, b, changed_ns, m[1])
      end
      if #api.nvim_buf_get_extmarks(b, changed_ns, 0, -1, { limit = 1 }) == 0 then
        watched[b] = nil
        return true -- detach
      end
    end,
    on_detach = function(_, b)
      watched[b] = nil
    end,
  })
end

--- The green block on `row` goes (marks that touch count as one block).
local function clear_block(buf, row)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local marks = api.nvim_buf_get_extmarks(buf, changed_ns, 0, -1, { details = true })
  local first, last, hit, grew = row, row, {}, true
  while grew do
    grew = false
    local reach = next(hit) and 1 or 0
    for _, m in ipairs(marks) do
      local top, bottom = m[2], m[4].end_row or m[2]
      if not hit[m[1]] and top <= last + reach and bottom >= first - reach then
        hit[m[1]], grew = true, true
        first, last = math.min(first, top), math.max(last, bottom)
      end
    end
  end
  for id in pairs(hit) do
    api.nvim_buf_del_extmark(buf, changed_ns, id)
  end
end

--- :Ai clear: no more green, in any file.
function M.clear_changes()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      api.nvim_buf_clear_namespace(b, changed_ns, 0, -1)
    end
  end
end

local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil -- the file's last newline
  end
  return lines
end

--- Make `buf` hold `new` (lines), changing only what differs, as one undo
--- step per request (`turn.touched`), the new lines tinted.
local function apply(buf, new, turn)
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunks = vim.diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", {
    result_type = "indices",
    algorithm = "histogram",
  })
  if #hunks == 0 then
    return 0
  end
  applying = true
  local ok, err = pcall(api.nvim_buf_call, buf, function()
    if turn.touched[buf] then
      pcall(vim.cmd, "undojoin") -- fails after a change of the user's: then it's a step of its own
    end
    for i = #hunks, 1, -1 do
      local sa, ca, sb, cb = unpack(hunks[i])
      local start = ca == 0 and sa or sa - 1
      api.nvim_buf_set_lines(buf, start, start + ca, false, vim.list_slice(new, sb, sb + cb - 1))
    end
  end)
  applying = false
  if not ok then
    error(err, 0)
  end
  turn.touched[buf] = true
  for _, h in ipairs(hunks) do
    local sb, cb = h[3], h[4]
    if cb > 0 then
      api.nvim_buf_set_extmark(buf, changed_ns, sb - 1, 0, {
        end_row = sb - 1 + cb - 1,
        line_hl_group = "YeyitoAiChanged",
        priority = 50,
      })
    end
  end
  watch(buf)
  return #hunks
end

--- Save `buf`, unless it had changes of the user's before (`was_modified`):
--- those stay theirs to save. Returns a note for the model, or nil.
local function save(buf, was_modified)
  if was_modified then
    return "not saved: the user has unsaved changes in it, left for them to save"
  end
  local ok, err = pcall(api.nvim_buf_call, buf, function()
    vim.cmd("silent keepalt write")
  end)
  if not ok then
    return "not saved: " .. tostring(err):gsub("^.-:%d+: ", ""):gsub("^Vim%(%a+%):", "")
  end
end

local function load(path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

-- ── The model's tools: Neovim does the work ───────────────────────────────

local function tools(root, turn)
  local function did(what)
    turn.did[#turn.did + 1] = what
    if M.on_did then
      M.on_did(what)
    end
  end
  local obj = function(props, required)
    return { type = "object", properties = props, required = required }
  end
  local str = function(description)
    return { type = "string", description = description }
  end
  return {
    {
      name = "read_file",
      description = "Read a text file of the project, as the user's editor has it (with their unsaved changes). "
        .. "Lines come numbered (number, tab, text); the numbers are not part of the file. "
        .. ("At most %d lines at a time: offset (1-based line) and limit read further."):format(READ_LIMIT),
      input_schema = obj({
        path = str("Path, relative to the project or absolute"),
        offset = { type = "integer", description = "First line (1-based)" },
        limit = { type = "integer", description = "How many lines" },
      }, { "path" }),
      handler = function(input)
        local path = resolve(root, input.path)
        local stat = uv.fs_stat(path)
        if stat and stat.type == "directory" then
          error(rel(root, path) .. " is a folder: use glob or the shell to list it", 0)
        end
        local b = loaded_buffer(path)
        local lines
        if b then
          lines = api.nvim_buf_get_lines(b, 0, -1, false)
        elseif stat then
          local f = assert(io.open(path, "rb"))
          local data = f:read("*a")
          f:close()
          if data:sub(1, 8000):find("%z") then
            error(rel(root, path) .. " is a binary file", 0)
          end
          lines = split(data)
        else
          error("No file " .. rel(root, path), 0)
        end
        did("read " .. rel(root, path))
        if #lines == 0 or (#lines == 1 and lines[1] == "") then
          return "(empty file)"
        end
        local from = math.max(1, tonumber(input.offset) or 1)
        local to = math.min(#lines, from + (tonumber(input.limit) or READ_LIMIT) - 1)
        local out = {}
        for i = from, to do
          local line = lines[i]
          if #line > 2000 then
            line = line:sub(1, 2000) .. "… (line cut)"
          end
          out[#out + 1] = ("%6d\t%s"):format(i, line)
        end
        if from > 1 or to < #lines then
          out[#out + 1] = ("(lines %d-%d of %d)"):format(from, to, #lines)
        end
        return table.concat(out, "\n")
      end,
    },
    {
      name = "edit_file",
      description = "Change a file in the user's editor: replace old_string, which must appear exactly once "
        .. "(or every time, with replace_all), with new_string. Copy old_string exactly from read_file's "
        .. "text, without the line numbers. The file is saved, and the user can undo it.",
      input_schema = obj({
        path = str("Path, relative to the project or absolute"),
        old_string = str("The exact text to replace"),
        new_string = str("What replaces it"),
        replace_all = { type = "boolean", description = "Replace every occurrence" },
      }, { "path", "old_string", "new_string" }),
      handler = function(input)
        local path = resolve(root, input.path)
        if (input.old_string or "") == "" then
          error("old_string is empty: use write_file to create or fill a file", 0)
        end
        local b = loaded_buffer(path)
        if not b then
          if not uv.fs_stat(path) then
            error("No file " .. rel(root, path) .. " (write_file creates one)", 0)
          end
          b = load(path)
        end
        local was_modified = vim.bo[b].modified
        local text = table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        local count, from = 0, 1
        while true do
          local s, e = text:find(input.old_string, from, true)
          if not s then
            break
          end
          count, from = count + 1, e + 1
        end
        if count == 0 then
          error("old_string is not in " .. rel(root, path) .. " (read it again: it must match exactly)", 0)
        end
        if count > 1 and not input.replace_all then
          error(("old_string is in %s %d times: give more of the text around it, or replace_all"):format(rel(root, path), count), 0)
        end
        local repl = input.new_string:gsub("%%", "%%%%")
        local new = text:gsub(vim.pesc(input.old_string), repl, input.replace_all and count or 1)
        apply(b, vim.split(new, "\n", { plain = true }), turn)
        local note = save(b, was_modified)
        did("edited " .. rel(root, path))
        return "Edited " .. rel(root, path) .. (note and " (" .. note .. ")" or "")
      end,
    },
    {
      name = "write_file",
      description = "Create a file with this content, or replace all of an existing file's content "
        .. "(prefer edit_file for changes to part of a file). Folders on the way are created. Saved.",
      input_schema = obj({
        path = str("Path, relative to the project or absolute"),
        content = str("The whole content of the file"),
      }, { "path", "content" }),
      handler = function(input)
        local path = resolve(root, input.path)
        local stat = uv.fs_stat(path)
        if stat and stat.type == "directory" then
          error(rel(root, path) .. " is a folder", 0)
        end
        local b = loaded_buffer(path)
        if b or stat then
          b = b or load(path)
          local was_modified = vim.bo[b].modified
          apply(b, split(input.content), turn)
          local note = save(b, was_modified)
          did("rewrote " .. rel(root, path))
          return "Wrote " .. rel(root, path) .. (note and " (" .. note .. ")" or "")
        end
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local f, err = io.open(path, "wb")
        if not f then
          error(err, 0)
        end
        f:write(input.content)
        f:close()
        files.created(path, false)
        require("yeyito.sidebar").changed(path)
        did("created " .. rel(root, path))
        return "Created " .. rel(root, path)
      end,
    },
    {
      name = "move_path",
      description = "Rename or move a file or folder (open buffers follow it). Fails if the destination exists.",
      input_schema = obj({ from = str("Path now"), to = str("New path") }, { "from", "to" }),
      handler = function(input)
        local from, to = resolve(root, input.from), resolve(root, input.to)
        local ok, err = files.move({ { from = from, to = to } }, "move")
        if not ok then
          error(err, 0)
        end
        require("yeyito.sidebar").moved(from, to)
        require("yeyito.sidebar").changed(to)
        did("moved " .. rel(root, from) .. " → " .. rel(root, to))
        return "Moved " .. rel(root, from) .. " to " .. rel(root, to)
      end,
    },
    {
      name = "delete_path",
      description = "Move a file or folder to the trash (the user can restore it).",
      input_schema = obj({ path = str("Path, relative to the project or absolute") }, { "path" }),
      handler = function(input)
        local path = resolve(root, input.path)
        local stat = uv.fs_lstat(path)
        if not stat then
          error("No file " .. rel(root, path), 0)
        end
        local paths, err = files.delete({ { path = path, dir = stat.type == "directory" } })
        if not paths then
          error(err, 0)
        end
        require("yeyito.sidebar").changed()
        did("deleted " .. rel(root, path))
        return "Moved " .. rel(root, path) .. " to the trash"
      end,
    },
  }
end

local function system_prompt(root)
  return table.concat({
    "You work inside the user's Neovim, on the project at " .. root .. ". They ask you to change their code "
      .. "and files: do it, then reply in one or two short plain sentences saying what you did. The reply "
      .. "shows in a small box in the editor: no headings, lists or code blocks unless they ask for them.",
    "",
    "Change files only with edit_file, write_file, move_path and delete_path: they go through the user's "
      .. "editor, so open buffers stay in sync and the user can undo. Read files with read_file: it sees "
      .. "unsaved changes. Never change files with the shell (no sed -i, redirections into files, mv, rm, "
      .. "git checkout/restore). Use the shell for everything else: building, running tests and programs, "
      .. "git status/diff/log, finding things; glob and grep search the project.",
    "",
    "Each request ends with the editor's state: the file in view, the cursor, and any selected text. "
      .. "\"This\", \"here\" and \"it\" mean those. Do what was asked and nothing more; when a request is "
      .. "unclear, ask in your reply instead of guessing.",
  }, "\n")
end

-- ── Conversation ──────────────────────────────────────────────────────────

local on_daemon_event

local function with_client(cb)
  if client and not client.closed then
    return cb(nil, client)
  end
  if connecting then
    connecting[#connecting + 1] = cb
    return
  end
  connecting = { cb }
  exo.connect({ app = APP, version = "yeyito" }, function(err, c)
    local waiting = connecting
    connecting = nil
    client = c
    if c then
      c:on_event(on_daemon_event)
    end
    for _, fn in ipairs(waiting) do
      fn(err, c)
    end
  end)
end

local following

--- Share conversation `id` with the other Neovims in `root`.
local function join(c, root, id, cb)
  c:join(id, function(e, conv)
    if e then
      return cb(e)
    end
    convs[root] = conv
    if conv.info.streaming and not busy[root] then
      following(root)
    end
    cb(nil, conv)
  end)
end

--- The project's conversation, if it has one: the one this Neovim is in, else
--- the one the daemon has for the folder.
local function find(root, cb)
  with_client(function(err, c)
    if err then
      return cb(err)
    end
    local conv = convs[root]
    if conv and not conv.ended then
      return cb(nil, conv)
    end
    c:list({}, function(e, list)
      if e then
        return cb(e)
      end
      for _, info in ipairs(list) do -- the last active first
        if info.cwd == root then
          return join(c, root, info.convId, function(je, joined)
            if je then
              return cb() -- gone meanwhile
            end
            cb(nil, joined)
          end)
        end
      end
      cb()
    end)
  end)
end

--- The project's conversation, a new one if it has none. Its tools' handlers
--- are rebuilt for each request (`turn`).
local function conversation(root, turn, cb)
  local defs = tools(root, turn)
  find(root, function(err, conv)
    if err then
      return cb(err)
    end
    if conv then
      conv:set_handlers(defs)
      return cb(nil, conv)
    end
    client:conversation({
      lifetime = "temporary",
      idle_ttl_ms = IDLE_TTL,
      title = "Neovim · " .. vim.fs.basename(root),
      system = { base = "none", text = system_prompt(root) },
      model = vim.g.yeyito_ai_model,
      cwd = root,
      builtin = { "bash", "glob", "grep" },
      tools = defs,
    }, function(e, new)
      if e then
        return cb(e)
      end
      join(client, root, new.id, cb)
    end)
  end)
end

-- ── The card: what it's doing, then its reply (top right of the editor) ───

local card = { win = nil, buf = nil, timer = nil, frame = 1, status = "", lines = {}, kind = "working" }

local function close_card()
  if card.timer then
    card.timer:stop()
    card.timer:close()
    card.timer = nil
  end
  if card.win and api.nvim_win_is_valid(card.win) then
    api.nvim_win_close(card.win, true)
  end
  card.win = nil
end

local function model_label()
  local name, major, minor = (vim.g.yeyito_ai_model or ""):match("^claude%-(%a+)%-(%d+)%-(%d+)")
  return name and (name:sub(1, 1):upper() .. name:sub(2) .. " " .. major .. "." .. minor) or vim.g.yeyito_ai_model
end

--- `text` laid out in lines of at most `width` columns, broken at spaces;
--- `code` spans lose their backticks and are returned as { line, from, to }
--- (byte columns) to colour. A code span is kept on one line when it fits,
--- else broken like the rest.
local function layout(text, width)
  local parts, code, len, from = {}, {}, 0, 1
  while true do
    local s, e = text:find("`[^`\n]+`", from)
    local plain = text:sub(from, s and s - 1 or #text)
    parts[#parts + 1], len = plain, len + #plain
    if not s then
      break
    end
    local inner = text:sub(s + 1, e - 1)
    code[#code + 1] = { len + 1, len + #inner }
    parts[#parts + 1], len = inner, len + #inner
    from = e + 1
  end
  local clean = table.concat(parts)
  local function in_code(i)
    for _, r in ipairs(code) do
      if i >= r[1] and i <= r[2] then
        return true
      end
    end
    return false
  end
  local lines, spans = {}, {}
  local function emit(a, b)
    lines[#lines + 1] = clean:sub(a, b)
    for _, r in ipairs(code) do
      local s, e = math.max(r[1], a), math.min(r[2], b)
      if s <= e then
        spans[#spans + 1] = { #lines, s - a, e - a + 1 }
      end
    end
  end
  local start = 1
  while true do
    local nl = clean:find("\n", start, true)
    local stop = nl and nl - 1 or #clean
    local p = start
    if p > stop then
      emit(p, p - 1) -- an empty line
    end
    while p <= stop do
      if vim.fn.strdisplaywidth(clean:sub(p, stop)) <= width then
        emit(p, stop)
        break
      end
      -- The last space that fits, outside a code span if there is one.
      local best, any
      for i = p + 1, stop do
        if clean:sub(i, i) == " " then
          if vim.fn.strdisplaywidth(clean:sub(p, i - 1)) > width then
            break
          end
          any = i
          if not in_code(i) then
            best = i
          end
        end
      end
      local cut = best or any
      if cut then
        emit(p, cut - 1)
        p = cut + 1
      else -- one word wider than the line: cut it
        local piece = vim.fn.strcharpart(clean:sub(p, stop), 0, width)
        emit(p, p + #piece - 1)
        p = p + #piece
      end
      while clean:sub(p, p) == " " and p <= stop do
        p = p + 1
      end
    end
    if not nl then
      break
    end
    start = nl + 1
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines, spans
end

local MAX_LINES = 14

local function draw_card()
  local width = math.max(30, math.min(64, math.floor(vim.o.columns * 0.4)))
  local head
  if card.kind == "working" then
    head = SPINNER[card.frame] .. " " .. model_label() .. " · " .. card.status
  elseif card.kind == "error" then
    head = "✗ " .. model_label()
  else
    head = "✓ " .. model_label()
  end
  local body, spans = {}, {}
  for _, text in ipairs(card.lines) do
    local lines, sp = layout(text, width - 2)
    for _, x in ipairs(sp) do
      spans[#spans + 1] = { x[1] + #body, x[2], x[3] }
    end
    vim.list_extend(body, lines)
  end
  if #body > MAX_LINES then
    body = vim.list_slice(body, 1, MAX_LINES - 1)
    body[#body + 1] = "… :Ai log shows it all"
    spans = vim.tbl_filter(function(x)
      return x[1] < MAX_LINES
    end, spans)
  end
  -- The lines with a space in front; `code` in a colour of its own.
  local waiting = card.kind == "working" and #(queue[card.root] or {}) or 0
  local queued = waiting > 0 and " · " .. waiting .. " queued" or ""
  local lines = { " " .. vim.fn.strcharpart(head, 0, width - 2 - vim.fn.strdisplaywidth(queued)) .. queued }
  for _, l in ipairs(body) do
    lines[#lines + 1] = " " .. l
  end
  for _, x in ipairs(spans) do
    x[2], x[3] = x[2] + 1, x[3] + 1
  end
  if not (card.buf and api.nvim_buf_is_valid(card.buf)) then
    card.buf = api.nvim_create_buf(false, true)
    vim.bo[card.buf].bufhidden = "hide"
  end
  api.nvim_buf_set_lines(card.buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(card.buf, working_ns, 0, -1)
  local head_hl = card.kind == "error" and "YeyitoAiError" or card.kind == "working" and "YeyitoAiHead" or "YeyitoAiDone"
  api.nvim_buf_set_extmark(card.buf, working_ns, 0, 0, { end_row = 1, hl_group = head_hl })
  if card.kind == "error" and #lines > 1 then
    api.nvim_buf_set_extmark(card.buf, working_ns, 1, 0, { end_row = #lines, hl_group = "YeyitoAiError" })
  end
  for _, sp in ipairs(spans) do
    api.nvim_buf_set_extmark(card.buf, working_ns, sp[1], sp[2], { end_col = sp[3], hl_group = "YeyitoAiCode" })
  end
  local cfg = {
    relative = "editor",
    anchor = "NE",
    row = 0,
    col = vim.o.columns,
    width = width,
    height = #lines,
  }
  if card.win and api.nvim_win_is_valid(card.win) then
    api.nvim_win_set_config(card.win, cfg)
  else
    cfg.style, cfg.focusable, cfg.mouse, cfg.zindex, cfg.noautocmd = "minimal", false, false, 150, true
    cfg.border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }
    card.win = api.nvim_open_win(card.buf, false, cfg)
    vim.wo[card.win].winhighlight = "Normal:YeyitoAiCard,FloatBorder:YeyitoAiCardBorder"
    vim.wo[card.win].wrap = false
  end
end

local function show_working(status)
  card.kind, card.status = "working", status
  if not card.timer then
    card.timer = uv.new_timer()
    card.timer:start(80, 80, vim.schedule_wrap(function()
      if card.kind ~= "working" then
        return
      end
      card.frame = card.frame % #SPINNER + 1
      if card.win and api.nvim_win_is_valid(card.win) then
        draw_card()
      end
    end))
  end
  draw_card()
end

local function show_result(kind, text)
  if card.timer then
    card.timer:stop()
    card.timer:close()
    card.timer = nil
  end
  card.kind, card.lines = kind, { text }
  draw_card()
end

--- What a tool call is doing, for the card.
local function activity(root, name, input)
  name = tostring(name or ""):gsub("^mcp__app__", ""):lower()
  input = type(input) == "table" and input or {}
  local path = input.path or input.from or input.file_path
  path = type(path) == "string" and rel(root, resolve(root, path)) or nil
  if name == "read_file" or name == "read" then
    return "reading " .. (path or "")
  elseif name == "edit_file" or name == "write_file" or name == "edit" or name == "write" then
    return "editing " .. (path or "")
  elseif name == "move_path" then
    return "moving " .. (path or "")
  elseif name == "delete_path" then
    return "deleting " .. (path or "")
  elseif name == "bash" or name == "exec_command" then
    local cmd = vim.trim(tostring(input.command or input.cmd or ""):gsub("%s+", " "))
    return "running " .. (#cmd > 40 and cmd:sub(1, 39) .. "…" or cmd)
  elseif name == "grep" or name == "glob" then
    return "searching"
  end
  return name
end

-- ── Asking ────────────────────────────────────────────────────────────────

--- A request, and where it was asked: its selection and the cursor stay marked in
--- their buffers, so they are still right when it runs, after what the requests
--- before it did to those lines and wherever the user went meanwhile. `sel`: the
--- selected lines, { buf, first, last }.
local function new_turn(request, sel)
  local turn = { touched = {}, did = {}, request = request }
  if sel and api.nvim_buf_is_valid(sel.buf) then
    turn.tint = {
      buf = sel.buf,
      id = api.nvim_buf_set_extmark(sel.buf, working_ns, sel.first - 1, 0, {
        end_row = sel.last - 1,
        line_hl_group = "YeyitoAiWorking",
        priority = 40,
        right_gravity = false, -- what replaces the lines stays inside the marks
        end_right_gravity = true,
      }),
    }
  end
  local buf = api.nvim_get_current_buf()
  if api.nvim_buf_get_name(buf) ~= "" and vim.bo[buf].buftype == "" then
    local row = api.nvim_win_get_cursor(0)[1] - 1
    turn.asked_in = { buf = buf, id = api.nvim_buf_set_extmark(buf, working_ns, row, 0, {}) }
  end
  return turn
end

--- Its marks go when it has run.
local function release(turn)
  for _, m in ipairs({ turn.tint or false, turn.asked_in or false }) do
    if m and api.nvim_buf_is_valid(m.buf) then
      pcall(api.nvim_buf_del_extmark, m.buf, working_ns, m.id)
    end
  end
end

--- The editor as the request was asked in it, with those lines as they are now.
local function editor_state(root, turn)
  local out = {}
  local here = turn.asked_in
  local buf = here and api.nvim_buf_is_valid(here.buf) and here.buf or nil
  local cursor = buf and api.nvim_buf_get_extmark_by_id(buf, working_ns, here.id, {})[1]
  if cursor then
    out[#out + 1] = ("Open file: %s (cursor on line %d%s)"):format(
      rel(root, vim.fs.normalize(api.nvim_buf_get_name(buf))),
      cursor + 1,
      vim.bo[buf].modified and "; it has unsaved changes" or ""
    )
  end
  local tint = turn.tint
  local mark = tint and api.nvim_buf_is_valid(tint.buf)
    and api.nvim_buf_get_extmark_by_id(tint.buf, working_ns, tint.id, { details = true })
  if mark and mark[1] then
    local first, last = mark[1] + 1, math.max(mark[1], mark[3].end_row or mark[1]) + 1
    local text = table.concat(api.nvim_buf_get_lines(tint.buf, first - 1, last, false), "\n")
    local path = rel(root, vim.fs.normalize(api.nvim_buf_get_name(tint.buf)))
    out[#out + 1] = ("Selected: %s, lines %d-%d:\n```%s\n%s\n```"):format(path, first, last, vim.bo[tint.buf].filetype, text)
  end
  local others = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    local n = api.nvim_buf_get_name(b)
    if b ~= buf and vim.bo[b].buflisted and vim.bo[b].buftype == "" and n ~= "" then
      others[#others + 1] = rel(root, vim.fs.normalize(n)) .. (vim.bo[b].modified and " (unsaved changes)" or "")
    end
  end
  if #others > 0 then
    out[#out + 1] = "Other open files: " .. table.concat(others, ", ")
  end
  return #out > 0 and "\n\n<editor>\n" .. table.concat(out, "\n") .. "\n</editor>" or ""
end

local pump

--- Run `turn`; when it ends, however it ends, the next queued request runs (as in
--- Exocortex). `follows`: right after another one, whose reply stays on the card.
local function start(root, turn, follows)
  busy[root] = turn
  card.root = root
  if not follows then
    card.lines = {}
  end
  show_working("thinking")
  local prompt = turn.request .. (M.context and editor_state(root, turn) or "")
  if M.on_prompt then
    M.on_prompt(prompt)
  end
  local function finish(kind, text)
    busy[root] = nil
    release(turn)
    if not turn.dropped then
      show_result(kind, text)
      if M.on_done then
        M.on_done(kind, text)
      end
    end
    pump(root, not turn.dropped)
  end
  local retried = false
  local function send()
    conversation(root, turn, function(err, conv)
      if turn.dropped then
        return finish()
      end
      if err then
        return finish("error", err.message or tostring(err))
      end
      turn.conv = conv
      conv:send(prompt, {
        on_event = function(ev)
          if ev.type == "tool_call" and busy[root] == turn then
            show_working(activity(root, ev.name, ev.input))
          end
        end,
      }, function(e, result)
        if turn.dropped then
          return finish()
        end
        if e then
          -- Another Neovim's request got there first: this one runs after it.
          if tostring(e.message):find("Already streaming", 1, true) then
            busy[root] = nil
            queue[root] = queue[root] or {}
            table.insert(queue[root], 1, turn)
            following(root)
            return draw_card()
          end
          -- The daemon dropped it (idle too long, a reinstall): once more, in a new one.
          if not retried and (e.code == "ended" or tostring(e.message):lower():find("conversation")) then
            retried = true
            convs[root] = nil
            return send()
          end
          return finish("error", e.message or tostring(e))
        end
        if result.stop_reason == "aborted" then
          return finish("error", "Stopped.")
        end
        if result.stop_reason == "error" then
          return finish("error", result.error or "The model failed.")
        end
        finish("done", result.text ~= "" and result.text or (#turn.did > 0 and table.concat(turn.did, ", ") or "Done."))
      end)
    end)
  end
  send()
end

--- The next waiting request runs, if the conversation is free.
pump = function(root, follows)
  local waiting = queue[root]
  if waiting and waiting[1] and not busy[root] and not foreign[root] then
    start(root, table.remove(waiting, 1), follows)
  end
end

-- ── The other Neovims in the folder ───────────────────────────────────────

--- Can this buffer show another Neovim's edit as an edit? Its unsaved changes
--- keep it out of this, and Vim warns about the file as usual; a CRLF file or
--- another encoding is left to 'autoread'.
local function followable(b)
  if not api.nvim_buf_is_loaded(b) then
    return false
  end
  local bo = vim.bo[b]
  return not bo.modified and bo.fileformat == "unix" and (bo.fileencoding == "" or bo.fileencoding == "utf-8")
end

--- Another Neovim's request is writing this buffer's file. Until `let_go` the
--- reload timer can't read it over the green: without 'autoread' a change on disk
--- runs this autocmd instead, and "keep" (a patch of this fork) says the buffer
--- has the file, so that :write doesn't warn about it. Returns the hold, if any.
local function hold(b, turn)
  local held = turn.held[b]
  if held then
    held.calls = held.calls + 1
  elseif followable(b) then
    vim.bo[b].autoread = false
    held = {
      calls = 1,
      autocmd = api.nvim_create_autocmd("FileChangedShell", {
        buffer = b,
        callback = function()
          local reason = vim.v.fcs_reason
          vim.v.fcs_choice = (reason == "conflict" or reason == "deleted") and "ask" or "keep"
        end,
      }),
    }
    turn.held[b] = held
  end
  return held
end

--- The buffer shows what's in its file, the way the asker's does (green, one u).
local function show_file(b, turn)
  if followable(b) then
    local f = io.open(api.nvim_buf_get_name(b), "rb")
    if f then
      local data = f:read("*a")
      f:close()
      apply(b, split(data), turn)
      vim.bo[b].modified = false
    end
  end
end

local function let_go(b, turn)
  local held = turn.held[b]
  turn.held[b] = nil
  if api.nvim_buf_is_loaded(b) then
    pcall(vim.cmd, "silent! checktime " .. b) -- the change on disk, if the timer hasn't seen it
    api.nvim_buf_call(b, function()
      vim.cmd("setlocal autoread<")
    end)
  end
  pcall(api.nvim_del_autocmd, held.autocmd)
end

--- Its end: any buffer still held shows its file.
local function let_all_go(turn)
  for b in pairs(turn.held) do
    show_file(b, turn)
    let_go(b, turn)
  end
end

--- What another Neovim's tool call did, done here too. `failed`: nothing did,
--- but its file is let go.
local function follow_tool(root, call, turn, failed)
  local name, input = call.name, call.input
  local sidebar = require("yeyito.sidebar")
  if name == "edit_file" or name == "write_file" then
    local path = resolve(root, input.path)
    local b = vim.fn.bufnr(path)
    local held = b > 0 and (turn.held[b] or hold(b, turn))
    if held then
      show_file(b, turn)
      held.calls = held.calls - 1
      if held.calls <= 0 then
        let_go(b, turn)
      end
    end
    sidebar.changed(path)
  elseif failed then
    return
  elseif name == "move_path" then
    local from, to = resolve(root, input.from), resolve(root, input.to)
    files.moved_elsewhere(from, to)
    sidebar.moved(from, to)
    sidebar.changed(to)
  elseif name == "delete_path" then
    files.deleted_elsewhere(resolve(root, input.path))
    sidebar.changed()
  end
end

--- Another Neovim's request ended (`kind`, `text`: how, unless that's unknown):
--- what it did by other means shows, and this Neovim's next request can run.
local function foreign_ended(root, kind, text)
  let_all_go(foreign[root])
  foreign[root] = nil
  pcall(vim.cmd, "silent! checktime")
  require("yeyito.sidebar").changed()
  if root == project() then
    if kind then
      show_result(kind, text)
    elseif not busy[root] then
      close_card()
    end
  end
  pump(root, true)
end

--- Another Neovim's request runs in `root`. Returns what's kept of it.
following = function(root)
  if foreign[root] then
    return foreign[root]
  end
  local turn = { touched = {}, calls = {}, held = {} }
  foreign[root] = turn
  if root == project() then
    card.root, card.lines = root, {}
    show_working("thinking")
  end
  -- Its end can pass unseen (the connection dropped): the daemon knows.
  local function check()
    if foreign[root] ~= turn then
      return
    end
    if not client or client.closed then
      return foreign_ended(root)
    end
    client:list({}, function(e, list)
      if foreign[root] ~= turn then
        return
      end
      local running = e ~= nil
      for _, info in ipairs(list or {}) do
        if convs[root] and info.convId == convs[root].id then
          running = info.streaming
        end
      end
      if running then
        vim.defer_fn(check, FOLLOW_CHECK)
      else
        foreign_ended(root)
      end
    end)
  end
  vim.defer_fn(check, FOLLOW_CHECK)
  return turn
end

--- What's running and waiting in `root` goes, and the card.
local function drop(root)
  for _, t in ipairs(queue[root] or {}) do
    release(t)
  end
  queue[root] = nil
  if busy[root] then
    busy[root].dropped = true
  end
  if foreign[root] then
    let_all_go(foreign[root])
    foreign[root] = nil
  end
  close_card()
end

local function daemon_event(ev)
  local t = ev.type
  if t == "app_conversation_created" then
    -- Two Neovims that started one at the same moment settle on the same one.
    local info, root = ev.conversation, project()
    if info and info.cwd == root and client and not (convs[root] and convs[root].id <= info.convId) then
      join(client, root, info.convId, function() end)
    end
    return
  end
  local root
  for r, conv in pairs(convs) do
    if conv.id == ev.convId then
      root = r
    end
  end
  if not root then
    return
  end
  if t == "conversation_deleted" then
    convs[root] = nil
    if ev.reason == "deleted" then -- another Neovim's :Ai new
      drop(root)
    elseif foreign[root] then
      foreign_ended(root)
    end
  elseif busy[root] then
    return -- this Neovim's own: start() has it
  elseif t == "streaming_started" or t == "user_message" or t == "turn_catchup" then
    following(root)
  elseif t == "tool_call" then
    local turn = following(root)
    local call = {
      name = tostring(ev.toolName):gsub("^mcp__app__", ""),
      input = type(ev.input) == "table" and ev.input or {},
    }
    turn.calls[ev.toolCallId] = call
    if call.name == "edit_file" or call.name == "write_file" then
      local b = vim.fn.bufnr(resolve(root, call.input.path))
      if b > 0 then
        hold(b, turn)
      end
    end
    if root == project() then
      show_working(activity(root, ev.toolName, ev.input))
    end
  elseif t == "tool_result" then
    local turn = foreign[root]
    local call = turn and turn.calls[ev.toolCallId]
    if call then
      follow_tool(root, call, turn, ev.isError)
    end
  elseif t == "turn_result" and foreign[root] then
    if ev.stopReason == "aborted" then
      foreign_ended(root, "error", "Stopped.")
    elseif ev.stopReason == "error" then
      foreign_ended(root, "error", ev.error or "The model failed.")
    else
      foreign_ended(root, "done", ev.text ~= "" and ev.text or "Done.")
    end
  end
end

on_daemon_event = function(ev)
  -- The client reads on after this: a failure here must not lose it the event.
  local ok, err = pcall(daemon_event, ev)
  if not ok then
    vim.notify("AI: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Join the current project's conversation, if it has one, so that this Neovim
--- shows what the others do there. Silent: no daemon, no AI until asked.
function M.sync()
  find(project(), function() end)
end

--- Ask the model to do `request` in the current project, now or, while it works
--- there, when what it's doing ends. `sel`: the selected lines, { buf, first, last }.
function M.ask(request, sel)
  request = vim.trim(request or "")
  if request == "" then
    return
  end
  local root = project()
  local turn = new_turn(request, sel)
  if busy[root] or foreign[root] then
    queue[root] = queue[root] or {}
    table.insert(queue[root], turn)
    card.root = root
    draw_card()
    return
  end
  start(root, turn, false)
end

--- Ctrl+Q: stop the request running in this project, whichever Neovim asked it.
--- True if there was one.
function M.stop()
  local root = project()
  local conv = busy[root] and busy[root].conv or foreign[root] and convs[root]
  if not conv then
    return false
  end
  conv:abort()
  return true
end

--- The box in the middle of the editor; `sel` as in editor_state.
function M.open(sel)
  local name = api.nvim_buf_get_name(0)
  local title = "Ask AI"
  if sel then
    title = title .. " · " .. (sel.last - sel.first + 1) .. " line" .. (sel.last > sel.first and "s" or "") .. " of " .. vim.fs.basename(name)
  elseif name ~= "" and vim.bo.buftype == "" then
    title = title .. " · " .. vim.fs.basename(name)
  end
  require("yeyito.sidebar").prompt({
    title = title,
    placeholder = "what to do",
    vim = true,
    text = draft,
    on_submit = function(text)
      draft = nil
      M.ask(text, sel)
    end,
    on_cancel = function(text)
      -- Kept for the next time the box opens.
      draft = vim.trim(text) ~= "" and text or nil
    end,
  })
end

local function selection(first, last)
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  return { buf = buf, first = math.min(first, last), last = math.max(first, last) }
end

--- The log's text: `entries` (the daemon's history), then what waits here.
local function log_lines(root, entries)
  local lines = { "# AI · " .. vim.fs.basename(root), "" }
  local function add(text)
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  local last_request
  for i, entry in ipairs(entries) do
    if entry.type == "user" then
      last_request = i
    end
  end
  local running = busy[root] or foreign[root]
  for i, entry in ipairs(entries) do
    if entry.type == "user" then
      vim.list_extend(lines, { "## You" .. (running and i == last_request and " (running)" or ""), "" })
      add((entry.text:gsub("\n\n<editor>\n.*\n</editor>$", "")))
    elseif entry.type == "ai" then
      local did, reply = {}, {}
      for _, block in ipairs(entry.blocks or {}) do
        if block.type == "tool_call" then
          did[#did + 1] = "- " .. activity(root, block.toolName, block.input)
        elseif block.type == "text" then
          reply[#reply + 1] = block.text
        end
      end
      if #did > 0 then
        vim.list_extend(lines, did)
        lines[#lines + 1] = ""
      end
      if #reply > 0 then
        vim.list_extend(lines, { "## " .. model_label(), "" })
        add(table.concat(reply, "\n\n"))
      end
    end
  end
  for _, t in ipairs(queue[root] or {}) do
    vim.list_extend(lines, { "## You (queued)", "" })
    add(t.request)
  end
  if #lines == 2 then
    lines[#lines + 1] = "Nothing asked in this project yet."
  end
  return lines
end

--- :Ai log: the conversation so far (every Neovim's requests in the project),
--- what was done, the replies.
function M.show_log()
  local root = project()
  local function show(entries)
    local lines = log_lines(root, entries)
    vim.cmd("botright vnew")
    local b = api.nvim_get_current_buf()
    vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = "nofile", "wipe", false
    api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].modifiable = false
    vim.bo[b].filetype = "markdown"
    pcall(api.nvim_buf_set_name, b, "ai://log")
  end
  find(root, function(err, conv)
    if err or not conv then
      return show({})
    end
    client:request({
      type = "load_conversation_history",
      convId = conv.id,
      beforeEntryIndex = 1000000000, -- the end
      turns = 100,
    }, function(ev)
      return ev.type == "conversation_history_loaded"
    end, function(e, ev)
      show(e and {} or ev.entries)
    end)
  end)
end
--- :Ai new: end the project's conversation, in every Neovim there; the next
--- request starts a new one.
function M.reset()
  local root = project()
  drop(root)
  find(root, function(_, conv)
    if conv then
      convs[root] = nil
      conv:delete()
    end
  end)
  vim.notify("A new AI conversation from the next request")
end

local function highlights()
  local set = require("yeyito.colors").set_hl
  set(0, "YeyitoAiChanged", { bg = "#0b2a1c" }) -- Exocortex's success green, as a faint background
  set(0, "YeyitoAiWorking", { bg = "#0f193c" })
  set(0, "YeyitoAiCard", { fg = "#ffffff", bg = "#030814" })
  set(0, "YeyitoAiCardBorder", { fg = "#1d9bf0", bg = "#030814" })
  set(0, "YeyitoAiHead", { fg = "#1d9bf0", bg = "#030814" })
  set(0, "YeyitoAiDone", { fg = "#50c878", bg = "#030814" })
  set(0, "YeyitoAiError", { fg = require("yeyito.colors").palette.red, bg = "#030814" })
  set(0, "YeyitoAiCode", { fg = "#ffffff", bg = "#162030" }) -- Exocortex's inline code
end

function M.setup()
  highlights()
  local group = api.nvim_create_augroup("yeyito.ai", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if card.win and api.nvim_win_is_valid(card.win) then
        draw_card()
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if client then
        -- A request can't go on without the Neovim that runs its tools.
        for _, turn in pairs(busy) do
          if turn.conv then
            turn.conv:abort()
          end
        end
        client:close() -- temporary conversations stay for the next Neovim
      end
    end,
  })
  local function sync()
    if vim.g.yeyito_ai_sync and #api.nvim_list_uis() > 0 then
      M.sync()
    end
  end
  api.nvim_create_autocmd("UIEnter", { group = group, once = true, callback = vim.schedule_wrap(sync) })
  api.nvim_create_autocmd("DirChanged", { group = group, callback = vim.schedule_wrap(sync) })
  vim.keymap.set("n", "<leader>a", function()
    M.open(nil)
  end, { desc = "Ask the AI (Exocortex)" })
  vim.keymap.set("x", "<leader>a", function()
    local sel = selection(vim.fn.line("v"), vim.fn.line("."))
    vim.cmd([[execute "normal! \<Esc>"]])
    M.open(sel)
  end, { desc = "Ask the AI about the selection" })
  -- Ctrl+Q stops it, as in Exocortex; otherwise Ctrl+Q is what it was.
  vim.keymap.set({ "n", "i", "x" }, "<C-q>", function()
    return M.stop() and "" or "<C-q>"
  end, { expr = true, desc = "Stop the AI" })
  -- Esc pressed in normal mode (this runs before the key does, so the mode is
  -- the one it was pressed in) with nothing else to do (not leaving insert or
  -- visual mode, closing a box or menu, a float, or cancelling a sidebar
  -- delete) puts the reply card away, else the green block under the cursor.
  -- `typed`: the sidebar maps Esc.
  vim.on_key(function(_, typed)
    if
      typed ~= "\27"
      or api.nvim_get_mode().mode ~= "n"
      or api.nvim_win_get_config(0).relative ~= ""
      or require("yeyito.sidebar").delete_pending()
    then
      return
    end
    if card.win and card.kind ~= "working" then
      vim.schedule(close_card)
    else
      local buf, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1] - 1
      vim.schedule(function()
        clear_block(buf, row)
      end)
    end
  end, working_ns)
  api.nvim_create_user_command("Ai", function(o)
    if o.args == "new" then
      return M.reset()
    elseif o.args == "log" then
      return M.show_log()
    elseif o.args == "clear" then
      return M.clear_changes()
    end
    local sel = o.range > 0 and selection(o.line1, o.line2) or nil
    if o.args == "" then
      return M.open(sel)
    end
    M.ask(o.args, sel)
  end, {
    nargs = "*",
    range = true,
    desc = "Ask the AI (Exocortex): :Ai request, :Ai new, :Ai log, :Ai clear",
    complete = function(lead)
      return vim.tbl_filter(function(c)
        return vim.startswith(c, lead)
      end, { "new", "log", "clear" })
    end,
  })
  -- :ai works too.
  vim.cmd([[cnoreabbrev <expr> ai getcmdtype() ==# ':' && getcmdline() =~# '^\%(''<,''>\)\=ai$' ? 'Ai' : 'ai']])
end

M._tools = tools -- for tests
M._card = card
M._show = show_result

return M
