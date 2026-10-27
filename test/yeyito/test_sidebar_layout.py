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
from test_smooth_scroll import NVIM, ROWS, COLS, Term, check, failures  # noqa: E402

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

        def layout():
            out = subprocess.run(
                [NVIM, "--clean", "--headless", "--server", sock, "--remote-expr",
                 "luaeval('vim.json.encode(dofile(\"%s\"))')" % layout_file],
                capture_output=True, text=True, timeout=10)
            return json.loads(out.stdout.strip() or "null")
        return t, layout

    t, layout = run()
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

    t, layout = run(["--cmd", "let g:yeyito_ui2 = v:false"])
    try:
        t.keys(b"\x13")
        l = layout()
        check("g:yeyito_ui2 = false: no ui2, the sidebar still opens",
              l["ui2"] is False and l["ft"] == "yeyito-sidebar" and l["foot"] is None, l)
    finally:
        t.close()

    print("%d failure(s)" % len(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
