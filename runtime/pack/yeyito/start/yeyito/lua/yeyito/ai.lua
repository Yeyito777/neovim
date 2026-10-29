-- AI in the editor, on the user's Exocortex daemon (its app API; the client is
-- lua/exocortex, vendored from Exocortex). The model works on the project
-- through Neovim itself: it reads and edits buffers, creates, moves and
-- deletes files, and has a shell; edits are saved, undoable with one u, and
-- the language servers and the sidebar see them.
--   <leader>a        ask, in a box in the middle of the editor (visual mode:
--                    about the selected text)
--   :Ai [request]    the same from the command line (:ai too; with a range,
--                    about those lines); :Ai new  a fresh conversation;
--                    :Ai log  this session's requests and replies
--   Ctrl+Q           stop it while it works
-- One conversation per project (the working directory), hidden from the
-- Exocortex sidebar, kept until it has been idle an hour.
local M = {}

local api, uv = vim.api, vim.uv
local exo = require("exocortex")
local files = require("yeyito.files")

local APP = "nvim"
local IDLE_TTL = 60 * 60 * 1000
local STATE = vim.fn.stdpath("state") .. "/ai.json" -- project -> conversation id
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local READ_LIMIT = 2000 -- lines read_file returns at once

local changed_ns = api.nvim_create_namespace("yeyito.ai.changed")
local working_ns = api.nvim_create_namespace("yeyito.ai.working")

M.context = true -- each request carries the editor's state (tests turn it off)

local client ---@type table? the connection to the daemon
local connecting ---@type function[]? callbacks waiting for it
local convs = {} ---@type table<string, table> project -> conversation
local busy = {} ---@type table<string, table> project -> the running turn
local log = {} ---@type table<string, table[]> project -> { request, did, reply }
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

local function read_state()
  local f = io.open(STATE, "r")
  if not f then
    return {}
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or {}
end

local function write_state(root, id)
  local data = read_state()
  data[root] = id
  vim.fn.mkdir(vim.fs.dirname(STATE), "p")
  local f = io.open(STATE, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

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
    for _, fn in ipairs(waiting) do
      fn(err, c)
    end
  end)
end

