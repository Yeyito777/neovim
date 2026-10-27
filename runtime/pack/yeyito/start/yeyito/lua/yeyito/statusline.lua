-- The statusline lualine drew with the old config, cell for cell:
--   NORMAL │  main │ +1 ~2 -3  file.py [+]        E1 W2  Top │  12:4
-- Inactive windows show just the file name and position, in gray.
local M = {}

local api = vim.api
local colors = require("yeyito.colors")

local mode_names = {
  ["n"] = "NORMAL", ["no"] = "O-PENDING", ["nov"] = "O-PENDING", ["noV"] = "O-PENDING",
  ["no\22"] = "O-PENDING", ["niI"] = "NORMAL", ["niR"] = "NORMAL", ["niV"] = "NORMAL",
  ["nt"] = "NORMAL", ["ntT"] = "NORMAL",
  ["v"] = "VISUAL", ["vs"] = "VISUAL", ["V"] = "V-LINE", ["Vs"] = "V-LINE",
  ["\22"] = "V-BLOCK", ["\22s"] = "V-BLOCK",
  ["s"] = "SELECT", ["S"] = "S-LINE", ["\19"] = "S-BLOCK",
  ["i"] = "INSERT", ["ic"] = "INSERT", ["ix"] = "INSERT",
  ["R"] = "REPLACE", ["Rc"] = "REPLACE", ["Rx"] = "REPLACE",
  ["Rv"] = "V-REPLACE", ["Rvc"] = "V-REPLACE", ["Rvx"] = "V-REPLACE",
  ["c"] = "COMMAND", ["cv"] = "EX", ["ce"] = "EX",
  ["r"] = "REPLACE", ["rm"] = "MORE", ["r?"] = "CONFIRM", ["!"] = "SHELL", ["t"] = "TERMINAL",
}

local mode_kinds = {
  ["VISUAL"] = "visual", ["V-LINE"] = "visual", ["V-BLOCK"] = "visual",
  ["SELECT"] = "visual", ["S-LINE"] = "visual", ["S-BLOCK"] = "visual",
  ["REPLACE"] = "replace", ["V-REPLACE"] = "replace",
  ["INSERT"] = "insert",
  ["COMMAND"] = "command", ["EX"] = "command", ["MORE"] = "command", ["CONFIRM"] = "command",
}

-- The first of these groups that has a foreground color, as lualine picked them.
local fg_sources = {
  StlDiffAdded = { "GitSignsAdd", "GitGutterAdd", "DiffAdded", "DiffAdd" },
  StlDiffModified = { "GitSignsChange", "GitGutterChange", "DiffModified", "DiffChange" },
  StlDiffRemoved = { "GitSignsDelete", "GitGutterDelete", "DiffRemoved", "DiffDelete" },
  StlDiagError = { "DiagnosticError" },
  StlDiagWarn = { "DiagnosticWarn" },
  StlDiagInfo = { "DiagnosticInfo" },
  StlDiagHint = { "DiagnosticHint" },
}

