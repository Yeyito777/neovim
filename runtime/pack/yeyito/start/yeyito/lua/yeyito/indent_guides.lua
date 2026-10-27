-- Indent guides ("│" in a barely-visible blue), drawn the way
-- indent-blankline did with scope off: a guide at each open indent level,
-- capped so continuation lines don't sprout extra guides, and blank lines
-- borrow the guides of the next line.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("yeyito.indent_guides")
local CHAR = "│"

local INDENT, SPACE, TAB = 1, 2, 3

local exclude_ft = {
  [""] = true, lspinfo = true, packer = true, checkhealth = true, help = true, man = true,
  gitcommit = true, TelescopePrompt = true, TelescopeResults = true,
}
local exclude_bt = { terminal = true, nofile = true, quickfix = true, prompt = true }

local end_reg = vim.regex([[^\s*\(}\|]\|)\|end\)]])

-- indent-blankline's indent.get(): one entry per leading-whitespace column.
-- `state.stack` holds the widths of the enclosing (open) indents.
local function classify(ws, sw, ts, state)
  local tbl = {}
  local spaces, tabs, extra, since_tab = 0, 0, 0, 0
  local cap = state.stack[#state.stack] or 0
  if state.cap then
    cap = state.stack[1] or 0
    state.cap = false
  end
  for ch in ws:gmatch(".") do
    if ch == "\t" then
      local width = ts - ((since_tab + extra - ts) % ts)
      tabs = tabs + width
      tbl[#tbl + 1] = TAB
      for _ = 2, width do
        tbl[#tbl + 1] = SPACE
      end
      since_tab = 0
    else
      local mod = (spaces + tabs + extra) % sw
      if vim.list_contains(state.stack, spaces + tabs) then
        tbl[#tbl + 1] = INDENT
        extra = extra + mod
      elseif mod == 0 then
        if #tbl < cap then
          tbl[#tbl + 1] = INDENT
          extra = extra + mod
        else
          state.cap = true
          tbl[#tbl + 1] = SPACE
        end
      else
        tbl[#tbl + 1] = SPACE
      end
      spaces = spaces + 1
      since_tab = since_tab + 1
    end
  end
  return tbl, spaces + tabs
end

local function push(state, width, whitespace_only)
  state.stack = vim.tbl_filter(function(w)
    return w < width
  end, state.stack)
  if not whitespace_only then
    state.stack[#state.stack + 1] = width
  end
end

-- Virtual text per row (0-based) for the rows about to be drawn.
local function compute(win, buf, toprow, botrow)
  local ts = vim.bo[buf].tabstop
  local sw = vim.bo[buf].shiftwidth
  if sw == 0 then
    sw = ts
  end
  local leftcol = api.nvim_win_call(win, vim.fn.winsaveview).leftcol
  local last = api.nvim_buf_line_count(buf) - 1

  -- Start from an unindented line above the view so the stack is right, and
  -- read a little past the bottom so blank lines can see the next line.
  local first = math.max(0, toprow - 300)
  local stop = math.min(last, botrow + 100)
  local all = api.nvim_buf_get_lines(buf, first, stop + 1, false)
  local s = toprow - first + 1
  while s > 1 and not (all[s] and all[s] ~= "" and not all[s]:find("^%s")) do
    s = s - 1
  end
  local start = first + s - 1
  local lines = vim.list_slice(all, s)

  local state = { stack = {}, cap = false }
  local rows, prev_tbl, blank_tbl, blanks_left = {}, {}, nil, 0
  for i = 1, math.min(#lines, botrow - start + 1) do
    local line = lines[i]
    local tbl
    if line ~= "" then
      local ws = line:match("^%s+") or ""
      local width
      tbl, width = classify(ws, sw, ts, state)
      push(state, width, ws == line)
    elseif blanks_left > 0 then
      blanks_left = blanks_left - 1
      tbl = blank_tbl
    elseif i == #lines and start + i - 1 == last then
      tbl = {}
    else
      -- Use the next non-blank line's guides; one level more if it closes a block.
      local j = i + 1
      while j < #lines and lines[j] == "" do
        blanks_left = blanks_left + 1
        j = j + 1
      end
      local ws = lines[j]:match("^%s+") or ""
      local width
      tbl, width = classify(ws, sw, ts, state)
      push(state, width, false)
      if end_reg:match_str(lines[j]) then
        local top = state.stack[#state.stack]
        local trail, trail_ws = prev_tbl[top + 1], prev_tbl[top]
        if trail then
          tbl[#tbl + 1] = trail
        elseif trail_ws then
          tbl[#tbl + 1] = trail_ws == TAB and TAB or INDENT
        end
      end
      blank_tbl = tbl
    end
    if line == "" then
      tbl = vim.list_slice(tbl, 1, #tbl)
      while #tbl > 0 and tbl[#tbl] == SPACE do
        tbl[#tbl] = nil
      end
    end
    prev_tbl = tbl

    local row = start + i - 1
    if row >= toprow and #tbl > leftcol then
      local vt, any = {}, false
      for k = leftcol + 1, #tbl do
        if tbl[k] == SPACE then
          vt[#vt + 1] = { " " }
        else
          vt[#vt + 1] = { CHAR, "IblIndent" }
          any = true
        end
      end
      rows[row] = any and vt or nil
    end
  end
  return rows
end

local drawing = {} ---@type table<integer, table<integer, table>>

function M.setup()
  local colors = require("yeyito.colors")
  local function highlights()
    colors.set_hl(0, "IblIndent", { fg = colors.palette.cursorline, nocombine = true })
  end
  highlights()
  local group = api.nvim_create_augroup("yeyito.indent_guides", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })

  -- A line's guides depend on the lines around it, but Neovim only redraws
  -- the lines that changed: redraw the window when indentation may have
  -- shifted (line count, or the edited line's indent or blankness changed).
  local last = {} ---@type table<integer, string>
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
    group = group,
    callback = function(args)
      local line = api.nvim_get_current_line()
      local key = ("%d:%s:%s"):format(api.nvim_buf_line_count(args.buf), line:match("^%s*"), line:find("%S") and 1 or 0)
      if args.event == "TextChanged" or args.event == "InsertLeave" or last[args.buf] ~= key then
        api.nvim__redraw({ buf = args.buf, valid = false })
      end
      last[args.buf] = key
    end,
  })

  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf, toprow, botrow)
      if exclude_ft[vim.bo[buf].filetype] or exclude_bt[vim.bo[buf].buftype] then
        return false
      end
      drawing[win] = compute(win, buf, toprow, botrow)
    end,
    on_line = function(_, win, buf, row)
      local vt = drawing[win] and drawing[win][row]
      if vt then
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
          virt_text = vt,
          virt_text_pos = "overlay",
          hl_mode = "combine",
          priority = 1,
          ephemeral = true,
        })
      end
    end,
  })
end

return M
