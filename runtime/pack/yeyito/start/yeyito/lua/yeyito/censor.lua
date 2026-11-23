-- Files with secrets in them (g:yeyito_censored_files, by name: keys.sh,
-- secrets.sh) show the value of each assignment (NAME=value, export NAME="value",
-- a quoted one over several lines too, like a private key) and what's between
-- < and > as dots, so they can be opened with someone looking over your
-- shoulder. The value under the cursor shows as it is. Only the display: the
-- file, yanks and searches have the real text.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("yeyito.censor")
local DOT = "*"

local function censored(buf)
  local name = api.nvim_buf_get_name(buf)
  if name == "" then
    return false
  end
  local base = vim.fs.basename(name)
  for _, n in ipairs(vim.g.yeyito_censored_files or {}) do
    if base == n then
      return true
    end
  end
  return false
end

--- The last `q` in `line` at or after byte `from` (1-based), or nil.
local function last_quote(line, q, from)
  for i = #line, from, -1 do
    if line:sub(i, i) == q then
      return i
    end
  end
end

--- What shows as dots in `buf`, by row (0-based): a list of { from, to, id }
--- per row, byte columns (0-based, `to` exclusive), `id` the value it is part
--- of (a value over several rows has one id). Worked out again when the text
--- changes.
local cache = {} ---@type table<integer, { tick: integer, rows: table<integer, table[]> }>
local function regions(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if c and c.tick == tick then
    return c.rows
  end
  local rows, id = {}, 0
  local function add(row, from, to)
    if to > from then
      rows[row] = rows[row] or {}
      table.insert(rows[row], { from, to, id })
    end
  end
  local open ---@type string? the quote a value over several rows is waiting for
  for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    row = row - 1
    local value_from, value_to = 0, 0 -- the line's value, < > spans outside it
    if open then
      -- To the line's last such quote: a value can hold quotes (a cookie's
      -- JSON), and showing a bit too much would be the worse mistake.
      local close = last_quote(line, open, 1)
      value_to = close and close - 1 or #line
      add(row, 0, value_to)
      if close then
        open = nil
      end
    else
      local eq = select(2, line:find("^%s*export%s+[%a_][%w_]*=")) or select(2, line:find("^%s*[%a_][%w_]*="))
      if eq and eq < #line then
        id = id + 1
        local q = line:sub(eq + 1, eq + 1)
        if q == '"' or q == "'" then
          local close = last_quote(line, q, eq + 2)
          value_from, value_to = eq + 1, close and close - 1 or #line
          if not close then
            open = q
          end
        else
          value_from, value_to = eq, (line:find("%s", eq + 1) or #line + 1) - 1
        end
        add(row, value_from, value_to)
      end
    end
    local from = 1
    while true do
      local lt = line:find("<", from, true)
      local gt = lt and line:find(">", lt + 1, true)
      if not gt then
        break
      end
      if gt > lt + 1 and (gt <= value_from or lt > value_to) then
        id = id + 1
        add(row, lt, gt - 1)
      end
      from = gt + 1
    end
  end
  cache[buf] = { tick = tick, rows = rows }
  return rows
end

--- The id of the value under the cursor of `win`, and the rows it covers.
local function under_cursor(win, buf)
  local cur = api.nvim_win_get_cursor(win)
  local row, col = cur[1] - 1, cur[2]
  local rows = regions(buf)
  for _, r in ipairs(rows[row] or {}) do
    -- Its quotes or brackets count as on it too.
    if col >= r[1] - 1 and col <= r[2] then
      local first, last = row, row
      while rows[first - 1] and vim.iter(rows[first - 1]):any(function(x) return x[3] == r[3] end) do
        first = first - 1
      end
      while rows[last + 1] and vim.iter(rows[last + 1]):any(function(x) return x[3] == r[3] end) do
        last = last + 1
      end
      return r[3], first, last
    end
  end
end

local shown = {} ---@type table<integer, { id: integer, first: integer, last: integer }?> window -> value shown under its cursor

function M.setup()
  if vim.g.yeyito_censored_files == nil then
    vim.g.yeyito_censored_files = { "keys.sh", "secrets.sh" }
  end
  require("yeyito.colors").set_hl(0, "YeyitoCensored", { link = "NonText", default = true })

  local rows_of = {} ---@type table<integer, table> window -> the regions it is drawing
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf)
      if not censored(buf) then
        rows_of[win] = nil
        return false
      end
      rows_of[win] = regions(buf)
      local id, first, last = under_cursor(win, buf)
      shown[win] = id and { id = id, first = first, last = last } or nil
      return true
    end,
    on_line = function(_, win, buf, row)
      local list = rows_of[win] and rows_of[win][row]
      if not list then
        return
      end
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      local open = shown[win]
      for _, r in ipairs(list) do
        if not (open and open.id == r[3]) then
          -- A dot over each character, so it covers the text however it wraps.
          local col = r[1]
          while col < r[2] do
            local len = vim.str_utf_end(line, col + 1) + 1
            local ch = line:sub(col + 1, col + len)
            local width = ch == "\t" and 1 or vim.fn.strdisplaywidth(ch)
            api.nvim_buf_set_extmark(buf, ns, row, col, {
              virt_text = { { DOT:rep(math.max(width, 1)), "YeyitoCensored" } },
              virt_text_pos = "overlay",
              ephemeral = true,
            })
            col = col + len
          end
        end
      end
    end,
  })

  -- The value under the cursor changed: its rows are drawn again, in the
  -- redraw that follows (CursorMoved runs before it).
  local group = api.nvim_create_augroup("yeyito.censor", { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      if not censored(args.buf) then
        return
      end
      local win = api.nvim_get_current_win()
      local id, first, last = under_cursor(win, args.buf)
      local was = shown[win]
      if (was and was.id) ~= id then
        for _, span in ipairs({ { first, last }, { was and was.first, was and was.last } }) do
          if span[1] then
            api.nvim__redraw({ win = win, range = { span[1], span[2] + 1 }, flush = false })
          end
        end
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      cache[args.buf] = nil
    end,
  })
end

return M