-- Groups are defined the way lualine did: nocombine (so StatusLine's own
-- attributes, e.g. reverse in 256-color mode, don't leak in) and lualine's
-- own 256-color conversion.
local to_cterm = require("yeyito.lualine_cterm")
local function stl_hl(name, fg, bg, bold)
  api.nvim_set_hl(0, name, {
    fg = fg,
    bg = bg,
    bold = bold,
    nocombine = true,
    ctermfg = to_cterm(fg),
    ctermbg = to_cterm(bg),
    cterm = { bold = bold, nocombine = true },
  })
end

local function highlights()
  local c = colors.palette
  local mode_colors = { normal = c.cyan, insert = c.teal, visual = c.purple, replace = c.red, command = c.yellow }
  for kind, color in pairs(mode_colors) do
    stl_hl("StlMode_" .. kind, c.bg, color, true)
    stl_hl("StlSep_" .. kind, color, c.bg)
  end
  stl_hl("StlB", c.cyan, c.bg)
  stl_hl("StlC", c.fg, c.bg)
  stl_hl("StlInactive", c.gray, c.bg)
  for name, groups in pairs(fg_sources) do
    for _, group in ipairs(groups) do
      local fg = api.nvim_get_hl(0, { name = group, link = false }).fg
      if fg then
        stl_hl(name, string.format("#%06x", fg), c.bg)
        break
      end
    end
  end
end

-- Git branch and diff counts per buffer, refreshed on enter/write/focus.
local git = {} ---@type table<integer, { branch: string, diff: string }>

local function read_branch(root)
  local gitdir = root .. "/.git"
  if vim.fn.filereadable(gitdir) == 1 then -- worktree: "gitdir: <path>"
    local line = (vim.fn.readfile(gitdir, "", 1)[1] or ""):match("^gitdir: (.+)$")
    if not line then
      return ""
    end
    gitdir = line:sub(1, 1) == "/" and line or root .. "/" .. line
  end
  local head = vim.fn.readfile(gitdir .. "/HEAD", "", 1)[1]
  if not head then
    return ""
  end
  return head:match("^ref: refs/heads/(.+)$") or head:match("^ref: (.+)$") or head:sub(1, 7)
end

-- Count hunks like lualine: paired old/new lines are "modified".
local function parse_diff(out)
  local added, modified, removed = 0, 0, 0
  for line in out:gmatch("[^\n]+") do
    local old, new = line:match("^@@ %-%d+,?(%d*) %+%d+,?(%d*) @@")
    if old then
      old, new = tonumber(old) or 1, tonumber(new) or 1
      local both = math.min(old, new)
      modified = modified + both
      added = added + new - both
      removed = removed + old - both
    end
  end
  local parts = {}
  for _, p in ipairs({ { "StlDiffAdded", "+", added }, { "StlDiffModified", "~", modified }, { "StlDiffRemoved", "-", removed } }) do
    if p[3] > 0 then
      parts[#parts + 1] = "%#" .. p[1] .. "#" .. p[2] .. p[3]
    end
  end
  return #parts > 0 and " " .. table.concat(parts, " ") .. " " or ""
end

local function update_git(buf)
  local file = api.nvim_buf_get_name(buf)
  local root = file ~= "" and vim.bo[buf].buftype == "" and vim.fs.root(file, ".git")
  if not root then
    git[buf] = nil
    return
  end
  local entry = git[buf] or { diff = "" }
  entry.branch = read_branch(root)
  git[buf] = entry
  if vim.uv.fs_stat(file) then
    local cmd = { "git", "-C", vim.fs.dirname(file), "--no-pager", "diff", "--no-color", "--no-ext-diff", "-U0", "--", file }
    pcall(vim.system, cmd, { text = true }, function(res)
      entry.diff = res.code == 0 and parse_diff(res.stdout or "") or ""
      vim.schedule(function()
        vim.cmd.redrawstatus({ bang = true })
      end)
    end)
  end
end

local function diagnostics(buf)
  local count = vim.diagnostic.count(buf)
  local sev = vim.diagnostic.severity
  local parts = {}
  for _, d in ipairs({ { sev.ERROR, "StlDiagError", "E" }, { sev.WARN, "StlDiagWarn", "W" }, { sev.INFO, "StlDiagInfo", "I" }, { sev.HINT, "StlDiagHint", "H" } }) do
    if (count[d[1]] or 0) > 0 then
      parts[#parts + 1] = "%#" .. d[2] .. "#" .. d[3] .. count[d[1]]
    end
  end
  return #parts > 0 and " " .. table.concat(parts, " ") .. " " or ""
end

local function filename(buf)
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t")
  name = name == "" and "[No Name]" or name:gsub("%%", "%%%%")
  local symbols = ""
  if vim.bo[buf].modified then
    symbols = symbols .. "[+]"
  end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    symbols = symbols .. "[-]"
  end
  local path = api.nvim_buf_get_name(buf)
  if path ~= "" and vim.bo[buf].buftype == "" and not vim.uv.fs_stat(path) then
    symbols = symbols .. "[New]"
  end
  return symbols ~= "" and name .. " " .. symbols or name
end

local function progress(win, buf)
  local cur, total = api.nvim_win_get_cursor(win)[1], api.nvim_buf_line_count(buf)
  if cur == 1 then
    return "Top"
  elseif cur == total then
    return "Bot"
  end
  return string.format("%2d%%%%", math.floor(cur / total * 100))
end

function M.render()
  local win = vim.g.statusline_winid
  local buf = api.nvim_win_get_buf(win)
  if win ~= api.nvim_get_current_win() then
    return "%#StlInactive# " .. filename(buf) .. " %= %3l:%-2v "
  end

  local name = mode_names[api.nvim_get_mode().mode] or api.nvim_get_mode().mode
  local kind = mode_kinds[name] or "normal"
  local info = git[buf]
  local branch = info and info.branch ~= "" and (" \u{e0a0} " .. info.branch .. " ") or ""
  local diff = info and info.diff or ""
  local b = branch .. ((branch ~= "" and diff ~= "") and "│" or "")

  return table.concat({
    "%#StlMode_" .. kind .. "# " .. name .. " ",
    "%#StlSep_" .. kind .. "#│",
    "%#StlB#" .. b .. diff,
    "%#StlC# " .. filename(buf) .. " %=",
    diagnostics(buf),
    "%#StlB# " .. progress(win, buf) .. " ",
    "%#StlSep_" .. kind .. "#│",
    "%#StlMode_" .. kind .. "# %3l:%-2v ",
  })
end

function M.setup()
  highlights()
  vim.o.statusline = "%!v:lua.require'yeyito.statusline'.render()"

  local group = api.nvim_create_augroup("yeyito.statusline", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FocusGained" }, {
    group = group,
    callback = function(args)
      update_git(args.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      git[args.buf] = nil
    end,
  })
  api.nvim_create_autocmd({ "ModeChanged", "DiagnosticChanged" }, {
    group = group,
    callback = function()
      vim.cmd.redrawstatus()
    end,
  })
end

return M
