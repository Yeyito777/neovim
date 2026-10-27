-- Tree-sitter text objects and motions, with nvim-treesitter-textobjects'
-- selection rules; queries are the vendored queries/<lang>/textobjects.scm.
--   af/if  function   ac/ic  class      (visual + operator-pending)
--   <Space>u/<Space>i  next/previous function start
--   ]]/[[              next/previous class start
local M = {}

local api = vim.api

--- Every range of `capture` in the buffer, across injected languages too.
--- @return { [1]: integer, [2]: integer, [3]: integer, [4]: integer, len: integer, sbyte: integer }[]
local function collect(buf, capture)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  parser:parse(true)

  local ranges = {}
  local function add(first, last)
    local sr, sc, sb = first:start()
    local er, ec, eb = last:end_()
    ranges[#ranges + 1] = { sr, sc, er, ec, len = eb - sb, sbyte = sb }
  end

  parser:for_each_tree(function(tree, ltree)
    local qok, query = pcall(vim.treesitter.query.get, ltree:lang(), "textobjects")
    if not qok or not query then
      return
    end
    for pattern, match in query:iter_matches(tree:root(), buf, 0, -1) do
      -- A capture can hold several nodes; like the plugin (written for
      -- Neovim's old single-node matches), use the last one.
      for id, nodes in pairs(match) do
        if query.captures[id] == capture then
          add(nodes[#nodes], nodes[#nodes])
        end
      end
      -- (#make-range! "function.inner" @_start @_end) spans several nodes.
      for _, pred in ipairs(query.info.patterns[pattern] or {}) do
        if pred[1] == "make-range!" and pred[2] == capture then
          local first, last = match[pred[3]], match[pred[4]]
          if first and last then
            add(first[#first], last[#last])
          end
        end
      end
    end
  end)
  return ranges
end

local function contains(r, row, col)
  return (r[1] < row or r[1] == row and r[2] <= col) and (row < r[3] or row == r[3] and col + 1 <= r[4])
end

local function encloses(outer, r)
  return (outer[1] < r[1] or outer[1] == r[1] and outer[2] <= r[2])
    and (r[3] < outer[3] or r[3] == outer[3] and r[4] <= outer[4])
end

-- The smallest range around the cursor; failing that (with lookahead) the
-- first one starting after it, preferring the larger on a tie.
local function best(ranges, row, col, lookahead)
  local smallest, ahead
  for _, r in ipairs(ranges) do
    if contains(r, row, col) then
      if not smallest or r.len < smallest.len then
        smallest = r
      end
    elseif lookahead and (r[1] > row or r[1] == row and r[2] > col) then
      if not ahead or r.sbyte < ahead.sbyte or r.sbyte == ahead.sbyte and r.len > ahead.len then
        ahead = r
      end
    end
  end
  return smallest or ahead
end

-- "@x.inner" is searched inside the "@x.outer" around the cursor first.
local function textobject_at(buf, capture, row, col)
  local ranges = collect(buf, capture)
  if capture:match("%.outer$") then
    return best(ranges, row, col, true)
  end
  local outer = best(collect(buf, (capture:gsub("%..*", ".outer"))), row, col, false)
  if not outer then
    return best(ranges, row, col, true)
  end
  local within = vim.tbl_filter(function(r)
    return encloses(outer, r)
  end, ranges)
  if #within == 0 then
    return best(ranges, row, col, true)
  end
  return best(within, row, col, true) or best(within, outer[1], outer[2], true)
end

local function select(capture)
  local cursor = api.nvim_win_get_cursor(0)
  local r = textobject_at(api.nvim_get_current_buf(), capture, cursor[1] - 1, cursor[2])
  if not r then
    return
  end
  local erow, ecol = r[3] + 1, r[4]
  if ecol == 0 then
    -- Ends at the start of a line: select through the end of the previous one.
    erow = erow - 1
    ecol = math.max(#api.nvim_buf_get_lines(0, erow - 1, erow, false)[1], 1)
  end
  if api.nvim_get_mode().mode ~= "v" then
    vim.cmd("normal! v")
  end
  api.nvim_win_set_cursor(0, { r[1] + 1, r[2] })
  vim.cmd("normal! o")
  api.nvim_win_set_cursor(0, { erow, ecol - 1 })
end

local function goto_start(capture, forward)
  local buf = api.nvim_get_current_buf()
  for _ = 1, vim.v.count1 do
    local cursor = api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]
    local target
    for _, r in ipairs(collect(buf, capture)) do
      if forward then
        if (r[1] > row or r[1] == row and r[2] > col) and (not target or r.sbyte < target.sbyte) then
          target = r
        end
      elseif (r[1] < row or r[1] == row and r[2] < col) and (not target or r.sbyte > target.sbyte) then
        target = r
      end
    end
    if not target then
      return
    end
    if not api.nvim_get_mode().mode:find("^no") then
      vim.cmd("normal! m'") -- jumplist, so <C-o> comes back
    end
    api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
  end
end

local selects = { af = "function.outer", ["if"] = "function.inner", ac = "class.outer", ic = "class.inner" }
local moves = {
  ["<Space>u"] = { "function.outer", true },
  ["]]"] = { "class.outer", true },
  ["<Space>i"] = { "function.outer", false },
  ["[["] = { "class.outer", false },
}

local function attach(buf)
  for lhs, capture in pairs(selects) do
    vim.keymap.set({ "x", "o" }, lhs, function()
      select(capture)
    end, { buffer = buf, silent = true, desc = "Select @" .. capture })
  end
  for lhs, move in pairs(moves) do
    vim.keymap.set({ "n", "x", "o" }, lhs, function()
      goto_start(move[1], move[2])
    end, { buffer = buf, silent = true, desc = (move[2] and "Next @" or "Previous @") .. move[1] .. " start" })
  end
end

function M.setup()
  -- Only buffers whose language has textobject queries, so ]] and [[ keep
  -- their built-in meaning elsewhere.
  api.nvim_create_autocmd("FileType", {
    group = api.nvim_create_augroup("yeyito.textobjects", { clear = true }),
    callback = function(args)
      local lang = vim.treesitter.language.get_lang(args.match)
      if lang and vim.treesitter.language.add(lang) and #vim.treesitter.query.get_files(lang, "textobjects") > 0 then
        attach(args.buf)
      end
    end,
  })
end

return M
