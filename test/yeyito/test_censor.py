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
        "key for openai: <%s>" % SECRET,
        "two: <aa> MID <bb>",
        "echo nothing here",
        "long: <%s>" % LONG,
        'export QUOTED="qv-123secretA"',
        "PLAIN=pv-456secretB other words",
        "# COMMENTED=cv-789notsecret",
        "export SINGLE='sv-000secretC'",
        'export COOKIE="a=1; b={\"k\":\"jv-111secretD\"}; c=tail-222secretE"',
        'export PEM="-----BEGIN KEY-----',
        "pemline1-333secretF",
        "pemline2-444secretG",
        '-----END KEY-----"',
        "echo after the key",
        'export NOTE="nv-555secretH" # a note here',
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
        check("a secret longer than the screen line is dots all the way", "END" not in text and "x" not in text.replace("export", "").replace("xxx", ""), text[:900])
        check("export NAME=\"value\": the value is dots, the quotes show",
              "qv-123secretA" not in text and 'export QUOTED="' + "•" * 13 + '"' in text, text)
        check("NAME=value: up to the first space", "pv-456secretB" not in text and "PLAIN=" + "•" * 13 + " other words" in text, text)
        check("quotes inside a value: dots to the last quote", "jv-111secretD" not in text and "tail-222secretE" not in text, text)
        check("a quoted value over several lines: every line of it", "secretF" not in text and "secretG" not in text and "BEGIN" not in text and "END KEY" not in text, text)
        check("the line after it shows", "echo after the key" in text, text)
        check("a comment after a value shows", "nv-555secretH" not in text and "# a note here" in text, text)
        s.feed(t.keys(b"/pemline2\r"))
        text = screen_text(s)
        check("the cursor in it: all of it shows", "pemline1-333secretF" in text and "pemline2-444secretG" in text and "BEGIN" in text, text)
        s.feed(t.keys(b"G"))
        check("and off it, all dots again", "secretF" not in screen_text(s))
        check("single quotes too", "sv-000secretC" not in text, text)
        check("a comment isn't an assignment", "cv-789notsecret" in text, text)
        s.feed(t.keys(b"5G0fq"))
        check("the cursor in a value: it shows", "qv-123secretA" in screen_text(s))
        s.feed(t.keys(b"0"))
        check("the cursor on the name: dots", "qv-123secretA" not in screen_text(s))
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
