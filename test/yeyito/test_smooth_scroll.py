"""Smooth scrolling (st mode 2032): the real TUI against a fake st on a PTY.

The fake terminal answers DECRQM like st (2026 and 2032 supported) and the
test checks the bytes of each frame: a view scroll is a region scroll plus
`OSC 2032 ; m` in the same synchronized update, edits never glide, and the
server's glide marker never reaches the terminal.

    python3 test/yeyito/test_smooth_scroll.py [build/bin/nvim]
"""
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import fcntl
import json
import random
import time
import unicodedata

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
NVIM = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "bin", "nvim"))
ROWS, COLS = 30, 100
WIN_H = ROWS - 2  # statusline + cmdline

GLIDE = re.compile(rb"\x1b\]2032;m;0;(-?\d+);100\x1b\\")
RECT = re.compile(rb"\x1b\]2032;r;(\d+),(\d+),(\d+),(\d+)\x1b\\")
SNAP = b"\x1b]2032;o;0\x1b\\"


class Term:
    def __init__(self, files, smooth=True, term="st-256color", cmds=(), cwd=None, args=()):
        self.smooth = smooth
        self.tmp = tempfile.mkdtemp(prefix="nvim-smooth-")
        env = dict(os.environ)
        for key in ("NVIM_TEST", "NVIM", "TMUX", "COLORTERM", "TERM_PROGRAM"):
            env.pop(key, None)
        env.update(
            TERM=term,
            NVIM_NOTTYFAST="1",
            VIMRUNTIME=os.path.join(ROOT, "runtime"),
            XDG_CONFIG_HOME=os.path.join(self.tmp, "config"),
            XDG_STATE_HOME=os.path.join(self.tmp, "state"),
            XDG_DATA_HOME=os.path.join(self.tmp, "data"),
            TMPDIR=self.tmp,
        )
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        argv = [NVIM, "-n", "-i", "NONE"] + list(args)
        for cmd in cmds:
            argv += ["-c", cmd]
        self.proc = subprocess.Popen(argv + list(files), stdin=slave, stdout=slave,
                                     stderr=slave, env=env, cwd=cwd or self.tmp, start_new_session=True)
        os.close(slave)
        self.fd = master
        self.log = bytearray()

    def answer(self, data):
        for mode in re.findall(rb"\x1b\[\?(\d+)\$p", data):
            state = 2 if mode == b"2026" or (mode == b"2032" and self.smooth) else 0
            os.write(self.fd, b"\x1b[?%s;%d$y" % (mode, state))
        if b"\x1b[c" in data:
            os.write(self.fd, b"\x1b[?62;22c")
        if b"\x1b[5n" in data:
            os.write(self.fd, b"\x1b[0n")

    def read(self, idle=0.4, limit=5.0):
        """Output until the TUI has been quiet for `idle` seconds."""
        out = bytearray()
        start = last = time.monotonic()
        while time.monotonic() - last < idle and time.monotonic() - start < limit:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.answer(chunk)
                out += chunk
                last = time.monotonic()
        self.log += out
        return bytes(out)

    def keys(self, data, idle=0.4):
        os.write(self.fd, data)
        return self.read(idle)

    def close(self):
        try:
            os.write(self.fd, b"\x1b:qa!\r")
            self.read(0.3, 3)
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, 9)
            self.proc.wait()
        os.close(self.fd)


def frames(out):
    return re.findall(rb"\x1b\[\?2026h(.*?)\x1b\[\?2026l", out, re.S)


def glides(out):
    return [int(m) for m in GLIDE.findall(out)]


