-- Manual completion on built-in insert-mode completion (what nvim-cmp did):
--   <C-Space>  open: file names when typing a path, otherwise LSP items
--              followed by words from open buffers
--   <Tab>/<S-Tab>  next/previous item, or jump through a snippet
--   <CR>       accept the selected (or first) item; LSP side effects such as
--              auto-imports and snippet expansion apply on accept
local M = {}

local map = vim.keymap.set

local function termcodes(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

-- Fuzzy score against the word being typed. LSP items come scored by core;
-- buffer words are scored the same way so both rank together, as in nvim-cmp.
local scores = setmetatable({}, { __mode = "k" })
local function score(item)
  if item._fuzzy_score or scores[item] then
    return item._fuzzy_score or scores[item]
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local typed = vim.api.nvim_get_current_line():sub(1, col):match("[%w_]*$")
  local s = typed ~= "" and vim.fn.matchfuzzypos({ item.word }, typed)[3][1] or 0
  scores[item] = s
  return s
end

-- Best match first; on a tie LSP items (in the server's order) before words.
local function by_score(a, b)
  local sa, sb = score(a), score(b)
  if sa ~= sb then
    return sa > sb
  end
  local la = vim.tbl_get(a, "user_data", "nvim", "lsp", "completion_item")
  local lb = vim.tbl_get(b, "user_data", "nvim", "lsp", "completion_item")
  if (la == nil) ~= (lb == nil) then
    return la ~= nil
  end
  if la then
    return (la.sortText or la.label) < (lb.sortText or lb.label)
  end
  return a.word < b.word
end

-- The path-ish word before the cursor contains a slash (./x, ~/x, /x, a/b).
local function typing_path()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local word = vim.api.nvim_get_current_line():sub(1, col):match("[^%s'\"`(){}%[%]=,;<>]*$")
  return word:find("/") ~= nil and not word:find("://", 1, true)
end

local function open()
  if vim.fn.pumvisible() == 1 then
    return
  end
  if typing_path() then
    vim.api.nvim_feedkeys(termcodes("<C-x><C-f>"), "n", false)
    return
  end
  -- Ask the servers first; their reply is merged into the buffer-word menu
  -- that <C-n> opens right away (vim.lsp.completion keeps non-LSP items).
  if next(vim.lsp.get_clients({ bufnr = 0, method = "textDocument/completion" })) then
    vim.lsp.completion.get()
  end
  vim.api.nvim_feedkeys(termcodes("<C-n>"), "n", false)
end

function M.setup()
  vim.opt.completeopt = { "menu", "menuone", "noselect", "popup", "fuzzy" }
  -- No "match 1 of 2" / "Pattern not found" chatter.
  vim.opt.shortmess:append("c")

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("yeyito.completion", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client:supports_method("textDocument/completion") then
        vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = false, cmp = by_score })
      end
    end,
  })

  map("i", "<C-Space>", open, { desc = "Complete" })

  map("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      return vim.fn.complete_info({ "selected" }).selected == -1 and "<C-n><C-y>" or "<C-y>"
    end
    return "<CR>"
  end, { expr = true, desc = "Accept completion or newline" })

  map({ "i", "s" }, "<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-n>"
    elseif vim.snippet.active({ direction = 1 }) then
      return "<Cmd>lua vim.snippet.jump(1)<CR>"
    end
    return "<Tab>"
  end, { expr = true, desc = "Next completion item or snippet field" })

  map({ "i", "s" }, "<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-p>"
    elseif vim.snippet.active({ direction = -1 }) then
      return "<Cmd>lua vim.snippet.jump(-1)<CR>"
    end
    return "<S-Tab>"
  end, { expr = true, desc = "Previous completion item or snippet field" })
end

return M
