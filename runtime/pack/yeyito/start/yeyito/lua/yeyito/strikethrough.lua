local M = {}

function M.toggle_lines(buf, first, last)
  first, last = math.min(first, last), math.max(first, last)
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  for i, line in ipairs(lines) do
    local indent, body, trailing = line:match("^(%s*)(.-)(%s*)$")
    if body ~= "" then
      -- Accept both the scratchpad's single tildes and standard double tildes.
      local inner = body:match("^~~(.-)~~$") or body:match("^~(.-)~$")
      lines[i] = indent .. (inner or ("~~" .. body .. "~~")) .. trailing
    end
  end
  -- One edit keeps a multi-line toggle together in undo history.
  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, lines)
end

function M.setup()
  vim.keymap.set("x", "<leader>s", function()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes("<Esc>", true, false, true) }, bang = true })
    M.toggle_lines(0, first, last)
  end, { desc = "Toggle strikethrough on selected lines" })
end

return M