class Screen:
    """What a terminal shows after these bytes, for the sequences the TUI sends
    (characters only): to compare with what Neovim thinks is on screen."""

    def __init__(self, rows=ROWS, cols=COLS):
        self.rows, self.cols = rows, cols
        self.cells = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.top, self.bot = 0, rows - 1
        self.wrap_pending = False
        self.moving = []  # the last OSC 2032 ; r, as (top, left, bot, right), 0-based
        self.tail = b""

    def _scroll(self, top, bot, n):
        """Rows top..bot, n > 0: content up."""
        height = bot - top + 1
        n = max(-height, min(height, n))
        band = self.cells[top:bot + 1]
        blank = [[" "] * self.cols for _ in range(abs(n))]
        self.cells[top:bot + 1] = band[n:] + blank if n >= 0 else blank + band[:n]

    def _put(self, ch):
        width = 2 if unicodedata.east_asian_width(ch) in "WF" else 1
        if unicodedata.combining(ch):
            return
        if self.wrap_pending or self.c + width > self.cols:
            self.c, self.wrap_pending = 0, False
            if self.r == self.bot:
                self._scroll(self.top, self.bot, 1)
            else:
                self.r = min(self.r + 1, self.rows - 1)
        row = self.cells[self.r]
        # Overwriting half of a double-width character blanks the other half.
        if row[self.c] == "" and self.c > 0:
            row[self.c - 1] = " "
        if self.c + width < self.cols and row[self.c + width] == "":
            row[self.c + width] = " "
        row[self.c] = ch
        if width == 2:
            row[self.c + 1] = ""
        self.c += width
        if self.c >= self.cols:
            self.c, self.wrap_pending = self.cols - 1, True

    def _csi(self, params, final):
        args = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else []
        arg = lambda i, default: args[i] if len(args) > i and args[i] else default
        n = arg(0, 1)
        if final not in "mhlqnct":
            self.wrap_pending = False
        if final in "Hf":
            self.r, self.c = min(arg(0, 1) - 1, self.rows - 1), min(arg(1, 1) - 1, self.cols - 1)
        elif final == "A":
            self.r = max(self.r - n, 0)
        elif final == "B":
            self.r = min(self.r + n, self.rows - 1)
        elif final == "C":
            self.c = min(self.c + n, self.cols - 1)
        elif final == "D":
            self.c = max(self.c - n, 0)
        elif final == "G":
            self.c = min(n - 1, self.cols - 1)
        elif final == "d":
            self.r = min(n - 1, self.rows - 1)
        elif final == "r":
            self.top, self.bot = arg(0, 1) - 1, arg(1, self.rows) - 1
            self.r = self.c = 0
        elif final == "M" and self.top <= self.r <= self.bot:
            self._scroll(self.r, self.bot, n)
        elif final == "L" and self.top <= self.r <= self.bot:
            self._scroll(self.r, self.bot, -n)
        elif final == "S":
            self._scroll(self.top, self.bot, n)
        elif final == "T":
            self._scroll(self.top, self.bot, -n)
        elif final == "X":
            for c in range(self.c, min(self.c + n, self.cols)):
                self.cells[self.r][c] = " "
        elif final == "K":
            mode = arg(0, 0)
            cols = range(self.c, self.cols) if mode == 0 else range(self.c + 1) if mode == 1 else range(self.cols)
            for c in cols:
                self.cells[self.r][c] = " "
        elif final == "J":
            mode = arg(0, 0)
            rows = range(self.rows) if mode >= 2 else range(self.r, self.rows) if mode == 0 else range(self.r + 1)
            for r in rows:
                if mode >= 2 or (mode == 0 and r > self.r) or (mode == 1 and r < self.r):
                    self.cells[r] = [" "] * self.cols
            if mode == 0:
                self._csi("", "K")

    def feed(self, data):
        data = self.tail + data
        self.tail = b""
        i, n = 0, len(data)
        while i < n:
            b = data[i]
            if b == 0x1b:
                m = re.compile(rb"\x1b\[([?>=!]?)([0-9;:]*)([ $\"'#]?)([@-~])").match(data, i)
                if m:
                    if not m.group(1) and not m.group(3):
                        self._csi(m.group(2).decode(), m.group(4).decode())
                    i = m.end()
                    continue
                m = re.compile(rb"\x1b[\]_P^](.*?)(?:\x1b\\|\x07)", re.S).match(data, i)
                if m:
                    osc = RECT_LIST.match(m.group(0))
                    if osc:
                        self.moving = [tuple(int(v) - 1 for v in r.split(b",")) for r in osc.group(1).split(b";")]
                    i = m.end()
                    continue
                if i + 1 < n and data[i + 1:i + 2] in (b"(", b")"):
                    i += 3
                    continue
                if n - i < 512 and not re.compile(rb"\x1b[=>78cDEHMZ]").match(data, i):
                    self.tail = data[i:]  # cut off mid-sequence
                    return
                i += 2
            elif b == 0x0d:
                self.c, self.wrap_pending = 0, False
                i += 1
            elif b == 0x0a:
                self.wrap_pending = False
                if self.r == self.bot:
                    self._scroll(self.top, self.bot, 1)
                else:
                    self.r = min(self.r + 1, self.rows - 1)
                i += 1
            elif b == 0x08:
                self.c, self.wrap_pending = max(self.c - 1, 0), False
                i += 1
            elif b < 0x20:
                i += 1
            else:
                size = 1 if b < 0x80 else 2 if b < 0xe0 else 3 if b < 0xf0 else 4
                if i + size > n:
                    self.tail = data[i:]
                    return
                self._put(data[i:i + size].decode("utf-8", "replace"))
                i += size


