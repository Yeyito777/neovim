local M = {}

-- The installed Markdown inline parser can reuse a stale tree when editing
-- adjacent ~struck~ lines (e.g. crossing out one task unhighlights its neighbor).
-- Refresh only inline Markdown; leave block parsing and fenced languages alone.
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "markdown" then
    return
  end
  if not vim.treesitter.highlighter.active[buf] then return end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok then return end
  local inline = parser:children().markdown_inline
  if inline then inline:invalidate(true) end
  parser:parse(true)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("MarkdownInlineRefresh", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args) M.refresh(args.buf) end,
    desc = "Prevent stale Markdown strikethrough after edits",
  })
end

return M
