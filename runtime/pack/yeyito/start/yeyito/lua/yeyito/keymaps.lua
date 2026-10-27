local M = {}

local map = vim.keymap.set

-- Diagnostic jumps open the float at the new position, like the old
-- vim.diagnostic.goto_next()/goto_prev() did.
local function jump(count, severity)
  vim.diagnostic.jump({
    count = count,
    severity = severity,
    on_jump = function(_, bufnr)
      vim.diagnostic.open_float({ bufnr = bufnr, scope = "cursor", focus = false })
    end,
  })
end

local function jump_to_mark()
  local mark = vim.fn.getcharstr()
  if mark == " " then
    vim.cmd("normal! ``zz")
  else
    local pos = vim.fn.getpos("'" .. mark)
    if pos[2] == 0 then
      vim.notify("Mark '" .. mark .. "' is not set", vim.log.levels.WARN, { title = "Marks" })
    else
      vim.cmd("normal! `" .. mark .. "zz")
    end
  end
end

local function clone_line()
  local lnum = vim.fn.line(".")
  local line = vim.fn.getline(lnum)
  vim.fn.append(lnum, line)
end

local function substitute_word(confirm)
  local word = vim.fn.expand("<cword>")
  if word == "" then return end
  local escaped = vim.fn.escape(word, "/\\")
  local cmd = confirm and (":%s/\\<" .. escaped .. "\\>//gc<Left><Left><Left>")
    or (":%s/\\<" .. escaped .. "\\>//g<Left><Left>")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(cmd, true, false, true), "n", false)
end

-- Ctrl+1-9: Jump to (n*10)% of visible screen
local function jump_to_screen_percent(percent)
  local win_height = vim.api.nvim_win_get_height(0)
  local top_line = vim.fn.line("w0")
  local target_offset = math.floor((win_height - 1) * percent / 100 + 0.5)
  local target_line = top_line + target_offset
  local max_line = vim.fn.line("$")
  target_line = math.min(target_line, max_line)
  target_line = math.max(target_line, 1)
  local view = vim.fn.winsaveview()
  view.lnum = target_line
  vim.fn.winrestview(view)
end

function M.setup()
  -- Diagnostics
  map("n", "gl", vim.diagnostic.open_float)
  map("n", "]e", function() jump(1, vim.diagnostic.severity.ERROR) end, { desc = "Next error" })
  map("n", "[e", function() jump(-1, vim.diagnostic.severity.ERROR) end, { desc = "Previous error" })
  map("n", "]w", function() jump(1) end, { desc = "Next diagnostic" })
  map("n", "[w", function() jump(-1) end, { desc = "Previous diagnostic" })

  -- Move lines
  map("n", "<C-j>", ":m .+1<CR>==", { silent = true })
  map("n", "<C-k>", ":m .-2<CR>==", { silent = true })
  map("x", "<C-j>", ":m '>+1<CR>gv=gv", { silent = true })
  map("x", "<C-k>", ":m '<-2<CR>gv=gv", { silent = true })

  -- Explicit clipboard/register mappings:
  --   y/Y copy to the system clipboard; p/P paste from it.
  --   <leader>y/<leader>p operate on an internal Vim register.
  map({ "n", "v" }, "y", '"+y', { desc = "Yank to system clipboard" })
  map("n", "Y", '"+Y', { desc = "Yank line to system clipboard" })
  map({ "n", "v" }, "p", '"+p', { desc = "Paste from system clipboard" })
  map({ "n", "v" }, "P", '"+P', { desc = "Paste before from system clipboard" })
  map({ "n", "v" }, "<leader>y", '"zy', { desc = "Yank to internal Vim register" })
  map("n", "<leader>Y", '"zY', { desc = "Yank line to internal Vim register" })
  map({ "n", "v" }, "<leader>p", '"zp', { desc = "Paste from internal Vim register" })
  map({ "n", "v" }, "<leader>P", '"zP', { desc = "Paste before from internal Vim register" })

  map({ "n", "v" }, "<leader>j", jump_to_mark, { desc = "Jump to mark or last position and center" })
  map("n", "<leader>k", clone_line, { desc = "Clones the current line or selection below" })
  map({ "n", "x", "o" }, "<leader>l", "``zz", { desc = "Jump back and center" })

  map("n", "<leader>s", function() substitute_word(true) end, { desc = "Substitute word under cursor (confirm)" })
  map("n", "<leader>S", function() substitute_word(false) end, { desc = "Substitute word under cursor (no confirm)" })

  -- Modern terminal keyboard protocols distinguish Ctrl+/ from Ctrl+_.
  -- Keep the legacy keycode too for terminals that send ASCII 0x1f.
  for _, key in ipairs({ "<C-/>", "<C-_>" }) do
    map("n", key, "gcc", { remap = true, desc = "Toggle comment for current line" })
    map("x", key, "gc", { remap = true, desc = "Toggle comment for selection" })
  end

  -- Ctrl+1-9,0,-: F14-F24 keys (sent by st terminal)
  -- Ctrl+1 = 0%, Ctrl+2 = 10%, ..., Ctrl+9 = 80%, Ctrl+0 = 90%, Ctrl+- = 100%
  for i = 14, 24 do
    local pct = (i - 14) * 10
    map({ "n", "v" }, "<F" .. i .. ">", function()
      jump_to_screen_percent(pct)
    end, { desc = string.format("Jump to %d%% of screen", pct) })
  end

  -- Insert mode convenience bindings
  map("i", "<C-l>", "<CR>", { desc = "Insert newline" })

  -- F14-F24 in insert mode: special characters
  map("i", "<F14>", "←", { desc = "Insert left arrow" })
  map("i", "<F15>", "•", { desc = "Insert bullet point" })
  map("i", "<F16>", "→", { desc = "Insert right arrow" })
  map("i", "<F22>", "…", { desc = "Insert ellipsis" })
  map("i", "<F23>", "–", { desc = "Insert en dash" })
  map("i", "<F24>", "—", { desc = "Insert em dash" })
end

return M
