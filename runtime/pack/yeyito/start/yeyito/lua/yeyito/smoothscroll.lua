-- Smooth scrolling in st, the way the Exocortex TUI does it: st's
-- app-driven smooth scrolling (mode 2032, ~/Config/st
-- docs/app-smooth-scroll.md). When a window's view scrolls, its rows are drawn
-- where they were and glide into place over 100 ms, timed by st at the
-- display's refresh rate; inputs mid-glide add up.
--
-- The TUI does the terminal side (src/nvim/tui/tui.c, glide_*): it turns
-- mode 2032 on when st supports it and glides the region scroll that draws
-- the move. This marks, just before the redraw, which windows' views moved,
-- so only scrolling glides: lines that move because of an edit (dd, o, a
-- paste) never do. Every way of scrolling glides (wheel, CTRL-E/Y/D/U/F/B,
-- j/k at the edge, zz/zt/zb, n/N and other jumps within a screen); jumps
-- further than a screen (gg, G) are drawn in place. The file sidebar only
-- glides with g:yeyito_sidebar_smooth_scroll (off by default, options.lua).
local M = {}

local api = vim.api

local function mark(win)
  if api.nvim_win_get_config(win).relative ~= "" then
    return -- floats are composited and never region-scrolled
  end
  if vim.bo[api.nvim_win_get_buf(win)].filetype == "yeyito-sidebar" and not vim.g.yeyito_sidebar_smooth_scroll then
    return -- the file sidebar jumps unless g:yeyito_sidebar_smooth_scroll (options.lua)
  end
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return
  end
  -- The text area in screen cells, bottom and right exclusive.
  local top = info.winrow - 1 + info.winbar
  local left = info.wincol - 1
  api.nvim_ui_send(("\27_nvim-glide;%d;%d;%d;%d\27\\"):format(top, top + info.height, left, left + info.width))
end

function M.setup()
  api.nvim_create_autocmd("WinScrolled", {
    group = api.nvim_create_augroup("yeyito.smoothscroll", { clear = true }),
    desc = "Mark scrolled windows so the TUI glides them",
    callback = function()
      for id, change in pairs(vim.v.event) do
        local win = tonumber(id) -- skips "all"
        if
          win
          and api.nvim_win_is_valid(win)
          and change.width == 0
          and change.height == 0
          and (change.topline ~= 0 or change.topfill ~= 0 or change.skipcol ~= 0 or change.leftcol ~= 0)
        then
          mark(win)
        end
      end
    end,
  })
end

return M