--- The project's conversation: the one this Neovim has, else the last one it
--- had there (another Neovim, before a restart) while the daemon keeps it,
--- else a new one. Its tools are rebuilt for each request (`turn`).
local function conversation(root, turn, cb)
  with_client(function(err, c)
    if err then
      return cb(err)
    end
    local defs = tools(root, turn)
    local conv = convs[root]
    if conv and not conv.ended then
      conv:_set_tools(defs) -- the definitions are the same: only the handlers change
      return cb(nil, conv)
    end
    local function create()
      c:conversation({
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
        convs[root] = new
        write_state(root, new.id)
        cb(nil, new)
      end)
    end
    local saved = read_state()[root]
    if not saved then
      return create()
    end
    c:attach(saved, { tools = defs }, function(e, old)
      if e then
        return create() -- expired, or the daemon was reinstalled
      end
      convs[root] = old
      cb(nil, old)
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

--- `text` cut into lines of at most `width` columns, at spaces where it can.
local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= "" then
          out[#out + 1] = line
          line = ""
        end
        local cut = vim.fn.strcharpart(word, 0, width)
        out[#out + 1] = cut
        word = word:sub(#cut + 1)
      end
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        out[#out + 1] = line
        line = word
      end
    end
    out[#out + 1] = line
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
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
  local body = {}
  local nbsp = "\194\160"
  for _, line in ipairs(card.lines) do
    -- A `code span` isn't broken across lines (its backticks stay together).
    line = line:gsub("`[^`\n]+`", function(span)
      return (span:gsub(" ", nbsp))
    end)
    for _, l in ipairs(wrap(line, width - 2)) do
      body[#body + 1] = (l:gsub(nbsp, " "))
    end
  end
  if #body > MAX_LINES then
    body = vim.list_slice(body, 1, MAX_LINES - 1)
    body[#body + 1] = "… :Ai log shows it all"
  end
  local lines = { " " .. vim.fn.strcharpart(head, 0, width - 2) }
  -- `code` in the reply: without the backticks, in a colour of its own.
  local spans = {}
  for i, l in ipairs(body) do
    local text, from = " ", 1
    while true do
      local s, e = l:find("`[^`]+`", from)
      if not s then
        break
      end
      text = text .. l:sub(from, s - 1)
      spans[#spans + 1] = { i, #text, #text + (e - s - 1) }
      text = text .. l:sub(s + 1, e - 1)
      from = e + 1
    end
    lines[#lines + 1] = text .. l:sub(from)
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
  card.kind, card.status, card.lines = "working", status, {}
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

--- What the editor shows now: the file, the cursor, `sel` (the selected
--- lines: { buf, first, last, text }), for the request.
local function editor_state(root, sel)
  local out = {}
  local buf = api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buf)
  if name ~= "" and vim.bo[buf].buftype == "" then
    local path = vim.fs.normalize(name)
    out[#out + 1] = ("Open file: %s (cursor on line %d%s)"):format(
      rel(root, path),
      api.nvim_win_get_cursor(0)[1],
      vim.bo[buf].modified and "; it has unsaved changes" or ""
    )
  end
  if sel then
    local path = rel(root, vim.fs.normalize(api.nvim_buf_get_name(sel.buf)))
    local ft = vim.bo[sel.buf].filetype
    out[#out + 1] = ("Selected: %s, lines %d-%d:\n```%s\n%s\n```"):format(path, sel.first, sel.last, ft, sel.text)
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

--- Ask the model to do `request` in the current project; `sel` as in editor_state.
function M.ask(request, sel)
  request = vim.trim(request or "")
  if request == "" then
    return
  end
  local root = project()
  if busy[root] then
    vim.notify("The AI is still working: Ctrl+Q stops it", vim.log.levels.WARN)
    return
  end
  local turn = { touched = {}, did = {}, request = request, sel = sel }
  busy[root] = turn
  if sel and api.nvim_buf_is_valid(sel.buf) then
    turn.tint = { buf = sel.buf, id = api.nvim_buf_set_extmark(sel.buf, working_ns, sel.first - 1, 0, {
      end_row = sel.last - 1,
      line_hl_group = "YeyitoAiWorking",
      priority = 40,
    }) }
  end
  local prompt = request .. (M.context and editor_state(root, sel) or "")
  show_working("thinking")
  local function finish(kind, text)
    busy[root] = nil
    if turn.tint and api.nvim_buf_is_valid(turn.tint.buf) then
      pcall(api.nvim_buf_del_extmark, turn.tint.buf, working_ns, turn.tint.id)
    end
    log[root] = log[root] or {}
    table.insert(log[root], { request = request, did = turn.did, reply = text, kind = kind })
    show_result(kind, text)
    if M.on_done then
      M.on_done(kind, text)
    end
  end
  local retried = false
  local function send()
    conversation(root, turn, function(err, conv)
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
        if e then
          -- The daemon dropped it (idle too long, a reinstall): once more, in a new one.
          if not retried and (e.code == "ended" or tostring(e.message):lower():find("conversation")) then
            retried = true
            convs[root] = nil
            write_state(root, nil)
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

--- Ctrl+Q: stop the request running in this project. True if there was one.
function M.stop()
  local turn = busy[project()]
  if not (turn and turn.conv) then
    return false
  end
  turn.conv:abort()
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
  first, last = math.min(first, last), math.max(first, last)
  return { buf = buf, first = first, last = last, text = table.concat(api.nvim_buf_get_lines(buf, first - 1, last, false), "\n") }
end

--- :Ai log: this session's requests in the project, what was done, the replies.
function M.show_log()
  local root = project()
  local lines = { "# AI · " .. vim.fs.basename(root), "" }
  for _, t in ipairs(log[root] or {}) do
    vim.list_extend(lines, { "## You", "" })
    vim.list_extend(lines, vim.split(t.request, "\n", { plain = true }))
    lines[#lines + 1] = ""
    if #t.did > 0 then
      for _, d in ipairs(t.did) do
        lines[#lines + 1] = "- " .. d
      end
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, { "## " .. model_label() .. (t.kind == "error" and " (failed)" or ""), "" })
    vim.list_extend(lines, vim.split(t.reply, "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  if #(log[root] or {}) == 0 then
    lines[#lines + 1] = "Nothing asked in this project since Neovim started."
  end
  vim.cmd("botright vnew")
  local b = api.nvim_get_current_buf()
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = "nofile", "wipe", false
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].filetype = "markdown"
  pcall(api.nvim_buf_set_name, b, "ai://log")
end

--- :Ai new: forget the project's conversation; the next request starts a new one.
function M.reset()
  local root = project()
  local conv = convs[root]
  convs[root] = nil
  write_state(root, nil)
  if conv and not conv.ended then
    conv:delete()
  end
  log[root] = nil
  close_card()
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
        client:close() -- temporary conversations stay for the next Neovim
      end
    end,
  })
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
  -- Esc in normal mode puts the reply card away.
  vim.on_key(function(key)
    if card.win and card.kind ~= "working" and key == "\27" and api.nvim_get_mode().mode == "n" then
      vim.schedule(close_card)
    end
  end, working_ns)
  api.nvim_create_user_command("Ai", function(o)
    if o.args == "new" then
      return M.reset()
    elseif o.args == "log" then
      return M.show_log()
    end
    local sel = o.range > 0 and selection(o.line1, o.line2) or nil
    if o.args == "" then
      return M.open(sel)
    end
    M.ask(o.args, sel)
  end, {
    nargs = "*",
    range = true,
    desc = "Ask the AI (Exocortex): :Ai request, :Ai new, :Ai log",
    complete = function(lead)
      return vim.tbl_filter(function(c)
        return vim.startswith(c, lead)
      end, { "new", "log" })
    end,
  })
  -- :ai works too.
  vim.cmd([[cnoreabbrev <expr> ai getcmdtype() ==# ':' && getcmdline() =~# '^\%(''<,''>\)\=ai$' ? 'Ai' : 'ai']])
end

M._tools = tools -- for tests
M._card = card
M._show = show_result

return M