RECT_LIST = re.compile(rb"\x1b\]2032;r;([0-9,;]+)(?:\x1b\\|\x07)")

failures = []


def check(name, ok, detail=""):
    if detail and not isinstance(detail, str):
        detail = repr(detail)
    print(("ok   " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    if not ok:
        failures.append(name)


def sample(lines=300):
    path = os.path.join(tempfile.mkdtemp(prefix="nvim-smooth-file-"), "sample.txt")
    with open(path, "w") as f:
        f.write("".join("line %d %s\n" % (i, "x" * (i % 40)) for i in range(1, lines + 1)))
    return path


FLOAT_LUA = r"""
local M = {}
function M.open(row, col, width, height, opts)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, height do lines[i] = ("float %d "):format(i):rep(20) end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local blend = opts and opts.blend
  local cfg = vim.tbl_extend("force", { relative = "editor", row = row, col = col, width = width, height = height,
    style = "minimal", focusable = false, noautocmd = true }, opts or {})
  cfg.blend = nil
  local win = vim.api.nvim_open_win(b, false, cfg)
  vim.wo[win].wrap = false
  if blend then vim.wo[win].winblend = blend end
  return win
end
function M.closeall()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" and c.focusable == false and c.zindex == 50 then vim.api.nvim_win_close(w, true) end
  end
end
_G.FL = M
return 1
"""


def floats():
    """A float over the window, like the AI's reply card (the Exocortex TUI's
    Tasks panel): the text scrolls and glides around it. What a terminal would
    show (Screen) is compared with what Neovim thinks is on screen after every
    key, for text wider than the float's edge is kind to."""
    tmp = tempfile.mkdtemp(prefix="nvim-smooth-floats-")
    path = os.path.join(tmp, "text.txt")
    with open(path, "w") as f:
        for i in range(1, 400):
            if i % 3 == 0:  # double-width characters across the float's edges, both ways
                f.write("%s%d %s\n" % (" " * (i % 2), i, "日本語" * 18))
            elif i % 7 == 0:
                f.write("\n")
            else:
                f.write("%d %s\n" % (i, "word " * 22))
    lua = os.path.join(tmp, "float.lua")
    open(lua, "w").write(FLOAT_LUA)

    def session(smooth, name, options="noruler"):
        sock = os.path.join(tmp, "%s.sock" % name)
        t = Term([path], smooth=smooth, cwd=tmp, args=["--listen", sock, "-c", "set " + options])
        t.read(1.0)
        screen = Screen()
        fed = [0]

        def expr(e):
            out = subprocess.run([NVIM, "--clean", "--headless", "--server", sock, "--remote-expr", e],
                                 capture_output=True, text=True, timeout=10)
            return json.loads(out.stdout.strip() or "null")

        def lua_do(code):
            with open(lua + ".do", "w") as f:
                f.write(code)
            return expr("json_encode(luaeval('dofile(\"%s\")'))" % (lua + ".do"))

        def sync():
            screen.feed(bytes(t.log[fed[0]:]))
            fed[0] = len(t.log)

        def differences():
            sync()
            want = expr("json_encode(map(range(1, %d), {_, r -> map(range(1, %d), {_, c -> screenstring(r, c)})}))" % (ROWS, COLS))
            for row in want:
                # A double-width character a float's edge cuts in two shows as a
                # blank; screenstring() reports what's in the grid under it.
                for c in range(COLS):
                    wide = unicodedata.east_asian_width(row[c] or " ") in "WF"
                    if wide and (c + 1 == COLS or row[c + 1] != ""):
                        row[c] = " "
                    elif row[c] == "" and (c == 0 or unicodedata.east_asian_width(row[c - 1] or " ") not in "WF"):
                        row[c] = " "
            bad = [(r, c, screen.cells[r][c], want[r][c]) for r in range(ROWS) for c in range(COLS)
                   if screen.cells[r][c] != want[r][c]]
            return bad, want

        def same_screen():
            """Neovim's screen and the terminal's, cell by cell."""
            bad, want = differences()
            if bad:  # something may still have been on its way
                t.read(0.3)
                bad, want = differences()
            return bad[:6]

        return t, expr, lua_do, sync, same_screen, screen

    def overlaps(rect, cover):
        top, left, bot, right = rect
        c_top, c_bot, c_left, c_right = cover  # bot and right exclusive
        return top < c_bot and bot >= c_top and left < c_right and right >= c_left

    t, expr, lua_do, sync, same_screen, screen = session(True, "card", "noruler nowrap")
    try:
        lua_do(FLOAT_LUA)
        check("floats: the terminal model agrees with Neovim before anything", same_screen() == [], same_screen())

        # The AI's reply card, top right.
        lua_do("require('yeyito.ai')._show('done', 'A reply that takes a line or two to say what it did.'); return 1")
        t.read(0.3)
        card = expr("json_encode(luaeval('(function() local w = require(\"yeyito.ai\")._card.win;"
                    " return { vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w) } end)()'))")
        card_rows, card_left = card[1] + 2, COLS - card[0] - 2
        cover = (0, card_rows, card_left, COLS)
        out = t.keys(b"\x05", idle=0.15)
        check("card: CTRL-E glides", glides(out) == [1000], repr(out[-300:]))
        rects = RECT_LIST.search(out)
        check("card: the columns beside it for the full height, its own below it", rects is not None and rects.group(1) == b"1,1,%d,%d;%d,%d,%d,%d" % (
            WIN_H, card_left, card_rows + 1, card_left + 1, WIN_H, COLS), rects and rects.group(1))
        scrolled = [f for f in frames(out) if b"\x1b[M" in f]
        check("card: the scroll, the glide and the card are one frame", len(scrolled) == 1
              and GLIDE.search(scrolled[0]) is not None and "┌".encode() in scrolled[0], [len(f) for f in frames(out)])
        check("card: not a repaint of the text", out.count(b"word") < 30, out.count(b"word"))
        check("card: drawn back in that frame, same screen", same_screen() == [], same_screen())
        out = t.keys(b"\x19", idle=0.15)
        check("card: CTRL-Y glides back", glides(out) == [-1000], repr(out[-200:]))
        check("card: rectangles sent once", RECT_LIST.search(out) is None, repr(out[-200:]))
        out = t.keys(b"\x04", idle=0.15)
        check("card: CTRL-D glides half a window", glides(out) == [WIN_H // 2 * 1000], repr(out[-200:]))
        check("card: same screen after CTRL-D", same_screen() == [], same_screen())
        out = t.keys(b"\x15", idle=0.15)
        check("card: CTRL-U glides back", glides(out) == [-(WIN_H // 2) * 1000], repr(out[-200:]))
        check("card: the marker never reaches the terminal", b"nvim-glide" not in t.log)
        t.keys(b"\x1b", idle=0.2)
        out = t.keys(b"\x05", idle=0.15)
        rects = RECT_LIST.search(out)
        check("card gone: the whole window moves again", glides(out) == [1000] and rects is not None
              and rects.group(1) == b"1,1,%d,%d" % (WIN_H, COLS), rects and rects.group(1))
        check("card gone: same screen", same_screen() == [], same_screen())

        # Any float, anywhere: in the middle it's four rectangles.
        lua_do("FL.open(8, 30, 30, 6); return 1")
        t.read(0.2)
        out = t.keys(b"\x05", idle=0.15)
        rects = RECT_LIST.search(out)
        want = b"1,1,%d,30;1,61,%d,%d;1,31,8,60;15,31,%d,60" % (WIN_H, WIN_H, COLS, WIN_H)
        check("float in the middle: goes around it", glides(out) == [1000] and rects and rects.group(1) == want,
              rects and rects.group(1))
        check("float in the middle: same screen", same_screen() == [], same_screen())
        lua_do("FL.open(10, 50, 30, 6, { border = 'single' }); return 1")  # over the first one
        t.read(0.2)
        out = t.keys(b"\x05", idle=0.15)
        sync()
        check("two floats overlapping: still glides, nothing moves under them", glides(out) == [1000] and screen.moving
              and not any(overlaps(r, (8, 14, 30, 60)) or overlaps(r, (10, 18, 50, 82)) for r in screen.moving),
              (glides(out), screen.moving))
        check("two floats overlapping: same screen", same_screen() == [], same_screen())
        lua_do("FL.closeall(); return 1")
        t.read(0.2)
        check("floats closed: same screen", same_screen() == [], same_screen())

        # Where it can't go around: drawn in place, as before, and still right.
        lua_do("FL.open(8, 30, 30, 6, { blend = 30 }); return 1")
        t.read(0.2)
        out = t.keys(b"\x05", idle=0.15)
        check("a see-through float: no glide", glides(out) == [], repr(out[-200:]))
        # (Not compared under it: screenstring() has the float's blanks, the text shows through.)
        lua_do("FL.closeall(); return 1")
        t.read(0.2)
        check("a see-through float closed: same screen", same_screen() == [], same_screen())
        lua_do("for i = 0, 4 do FL.open(1 + 5 * i, 40, 10, 2) end return 1")
        t.read(0.2)
        out = t.keys(b"\x05", idle=0.15)
        check("five floats: no glide", glides(out) == [], repr(out[-200:]))
        check("five floats: same screen", same_screen() == [], same_screen())
        lua_do("FL.closeall(); FL.open(0, 0, %d, %d); return 1" % (COLS, ROWS - 2))
        t.read(0.2)
        out = t.keys(b"\x05", idle=0.15)
        check("a float over all of it: no glide", glides(out) == [], repr(out[-200:]))
        check("a float over all of it: same screen", same_screen() == [], same_screen())
        lua_do("FL.closeall(); return 1")
        t.read(0.2)
    finally:
        t.close()

    # Everything that moves or changes lines, under floats that overlap the
    # window every way, with double-width text cut by their edges; beside the
    # sidebar and in splits, with and without smooth scrolling.
    keys = [b"\x05", b"\x05", b"\x19", b"\x04", b"\x15", b"\x06", b"\x02", b"3\x05", b"3\x19", b"j", b"k", b"L",
            b"Lj", b"Hk", b"zz", b"zt", b"zb", b"gg", b"G", b"dd", b"u", b"ox\x1b", b"u", b"20j", b"20k", b"p", b"u",
            b"Jx", b"u", b"zL", b"zH", b":set wrap!\r", b"\x1b", b"i\x18\x05\x1b", b"i\x18\x19\x1b", b"ohello \x18\x0e\x18\x05\x18\x05\x1b", b"u"]
    setups = [
        ("full width", True, [], "FL.open(1, 60, 30, 5, { border = 'single' }); FL.open(20, 0, 25, 4); FL.open(10, 40, 20, 3)"),
        ("beside the sidebar", True, [b"\x13", b"\t"], "FL.open(0, 70, 28, 6, { border = 'rounded' }); FL.open(18, 20, 40, 5)"),
        ("in a split", True, [b":vsplit\r"], "FL.open(3, 35, 30, 8); FL.open(20, 80, 30, 6)"),
        ("no smooth scrolling", False, [], "FL.open(1, 60, 30, 5, { border = 'single' }); FL.open(20, 0, 25, 4)"),
    ]
    rng = random.Random(7)
    for name, smooth, first, code in setups:
        t, expr, lua_do, sync, same_screen, screen = session(smooth, name.replace(" ", "-"))
        try:
            lua_do(FLOAT_LUA)
            for k in first:
                t.keys(k, idle=0.25)
            lua_do(code + "; return 1")
            t.read(0.2)
            bad = same_screen()
            sequence = list(keys) + [rng.choice(keys) for _ in range(30)]
            for k in sequence:
                if bad:
                    break
                t.keys(k, idle=0.1)
                bad = same_screen()
                if bad:
                    bad = (k, bad)
            check("%s: the terminal shows what Neovim does after every key (%d keys)" % (name, len(sequence)),
                  not bad, bad)
        finally:
            t.close()


def main():
    path = sample()
    t = Term([path])
    try:
        startup = t.read(1.0)
        check("queries mode 2032", b"\x1b[?2032$p" in startup)
        check("turns mode 2032 on", b"\x1b[?2032h" in t.log, repr(t.log[-200:]))

        out = t.keys(b"\x05")  # CTRL-E
        moves = [(f.find(b"\x1b[M"), m.start()) for f in frames(out) for m in [GLIDE.search(f)] if m]
        check("CTRL-E glides 1 row", glides(out) == [1000], repr(out))
        check("glide is inside the frame, after the region scroll",
              len(moves) == 1 and 0 <= moves[0][0] < moves[0][1], repr(out))
        rect = RECT.search(out)
        check("rectangle is the window", rect is not None
              and tuple(int(x) for x in rect.groups()) == (1, 1, WIN_H, COLS), repr(out))

        check("CTRL-Y glides back", glides(t.keys(b"\x19")) == [-1000])
        check("CTRL-D glides half a window", glides(t.keys(b"\x04")) == [WIN_H // 2 * 1000])
        check("CTRL-U glides back", glides(t.keys(b"\x15")) == [-(WIN_H // 2) * 1000])
        check("CTRL-F glides a page", glides(t.keys(b"\x06")) == [(WIN_H - 2) * 1000])
        check("CTRL-B glides a page back", glides(t.keys(b"\x02")) == [-(WIN_H - 2) * 1000])
        check("wheel glides", glides(t.keys(b"\x1b[<65;10;10M")) == [3000])
        check("j at the bottom edge glides", glides(t.keys(b"L") + t.keys(b"j")) == [1000])
        check("rectangle sent once per window", RECT.search(t.keys(b"\x05")) is None)

        out = t.keys(b"10Gdd")
        check("dd does not glide", glides(out) == [] and b"\x1b[M" in out, repr(out))
        out = t.keys(b"o")
        out += t.keys(b"\x1b")
        check("o does not glide", glides(out) == [])

        out = t.keys(b"\x05", idle=0.0) + t.keys(b"G")
        check("G mid-glide snaps, no glide", glides(out[out.find(b"\x1b[") :]) in ([1000], []) and SNAP in out,
              repr(out[-300:]))
        out = t.keys(b"gg")
        check("gg (far jump) does not glide", glides(out) == [])

        out = t.keys(b":vsplit\r")
        out = t.keys(b"gg\x05")
        rect = RECT.search(out)
        check("split window glides", glides(out) == [1000], repr(out))
        check("split window: full-width band, no left/right margins",
              b"\x1b[?69h" not in out and b"\x1b[1;%dr" % WIN_H in out, repr(out))
        check("split window: rectangle is its columns", rect is not None
              and int(rect.group(1)) == 1 and int(rect.group(3)) == WIN_H
              and int(rect.group(2)) == 1 and int(rect.group(4)) < COLS, repr(out))
        check("marker never reaches the terminal", b"nvim-glide" not in t.log)
    finally:
        t.close()
    check("turns mode 2032 off on exit", b"\x1b[?2032l" in t.log)

    # The file sidebar glides only with g:yeyito_sidebar_smooth_scroll.
    project = tempfile.mkdtemp(prefix="nvim-smooth-project-")
    for i in range(80):
        open(os.path.join(project, "file%02d.txt" % i), "w").close()
    t = Term([path], cwd=project)
    try:
        t.read(1.0)
        t.keys(b"\x13")  # CTRL-S
        # In the sidebar CTRL-E moves an entry to the top of its folder (as in
        # Exocortex), so it scrolls with CTRL-D / CTRL-Y here.
        out = t.keys(b"gg") + t.keys(b"\x04")
        check("sidebar does not glide by default", glides(out) == [] and b"file" in out, repr(out[-300:]))
        t.keys(b":let g:yeyito_sidebar_smooth_scroll = v:true\r")
        check("sidebar glides with the flag on", glides(t.keys(b"\x19")) == [-1000])
        t.keys(b":let g:yeyito_sidebar_smooth_scroll = v:false\r")
        check("flag off again: sidebar jumps", glides(t.keys(b"\x19")) == [])
        t.keys(b"\t")  # to the editor
        check("editor beside the sidebar still glides", glides(t.keys(b"gg\x05")) == [1000])
        check("marker never reaches the terminal (sidebar)", b"nvim-glide" not in t.log)
    finally:
        t.close()

    t = Term([path], smooth=False)
    try:
        t.read(1.0)
        out = t.keys(b"\x05\x04")
        check("no mode 2032 without support", b"\x1b[?2032h" not in t.log and b"2032;" not in t.log)
        check("still scrolls without support", b"\x1b[M" in out or b"M" in out)
        check("marker never reaches a terminal without support", b"nvim-glide" not in t.log)
    finally:
        t.close()

    floats()

    print("%d failure(s)" % len(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
