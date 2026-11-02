-- Shift+J/K and ;, headless:
--   VIMRUNTIME=$PWD/runtime build/bin/nvim --headless -u NORC -c 'luafile test/yeyito/test_keys.lua'
local api = vim.api
local failures = 0
local function check(name, ok, detail)
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. ((not ok and detail ~= nil) and ("  " .. vim.inspect(detail)) or "") .. "\n")
  if not ok then
    failures = failures + 1
  end
end
local function keys(k)
  api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "mx", false)
end
local function cursor()
  return api.nvim_win_get_cursor(0)
end

vim.o.lines, vim.o.columns = 42, 80
vim.o.scrolloff = 0
local lines = {}
for i = 1, 200 do
  lines[i] = i % 10 == 0 and "short" or ("line " .. i .. " with plenty of text in it")
end
api.nvim_buf_set_lines(0, 0, -1, false, lines)
local rows = math.floor(math.floor(api.nvim_win_get_height(0) / 2) / 4)
check("the window is tall enough to mean something", rows >= 3, rows)

keys("gg")
keys("J")
check("J: down an eighth of the window", cursor()[1] == 1 + rows, cursor())
keys("K")
check("K: back up", cursor()[1] == 1, cursor())
keys("3J")
check("a count multiplies it", cursor()[1] == 1 + 3 * rows, cursor())
keys("gg")

-- The column stays, as with j/k, through a line too short for it.
api.nvim_win_set_cursor(0, { 10 - rows, 14 })
keys("J")
check("onto a short line: the cursor stops at its end", cursor()[1] == 10 and cursor()[2] == 4, cursor())
keys("J")
check("then it has its column back", cursor()[1] == 10 + rows and cursor()[2] == 14, cursor())

-- The view only moves past its edges, and only as far as it must.
keys("gg")
local top = vim.fn.line("w0")
keys("J")
check("inside the view it stays put", vim.fn.line("w0") == top, vim.fn.line("w0"))
api.nvim_win_set_cursor(0, { vim.fn.line("w$"), 0 })
local bottom = vim.fn.line("w$")
top = vim.fn.line("w0")
keys("J")
check("past the bottom it scrolls just enough", vim.fn.line("w$") == bottom + rows and vim.fn.line("w0") == top + rows,
  { vim.fn.line("w0"), vim.fn.line("w$") })

-- The ends of the file.
keys("G")
keys("K")
keys("J")
check("back down to the last line", cursor()[1] == 200, cursor())
keys("J")
check("at the last line it stays", cursor()[1] == 200, cursor())
api.nvim_win_set_cursor(0, { 198, 0 })
keys("J")
check("near the last line it goes to it", cursor()[1] == 200, cursor())
api.nvim_win_set_cursor(0, { 2, 0 })
keys("K")
check("near the first line it goes to it", cursor()[1] == 1, cursor())

-- Visual modes: the selection grows.
keys("gg")
keys("VJ")
local mode, sel_end = api.nvim_get_mode().mode, vim.fn.line(".")
keys("<Esc>")
check("visual-line: J extends the selection", mode == "V" and sel_end == 1 + rows, { mode, sel_end })
keys("gg")
keys("vJK")
mode, sel_end = api.nvim_get_mode().mode, vim.fn.line(".")
keys("<Esc>")
check("visual: J and K move its end", mode == "v" and sel_end == 1, { mode, sel_end })

-- J no longer joins.
local count = api.nvim_buf_line_count(0)
keys("ggJ")
check("J doesn't join lines", api.nvim_buf_line_count(0) == count)

-- ; without a language server: 'keywordprg'.
local looked_up
api.nvim_create_user_command("LookUp", function(o)
  looked_up = o.args
end, { nargs = "*" })
vim.bo.keywordprg = ":LookUp"
api.nvim_buf_set_lines(0, 0, 1, false, { "needle in a line" })
api.nvim_win_set_cursor(0, { 1, 0 })
keys(";")
check("; with no language server: 'keywordprg' on the word", looked_up == "needle", looked_up)
vim.bo.keywordprg = ""

-- ; with one: its hover. K stays Shift+K though Neovim maps K to hover by default.
local hovered = 0
local client = vim.lsp.start({
  name = "fake",
  cmd = function()
    return {
      request = function(method, _, callback)
        if method == "initialize" then
          callback(nil, { capabilities = { hoverProvider = true } })
        elseif method == "textDocument/hover" then
          hovered = hovered + 1
          callback(nil, { contents = "docs" })
        elseif method == "shutdown" then
          callback(nil, nil)
        end
      end,
      notify = function() end,
      is_closing = function()
        return false
      end,
      terminate = function() end,
    }
  end,
})
vim.wait(2000, function()
  return #vim.lsp.get_clients({ bufnr = 0 }) > 0 and vim.lsp.get_client_by_id(client).initialized
end, 10)
local here = cursor()[1]
keys(";")
vim.wait(2000, function()
  return hovered > 0
end, 10)
check("; with a language server: its hover", hovered == 1 and looked_up == "needle", { hovered, looked_up })
for _, win in ipairs(api.nvim_list_wins()) do
  if api.nvim_win_get_config(win).relative ~= "" then
    api.nvim_win_close(win, true)
  end
end
keys("J")
check("J and K still move in a buffer with a language server", cursor()[1] == here + rows and hovered == 1, { cursor(), hovered })
keys("K")
check("K isn't hover there", cursor()[1] == here and hovered == 1, { cursor(), hovered })
vim.lsp.get_client_by_id(client):stop(true)

io.stdout:write(failures .. " failure(s)\n")
vim.cmd(failures == 0 and "qa!" or "cq!")
