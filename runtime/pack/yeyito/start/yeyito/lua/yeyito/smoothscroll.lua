-- Smooth scrolling in st, the way the Exocortex TUI does it: st's
-- app-driven smooth scrolling (mode 2032, ~/Config/st
-- docs/app-smooth-scroll.md). When a window's view scrolls, its rows are drawn
-- where they were and glide into place over 100 ms, timed by st at the
-- display's refresh rate; inputs mid-glide add up.
--
-- Both sides now live in C: drawscreen.c (win_update / win_scroll_lines_glide)
-- marks view scrolls directly before emitting grid_scroll, and tui.c (glide_*)
-- turns mode 2032 on when st supports it and glides those scrolls. Doing the
-- marking in win_update instead of a WinScrolled autocmd avoids missed glides
-- in visual mode, incsearch, recursive redraws, and multi-frame flushes. The
-- file sidebar only glides with g:yeyito_sidebar_smooth_scroll (off by
-- default, options.lua).
local M = {}

function M.setup() end

return M
