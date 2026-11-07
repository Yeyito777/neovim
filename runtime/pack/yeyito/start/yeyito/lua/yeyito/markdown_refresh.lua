local M = {}

-- The installed Markdown inline parser can reuse a stale tree when editing
-- adjacent ~struck~ lines (e.g. crossing out one task unhighlights its neighbor).
-- The stale tree is always one an edit touched, or the paragraph beside it:
-- have those parsed afresh, and leave the rest of the document (and block
-- parsing and fenced languages) alone. Reparsing the whole buffer cost 40 ms
-- a key in a long draft.

-- Rows (0-based, inclusive) changed since each reader last took them, per
-- buffer: this module's refresh and markdown_links'.
local changed = {} ---@type table<integer, table<string, { [1]: integer, [2]: integer }|false>>

local function grow(span, row, old_rows, new_rows)
  if not span then return { row, row + new_rows } end
  -- Rows below the edit move with it.
  if row <= span[2] then span[2] = math.max(row, span[2] + new_rows - old_rows) end
  span[1] = math.min(span[1], row)
  span[2] = math.max(span[2], row + new_rows)
  return span
end

local function grow_all(buf, row, old_rows, new_rows)
  local spans = changed[buf]
  if not spans then return true end
  for who, span in pairs(spans) do
    spans[who] = grow(span, row, old_rows, new_rows)
  end
end

-- Follow a buffer's edits (once per buffer): the rows edited, and the rows
-- the block structure changed in (a ``` fences off the rest of the file).
function M.track(buf)
  if changed[buf] then return end
  changed[buf] = {}
  vim.api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, b, _, row, _, _, old_rows, _, _, new_rows)
      return grow_all(b, row, old_rows, new_rows)
    end,
    on_detach = function(_, b) changed[b] = nil end,
  })
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if ok and parser then
    parser:register_cbs({
      on_changedtree = function(ranges)
        for _, r in ipairs(ranges) do
          grow_all(buf, r[1], 0, r[4] - r[1])
        end
      end,
    })
  end
end

-- The rows `who` hasn't seen change yet, and from now on none (`keep`: still
-- them). nil: unknown (not followed before), so all of them.
function M.take(buf, who, keep)
  local spans = changed[buf]
  if not spans then return nil end
  local span = spans[who]
  if not keep then spans[who] = false end
  if span == nil then return nil end
  return span and { span[1], span[2] } or false
end

function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "markdown" then
    return
  end
  if not vim.treesitter.highlighter.active[buf] then return end
  M.track(buf)
  local span = M.take(buf, "refresh")
  if span == false then return end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok then return end
  local inline = parser:children().markdown_inline
  if not inline then return end
  if not span then
    inline:invalidate(true)
    return
  end
  -- The inline trees an edit touched, and a row more each side (an edit can
  -- grow or shrink the paragraph beside it: a blank line typed into).
  local first, last
  for _, tree in pairs(inline:trees()) do
    local sr, sc, sb, er, ec, eb = tree:root():range(true)
    if sr <= span[2] + 1 and er >= span[1] - 1 then
      if not first or sb < first[3] then first = { sr, sc, sb } end
      if not last or eb > last[3] then last = { er, ec, eb } end
    end
  end
  if first then
    -- An edit that changes nothing, over all of them: their regions are
    -- parsed again, and none of their nodes can be reused.
    inline:_edit(first[3], last[3], last[3], first[1], first[2], last[1], last[2], last[1], last[2])
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("MarkdownInlineRefresh", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(args) M.track(args.buf) end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args) M.refresh(args.buf) end,
    desc = "Prevent stale Markdown strikethrough after edits",
  })
end

return M
