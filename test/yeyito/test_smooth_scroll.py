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
import time

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
        out = t.keys(b"gg") + t.keys(b"\x05")
        check("sidebar does not glide by default", glides(out) == [] and b"file" in out, repr(out[-300:]))
        t.keys(b":let g:yeyito_sidebar_smooth_scroll = v:true\r")
        check("sidebar glides with the flag on", glides(t.keys(b"\x05")) == [1000])
        t.keys(b":let g:yeyito_sidebar_smooth_scroll = v:false\r")
        check("flag off again: sidebar jumps", glides(t.keys(b"\x05")) == [])
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

    print("%d failure(s)" % len(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
