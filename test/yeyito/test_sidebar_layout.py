"""The file sidebar runs the full height of the screen, with the command line
and messages (ui2) beside it: the real TUI on a fake st (test_smooth_scroll's
Term), window positions read over --listen.

    python3 test/yeyito/test_sidebar_layout.py [build/bin/nvim]
"""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_smooth_scroll import NVIM, ROWS, COLS, Term, check, failures, frames  # noqa: E402

LAYOUT = r'''
local ui = package.loaded["vim._core.ui2"]
local function pos(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return vim.NIL end
  local c = vim.api.nvim_win_get_config(win)
  local p = vim.api.nvim_win_get_position(win)
  return { row = p[1], col = p[2], width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win), hide = c.hide or false }
end
local foot = vim.NIL
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local c = vim.api.nvim_win_get_config(w)
  if c.relative ~= "" and c.zindex == 200 and c.focusable == false and not c.hide
    and vim.api.nvim_win_get_width(w) == 28 then
    foot = pos(w)
  end
end
return {
  ui2 = ui ~= nil and ui.msg ~= nil,
  col = ui and ui.col or vim.NIL,
  cmd = ui and pos(ui.wins.cmd) or vim.NIL,
  pager = ui and pos(ui.wins.pager) or vim.NIL,
  foot = foot,
  cur = pos(vim.api.nvim_get_current_win()),
  ft = vim.bo.filetype,
}
'''


