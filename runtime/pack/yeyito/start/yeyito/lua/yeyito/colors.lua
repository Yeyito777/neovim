-- Terminal color-level detection, a set_hl() that adds 256/16-color
-- fallbacks for terminals without truecolor, and the editor's own colors.
local M = {}

local function normalize_color_override(value)
  value = (value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if value == "3" or value == "truecolor" or value == "24bit" or value == "24-bit" or value == "rgb" then
    return "truecolor"
  end
  if value == "2" or value == "256" or value == "256color" or value == "8bit" or value == "8-bit" then
    return "256"
  end
  if value == "1" or value == "16" or value == "ansi" or value == "basic" then
    return "16"
  end
  return nil
end

local function detect_terminal_color_level()
  local explicit = normalize_color_override(vim.env.NVIM_TUI_COLOR) or normalize_color_override(vim.env.EXOCORTEX_TUI_COLOR)
  if explicit then return explicit end

  if vim.env.NO_COLOR then return "16" end

  local forced = normalize_color_override(vim.env.FORCE_COLOR)
  if forced then return forced end

  local term = (vim.env.TERM or ""):lower()
  local colorterm = (vim.env.COLORTERM or ""):lower()
  local term_program = (vim.env.TERM_PROGRAM or ""):lower()

  if colorterm:find("truecolor", 1, true) or colorterm:find("24bit", 1, true) then
    return "truecolor"
  end
  if term:find("direct", 1, true) or term:find("truecolor", 1, true) or term:find("24bit", 1, true) then
    return "truecolor"
  end

  -- Be conservative: generic xterm-256color is not a truecolor signal. This is
  -- what macOS Terminal.app commonly reports over SSH. Known truecolor terminals
  -- get truecolor even when their TERM name does not use the newer *-direct form.
  if term == "xterm-kitty" or term == "wezterm" or term == "foot" or term == "foot-extra"
      or term == "alacritty" or term == "rio" or term == "ghostty" or term == "st" or term:match("^st%-") then
    return "truecolor"
  end

  -- TERM_PROGRAM is usually absent over SSH unless explicitly forwarded, but use
  -- it when present. Apple Terminal stays on the 256-color path unless one of the
  -- stronger truecolor signals above was set.
  if term_program == "wezterm" or term_program == "ghostty" or term_program == "kitty" or term_program == "iterm.app" then
    return "truecolor"
  end
  if term_program == "apple_terminal" then
    return "256"
  end

  if term:find("256color", 1, true) or term:find("256", 1, true) then
    return "256"
  end
  return "16"
end

local color_level = detect_terminal_color_level()
M.level = color_level

-- Neovim's OSC 52 clipboard auto-detection can send an XTGETTCAP query for
-- the `Ms` capability: ESC P + q 4D73 ESC \.  Apple Terminal.app and some SSH
-- paths echo unsupported DCS queries as visible text, which shows up as
-- "+q4D73" where the cursor is.  Over SSH, TERM_PROGRAM is often absent, so
-- treat plain xterm-256color with no COLORTERM as Apple-Terminal-ish and skip
-- the probe.  Set NVIM_OSC52=1 if you explicitly want to try OSC 52 anyway.
local current_term = (vim.env.TERM or ""):lower()
local current_colorterm = (vim.env.COLORTERM or ""):lower()
local current_term_program = (vim.env.TERM_PROGRAM or ""):lower()
if vim.env.NVIM_OSC52 ~= "1"
    and (current_term_program == "apple_terminal"
      or (current_term == "xterm-256color" and current_colorterm == "" and current_term_program == "")) then
  local termfeatures = vim.g.termfeatures or {}
  termfeatures.osc52 = false
  vim.g.termfeatures = termfeatures
end

local xterm_256_levels = { 0, 95, 135, 175, 215, 255 }
local ansi_16_rgb = {
  { 0, 0, 0 },       -- black
  { 205, 0, 0 },     -- red
  { 0, 205, 0 },     -- green
  { 205, 205, 0 },   -- yellow
  { 0, 0, 238 },     -- blue
  { 205, 0, 205 },   -- magenta
  { 0, 205, 205 },   -- cyan
  { 229, 229, 229 }, -- white
  { 127, 127, 127 }, -- bright black / gray
  { 255, 0, 0 },
  { 0, 255, 0 },
  { 255, 255, 0 },
  { 92, 92, 255 },
  { 255, 0, 255 },
  { 0, 255, 255 },
  { 255, 255, 255 },
}

local function clamp_byte(value)
  value = tonumber(value) or 0
  return math.max(0, math.min(255, math.floor(value + 0.5)))
end

local function color_distance_sq(r1, g1, b1, r2, g2, b2)
  return (r1 - r2) ^ 2 + (g1 - g2) ^ 2 + (b1 - b2) ^ 2
end

local function nearest_index(levels, value)
  local best = 1
  local best_dist = math.huge
  for i, level in ipairs(levels) do
    local dist = math.abs(value - level)
    if dist < best_dist then
      best = i
      best_dist = dist
    end
  end
  return best
end

local function hex_to_rgb(hex)
  if type(hex) ~= "string" then return nil end
  local h = hex:gsub("^#", "")
  if #h == 3 then
    h = h:sub(1, 1) .. h:sub(1, 1) .. h:sub(2, 2) .. h:sub(2, 2) .. h:sub(3, 3) .. h:sub(3, 3)
  end
  if not h:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
    return nil
  end
  return tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
end

local function rgb_to_xterm256(r, g, b)
  r, g, b = clamp_byte(r), clamp_byte(g), clamp_byte(b)
  local ri = nearest_index(xterm_256_levels, r)
  local gi = nearest_index(xterm_256_levels, g)
  local bi = nearest_index(xterm_256_levels, b)

  local cube_code = 16 + (36 * (ri - 1)) + (6 * (gi - 1)) + (bi - 1)
  local cube_r, cube_g, cube_b = xterm_256_levels[ri], xterm_256_levels[gi], xterm_256_levels[bi]
  local cube_dist = color_distance_sq(r, g, b, cube_r, cube_g, cube_b)

  local chroma = math.max(r, g, b) - math.min(r, g, b)
  if chroma > 12 then return cube_code end

  local avg = (r + g + b) / 3
  local gray_index
  if avg <= 8 then
    gray_index = 0
  elseif avg >= 248 then
    gray_index = 23
  else
    gray_index = math.max(0, math.min(23, math.floor(((avg - 8) / 10) + 0.5)))
  end
  local gray_value = 8 + (gray_index * 10)
  local gray_code = 232 + gray_index
  local gray_dist = color_distance_sq(r, g, b, gray_value, gray_value, gray_value)

  if gray_dist < cube_dist then return gray_code end
  return cube_code
end

local function rgb_to_ansi16(r, g, b)
  r, g, b = clamp_byte(r), clamp_byte(g), clamp_byte(b)
  local best = 0
  local best_dist = math.huge
  for i, rgb in ipairs(ansi_16_rgb) do
    local dist = color_distance_sq(r, g, b, rgb[1], rgb[2], rgb[3])
    if dist < best_dist then
      best = i - 1
      best_dist = dist
    end
  end
  return best
end

local function color_to_cterm(color)
  if type(color) == "number" then return color end
  if type(color) ~= "string" or color:lower() == "none" then return nil end
  local r, g, b = hex_to_rgb(color)
  if not r then return nil end
  if color_level == "16" then
    return rgb_to_ansi16(r, g, b)
  end
  return rgb_to_xterm256(r, g, b)
end

function M.set_hl(ns, name, opts)
  if color_level ~= "truecolor" then
    opts = vim.tbl_extend("force", {}, opts)
    if opts.fg ~= nil and opts.ctermfg == nil then
      opts.ctermfg = color_to_cterm(opts.fg)
    end
    if opts.bg ~= nil and opts.ctermbg == nil then
      opts.ctermbg = color_to_cterm(opts.bg)
    end
  end
  vim.api.nvim_set_hl(ns, name, opts)
end

local set_hl = M.set_hl

-- The palette, shared by the statusline and other UI pieces.
M.palette = {
  bg = "#00050f",
  fg = "#f1faee",
  cyan = "#48cae4",
  teal = "#2ec4b6",
  blue = "#5fa8d3",
  purple = "#c77dff",
  yellow = "#ffe066",
  gold = "#ffd166",
  red = "#ff6b6b",
  gray = "#457b9d",
  cursorline = "#090d35",
}

function M.setup()
  vim.g.nvim_color_level = color_level
  vim.opt.termguicolors = color_level == "truecolor"

  local c = M.palette
  -- Completion menu colors
  set_hl(0, "Pmenu", { bg = "#001f3f", fg = c.fg }) -- popup background
  set_hl(0, "PmenuSel", { bg = "#00509e", fg = "#ffffff", bold = true }) -- selected item
  set_hl(0, "PmenuSbar", { bg = "#001f3f" }) -- scrollbar
  set_hl(0, "PmenuThumb", { bg = "#00509e" }) -- scrollbar thumb
  -- Casual stuff
  set_hl(0, "Normal", { fg = c.fg, bg = c.bg })
  set_hl(0, "Cursor", { fg = c.bg, bg = c.cyan })
  set_hl(0, "Comment", { fg = c.gray, italic = true })
  set_hl(0, "Statement", { fg = c.red })
  set_hl(0, "Identifier", { fg = c.teal })
  set_hl(0, "Constant", { fg = c.gold })
  set_hl(0, "Type", { fg = c.cyan })
  set_hl(0, "Special", { fg = c.purple })
  set_hl(0, "Directory", { fg = c.blue })
  set_hl(0, "Search", { fg = c.bg, bg = c.yellow })
  -- Hide the separator shown above the hit-enter/message prompt (e.g. E37/E162 warnings).
  -- Neovim 0.9+ always reserves this row for scrolled messages, so make it blend in.
  set_hl(0, "MsgSeparator", { fg = c.bg, bg = c.bg })
  set_hl(0, "LineNr", { fg = c.gray, bg = c.bg })
  set_hl(0, "CursorLineNr", { fg = c.cyan, bg = c.bg, bold = true })
  set_hl(0, "CursorLine", { bg = c.cursorline })
end

return M
