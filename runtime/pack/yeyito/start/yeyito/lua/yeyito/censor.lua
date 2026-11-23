-- Files with secrets in them (g:yeyito_censored_files, by name: keys.sh,
-- secrets.sh) show what's between < and > as dots, so they can be opened with
-- someone looking over your shoulder. The span under the cursor shows as it
-- is. Only the display: the file, yanks and searches have the real text.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("yeyito.censor")
local DOT = "•"

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

--- The <...> spans of `line`: { first, last } byte columns (0-based) of the
--- brackets, on one line, not nested.
local function spans(line)
  local out, from = {}, 1
  while true do
    local lt = line:find("<", from, true)
    if not lt then
      return out
    end
    local gt = line:find(">", lt + 1, true)
    if not gt then
      return out
    end
    if gt > lt + 1 then
      out[#out + 1] = { lt - 1, gt - 1 }
    end
    from = gt + 1
  end
end

--- The span under the cursor of `win`, as "row:col", or nil.
local function under_cursor(win, buf)
  local cur = api.nvim_win_get_cursor(win)
  local line = api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] or ""
  for _, s in ipairs(spans(line)) do
    if cur[2] >= s[1] and cur[2] <= s[2] then
      return cur[1] - 1, s[1]
    end
  end
end

local shown = {} ---@type table<integer, { row: integer, col: integer }?> window -> span shown under its cursor

function M.setup()
  if vim.g.yeyito_censored_files == nil then
    vim.g.yeyito_censored_files = { "keys.sh", "secrets.sh" }
  end
  require("yeyito.colors").set_hl(0, "YeyitoCensored", { link = "NonText", default = true })

  local active = {} ---@type table<integer, boolean> window -> drawing a censored buffer
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf)
      active[win] = censored(buf)
      if active[win] then
        local row, col = under_cursor(win, buf)
        shown[win] = row and { row = row, col = col } or nil
      end
      return active[win]
    end,
    on_line = function(_, win, buf, row)
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      if not line or not line:find("<", 1, true) then
        return
      end
      local open = shown[win]
      for _, s in ipairs(spans(line)) do
        if not (open and open.row == row and open.col == s[1]) then
          -- A dot over each character, so it covers the text however it wraps.
          local col = s[1] + 1
          while col < s[2] do
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

  -- The span under the cursor changed: its lines are drawn again, in the
  -- redraw that follows (CursorMoved runs before it).
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = api.nvim_create_augroup("yeyito.censor", { clear = true }),
    callback = function(args)
      if not censored(args.buf) then
        return
      end
      local win = api.nvim_get_current_win()
      local row, col = under_cursor(win, args.buf)
      local was = shown[win]
      if (was and was.row) ~= row or (was and was.col) ~= col then
        local rows = { row, was and was.row }
        for _, r in pairs(rows) do
          api.nvim__redraw({ win = win, range = { r, r + 1 }, flush = false })
        end
      end
    end,
  })
end

return M
