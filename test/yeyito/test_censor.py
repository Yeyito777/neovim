#!/usr/bin/env python3
"""keys.sh and secrets.sh show what's between < and > as dots, except the span
under the cursor: the real TUI on a fake st, what it draws read with Screen.

    python3 test/yeyito/test_censor.py
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_smooth_scroll as T  # noqa: E402
from test_smooth_scroll import Screen, Term, check, failures  # noqa: E402,F401

SECRET = "sk-live-9f8e7d6c5b4a"
LONG = "x" * 150 + "END"


def screen_text(screen):
    return "\n".join("".join(row) for row in screen.cells)


def main():
    tmp = tempfile.mkdtemp(prefix="nvim-censor-", dir=os.path.expanduser("~/.cache"))
    lines = [
        "export OPENAI_KEY=<%s>" % SECRET,
        "export TWO=<aa> MID <bb>",
        "echo nothing here",
        "export LONG=<%s>" % LONG,
    ]
    for name in ("keys.sh", "secrets.sh", "other.sh"):
        with open(os.path.join(tmp, name), "w") as f:
            f.write("\n".join(lines) + "\n")

    def run(name):
        t = Term([os.path.join(tmp, name)], cwd=tmp, cmds=["set wrap", "normal! 3G"])
        s = Screen(T.ROWS, T.COLS)
        s.feed(t.read(1.5))
        return t, s

    t, s = run("keys.sh")
    try:
        text = screen_text(s)
        check("keys.sh: a secret off the cursor is dots", SECRET not in text and "<" + "•" * len(SECRET) + ">" in text, text[:300])
        check("two spans on a line, the text between them shows", "<••> MID <••>" in text, text[:400])
        check("a secret longer than the screen line is dots all the way", "END" not in text and "x" not in text.replace("export", ""), text[:900])
        s.feed(t.keys(b"1G"))
        s.feed(t.keys(b"0"))
        text = screen_text(s)
        check("the cursor on the line but not over it: still dots", SECRET not in text, text[:200])
        s.feed(t.keys(b"f<"))
        text = screen_text(s)
        check("the cursor on its <: it shows", SECRET in text, text[:200])
        s.feed(t.keys(b"$"))
        check("and on its >", SECRET in screen_text(s))
        s.feed(t.keys(b"j"))
        text = screen_text(s)
        check("cursor off it: dots again", SECRET not in text and "<" + "•" * len(SECRET) + ">" in text, text[:300])
        s.feed(t.keys(b"0f<l"))
        text = screen_text(s)
        check("only the span under the cursor shows", "<aa> MID <••>" in text, text[:400])
        s.feed(t.keys(b"1G0f<a-NEW\x1b"))
        check("typing in it: it shows while there", SECRET[:1] + "-NEW" in screen_text(s) or "<-NEW" in screen_text(s))
        s.feed(t.keys(b"3G"))
        check("and is dots after", "NEW" not in screen_text(s))
        s.feed(t.keys(b"u"))
    finally:
        t.close()

    t, s = run("secrets.sh")
    try:
        check("secrets.sh too", SECRET not in screen_text(s))
    finally:
        t.close()

    t, s = run("other.sh")
    try:
        check("any other file shows as it is", SECRET in screen_text(s))
    finally:
        t.close()

    with open(os.path.join(tmp, "keys.sh")) as f:
        check("the file itself is never changed", f.read().split("\n")[0] == lines[0])
    print("%d failure(s)" % len(T.failures))
    return 1 if T.failures else 0


if __name__ == "__main__":
    sys.exit(main())