def main():
    tmp = tempfile.mkdtemp(prefix="nvim-sidebar-layout-")
    project = os.path.join(tmp, "project")
    os.makedirs(os.path.join(project, "src"))
    for f in ("src/main.c", "README.md"):
        open(os.path.join(project, f), "w").write("x\n")
    layout_file = os.path.join(tmp, "layout.lua")
    open(layout_file, "w").write(LAYOUT)

    def run(extra=()):
        sock = os.path.join(tmp, "nvim-%d.sock" % len(os.listdir(tmp)))
        t = Term(["src/main.c"], cwd=project, args=["--listen", sock] + list(extra))
        t.read(1.0)

        def expr(e):
            out = subprocess.run([NVIM, "--clean", "--headless", "--server", sock, "--remote-expr", e],
                                 capture_output=True, text=True, timeout=10)
            return json.loads(out.stdout.strip() or "null")

        def layout():
            return expr("luaeval('vim.json.encode(dofile(\"%s\"))')" % layout_file)
        return t, layout, expr

    t, layout, expr = run()
    try:
        l = layout()
        check("ui2 is on", l["ui2"] is True, l)
        check("without the sidebar the command line has the full width",
              l["col"] == 0 and l["cmd"]["col"] == 0 and l["cmd"]["width"] == COLS, l)

        t.keys(b"\x13")  # CTRL-S
        l = layout()
        check("sidebar open", l["ft"] == "yeyito-sidebar", l)
        check("the command line starts right of the sidebar",
              l["col"] == 28 and l["cmd"]["col"] == 28 and l["cmd"]["width"] == COLS - 28, l)
        f = l["foot"]
        check("the sidebar runs to the bottom of the screen",
              f is not None and f["col"] == 0 and f["row"] + f["height"] == ROWS and f["row"] == ROWS - 2, f)

        t.keys(b"/")
        c = layout()["cur"]
        check("/ opens the sidebar's bar in its bottom row",
              c["row"] == ROWS - 1 and c["col"] == 0 and c["width"] == 27, c)
        t.keys(b"m")
        # Row 2 (under the header) is "  src/main.c", its "m" in column 7; the
        # selection moved on to README.md (the selected row shows no matches:
        # its CursorLine has a foreground).
        attrs = expr("json_encode([screenstring(2, 7), screenattr(2, 3), screenattr(2, 7), screenattr(2, 8)])")
        check("matches are highlighted where they are drawn",
              attrs is not None and attrs[0] == "m" and attrs[2] != attrs[1] and attrs[3] == attrs[1], attrs)
        t.keys(b"\x1b")

        t.keys(b"\t:echomsg 'one' | echomsg 'two' | echomsg 'three'\r")
        t.keys(b":messages\r", idle=0.6)
        p = layout()["pager"]
        check("the pager opens beside the sidebar",
              p is not None and not p["hide"] and p["col"] == 28 and p["width"] == COLS - 28, p)
        t.keys(b"q")

        t.keys(b"\x13")  # CTRL-S from the editor while it is open: close
        l = layout()
        check("closing it gives the command line the full width again",
              l["ft"] != "yeyito-sidebar" and l["col"] == 0 and l["cmd"]["col"] == 0
              and l["cmd"]["width"] == COLS and l["foot"] is None, l)

        t.keys(b":set cmdheight=2\r")
        t.keys(b"\x13")
        f = layout()["foot"]
        check("with cmdheight=2 the sidebar still reaches the bottom",
              f is not None and f["row"] + f["height"] == ROWS and f["height"] == 3, f)
        check("the marker never reaches the terminal", b"nvim-glide" not in t.log)
    finally:
        t.close()

    t, layout, _ = run(["--cmd", "let g:yeyito_ui2 = v:false"])
    try:
        t.keys(b"\x13")
        l = layout()
        check("g:yeyito_ui2 = false: no ui2, the sidebar still opens",
              l["ui2"] is False and l["ft"] == "yeyito-sidebar" and l["foot"] is None, l)
    finally:
        t.close()

    # st sends CSI 111;6u for Ctrl+Shift+O: a new file at the top of the
    # project, wherever the sidebar's cursor is; Ctrl+P, in the cursor's folder.
    t, layout, expr = run()
    try:
        t.keys(b"\x13")  # CTRL-S: the sidebar, on src/main.c
        t.keys(b"\t")    # back to the editor
        t.keys(b"\x10")  # CTRL-P
        t.keys(b"in_src.txt\r")
        check("Ctrl+P: a new file in the sidebar cursor's folder",
              os.path.exists(os.path.join(project, "src", "in_src.txt")) and expr("json_encode(expand('%:.'))") == "src/in_src.txt")
        t.keys(b"\x1b[111;6u")
        t.keys(b"at_top.txt\r")
        check("Ctrl+Shift+O (st's CSI 111;6u): at the top of the project",
              os.path.exists(os.path.join(project, "at_top.txt")) and expr("json_encode(expand('%:.'))") == "at_top.txt")
    finally:
        t.close()

    # The AI's request box takes st's keys: Shift+Enter (CSI 13;2u) is a new
    # line, Esc goes to normal mode.
    t, layout, expr = run()
    try:
        t.keys(b" a")  # <leader>a
        t.keys(b"one\x1b[13;2utwo")
        lines = expr("json_encode(getline(1, '$'))")
        t.keys(b"\x1b")
        mode = expr("json_encode(mode())")
        check("AI box: Shift+Enter from st adds a line; Esc is normal mode",
              lines == ["one", "two"] and mode == "n", (lines, mode))
        t.keys(b"\x1b")
    finally:
        t.close()

    # The AI's request box changes layout in the same screen update as the text:
    # one frame per key (no ruler: ui2 draws it in a frame of its own), and the
    # text never scrolls out of view, not even when a row fills up exactly and
    # the cursor is alone on the next one.
    t, layout, expr = run(["-c", "set noruler"])
    try:
        t.keys(b" a")
        width = expr("json_encode(winwidth(0))")

        def press(key):
            out = t.keys(key, idle=0.2)
            view = expr("json_encode([winheight(0), winline(), winsaveview().skipcol])")
            return out, frames(out), view
        out, drawn, view = press(b"x")
        check("AI box: the first letter replaces the placeholder in one frame",
              len(drawn) == 1 and b"what to do" not in out and view == [1, 1, 0], (drawn, view))
        t.keys(b"x" * (width - 3), idle=0.3)
        for typed, want in ((width - 1, [1, 1, 0]), (width, [2, 2, 0]), (width + 1, [2, 2, 0])):
            _, drawn, view = press(b"x")
            check("AI box: char %d of a %d-wide row: one frame, no scrolling" % (typed, width),
                  len(drawn) == 1 and view == want, (drawn, view))
        for left, want in ((width, [2, 2, 0]), (width - 1, [1, 1, 0])):
            _, drawn, view = press(b"\x7f")
            check("AI box: Backspace to %d chars: one frame" % left, len(drawn) == 1 and view == want, (drawn, view))
        _, drawn, view = press(b"\x1b[13;2u")
        check("AI box: Shift+Enter grows it in one frame", len(drawn) == 1 and view == [2, 2, 0], (drawn, view))
        t.keys(b"\x1b")
        out = t.keys(b"dd", idle=0.2)
        blank_row = [f for f in frames(out) if b"\x1b[69X" in f or b"\x1b[%dX" % (width - 1) in f]
        check("AI box: dd shrinks it without a frame of a blank row",
              expr("json_encode(winheight(0))") == 1 and blank_row == [], frames(out))
        t.keys(b"\x1b")
        t.keys(b"\x13")
        t.keys(b"/")
        t.keys(b"m", idle=0.5)  # the first search builds the index
        drawn = frames(t.keys(b"a", idle=0.2))
        check("sidebar search: the letter and the list it filters in one frame", len(drawn) == 1, drawn)
        t.keys(b"\x1b")
    finally:
        t.close()

    # st's Esc and the AI's reply card: it stays up until Esc in normal mode.
    t, layout, expr = run()
    try:
        expr("json_encode(luaeval('require(\"yeyito.ai\")._show(\"done\", \"a reply\")'))")

        def card():
            return expr("json_encode(luaeval('(function() local w = require(\"yeyito.ai\")._card.win;"
                        " return w ~= nil and vim.api.nvim_win_is_valid(w) end)()'))")
        t.keys(b"i")
        t.keys(b"\x1b", idle=0.3)
        check("reply card: stays when Esc leaves insert mode", card() is True)
        t.keys(b"\x1b", idle=0.3)
        check("reply card: Esc in normal mode puts it away", card() is False)
    finally:
        t.close()

    print("%d failure(s)" % len(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
