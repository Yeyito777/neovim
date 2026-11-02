#!/usr/bin/env python3
"""The file sidebar's folder counts: there in the first frame, all at once:
  python3 test/yeyito/test_sidebar_counts.py
Real Neovims (headless, driven over --listen) on a generated tree."""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NVIM = os.path.join(REPO, "build", "bin", "nvim")
failures = 0


def check(name, ok, detail=None):
    global failures
    print(("ok   " if ok else "FAIL ") + name + ("" if ok or detail is None else "  " + repr(detail)), flush=True)
    if not ok:
        failures += 1


def wait_for(cond, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return False


def touch(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").close()


class Neovim:
    instances = 0

    def __init__(self, cwd, env, tmp, extra=()):
        Neovim.instances += 1
        self.sock = os.path.join(tmp, f"n{Neovim.instances}.sock")
        self.env = env
        self.proc = subprocess.Popen([NVIM, "--headless", "--listen", self.sock, "-u", "NORC", "-n", *extra], cwd=cwd, env=env,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: os.path.exists(self.sock))
        self.do("""
          _G.S = require("yeyito.sidebar")
          _G.lines = function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
          _G.key = function(k) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false) end
          _G.pick = function(text)
            for i, l in ipairs(lines()) do
              if vim.trim(l):find(text, 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) return true end
            end
          end
        """)

    def expr(self, expr):
        out = subprocess.run([NVIM, "--server", self.sock, "--remote-expr", expr], env=self.env,
                             capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(out.stderr)
        return out.stdout

    def lua(self, code):
        """The value of Lua statements ending in a return."""
        wrapped = "local function f() " + code + " end return vim.json.encode(f())"
        return json.loads(self.expr("luaeval(" + json.dumps("assert(loadstring(_A))()") + ", " + json.dumps(wrapped) + ")"))

    def do(self, code):
        self.expr("luaeval(" + json.dumps("(assert(loadstring(_A))() or 0) and 0") + ", " + json.dumps(code) + ")")

    def lines(self):
        return [line.strip() for line in self.lua("return lines()")]

    def has(self, line):
        return line in self.lines()

    def quit(self):
        if self.proc.poll() is None:
            try:
                self.expr('execute("qa!")')
            except Exception:
                pass
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def main():
    tmp = tempfile.mkdtemp(prefix="counts-", dir=os.path.expanduser("~/.cache"))
    project = os.path.realpath(os.path.join(tmp, "project"))
    for rel in ("src/a", "src/b", "src/c", "src/deep/x", "src/deep/y", "src/deep/er/z", "lib/one", "lib/two", "top.txt", "we\nird/f"):
        touch(os.path.join(project, rel))
    os.makedirs(os.path.join(project, "empty"))
    os.makedirs(os.path.join(project, ".git"))
    touch(os.path.join(project, "src/.git/not-counted"))
    env = dict(os.environ, VIMRUNTIME=os.path.join(REPO, "runtime"), XDG_STATE_HOME=os.path.join(tmp, "state"),
               XDG_DATA_HOME=os.path.join(tmp, "data"))
    saved = os.path.join(tmp, "state", "nvim", "sidebar-counts")
    nvims = []

    def nvim(cwd=project, env_=env, extra=()):
        n = Neovim(cwd, env_, tmp, extra)
        nvims.append(n)
        return n

    try:
        # The first time ever: one walk, all the numbers in one redraw.
        a = nvim()
        first = a.lua("""
          S.open()
          _G.redraws = 0
          vim.api.nvim_buf_attach(0, false, { on_lines = function() redraws = redraws + 1 end })
          return lines()
        """)
        check("a project never seen: the sidebar opens at once, numbers on the way", any("src/" in line for line in first), first)
        check("the numbers land", wait_for(lambda: a.has("📁 src/ 6")), a.lines())
        check("all of them in one redraw", a.lua("return redraws") == 1, a.lua("return redraws"))
        rows = a.lines()
        check("every folder has its number", "📁 lib/ 2" in rows and "📁 empty/ 0" in rows, rows)
        check("a name with a newline in it too", "📁 we?ird/ 1" in rows, rows)
        check("the file is saved", len(glob.glob(saved + "/*")) == 1, glob.glob(saved + "/*"))

        # A name too long for its row: the name is cut, not the number.
        touch(os.path.join(project, "a-folder-with-a-really-long-name/f"))
        a.do('vim.cmd("doautocmd FocusGained")')
        check("a long name is cut, not its number", wait_for(lambda: any(line.endswith("… 1") for line in a.lines())), a.lines())

        # Past what a row can show: and what's inside it gets counted next.
        for sub in ("a", "b"):
            for i in range(6000):
                touch(os.path.join(project, "big", sub, f"f{i}"))
        a.do('vim.cmd("doautocmd FocusGained")')
        check("past 9999: 9999+", wait_for(lambda: a.has("📁 big/ 9999+")), a.lines())

        # Inside: there before the folder opens.
        opened = a.lua('pick("src/"); key("<CR>"); return lines()')
        check("opening a folder: its folders' numbers are in that same frame", any(line.strip() == "📁 deep/ 3" for line in opened), opened)
        opened = a.lua('pick("deep/"); key("<CR>"); return lines()')
        check("and all the way down", any(line.strip() == "📁 er/ 1" for line in opened), opened)
        opened = a.lua('pick("big/"); key("<CR>"); return lines()')
        check("past the limit too: 9999+, and what's inside it was counted next",
              any(line.strip() == "📁 a/ 6000" for line in opened) and any(line.strip() == "📁 b/ 6000" for line in opened), opened)
        a.do("S.close()")

        # The next Neovim has them in its first frame.
        b = nvim()
        first = [line.strip() for line in b.lua("S.open(); return lines()")]
        check("another Neovim: the numbers are in the first frame", "📁 src/ 6" in first and "📁 big/ 9999+" in first, first)

        # What the disk says changes quietly, without moving anything.
        time.sleep(0.5)  # the walk its opening started has ended
        touch(os.path.join(project, "lib/three"))
        b.do("S.close()")
        c = nvim()
        first = [line.strip() for line in c.lua('S.open(); pick("src/"); return lines()')]
        check("a saved number shows until the new one lands", "📁 lib/ 2" in first, first)
        check("the new one lands", wait_for(lambda: c.has("📁 lib/ 3")), c.lines())
        check("the cursor stayed", c.lua('return vim.trim(vim.api.nvim_get_current_line())').startswith("▸ ") is False
              and "src/" in c.lua("return vim.api.nvim_get_current_line()"), c.lua("return vim.api.nvim_get_current_line()"))
        redraws = c.lua("""
          _G.redraws = 0
          vim.api.nvim_buf_attach(0, false, { on_lines = function() redraws = redraws + 1 end })
          vim.cmd("doautocmd FocusGained")
          return true
        """)
        time.sleep(0.5)
        check("nothing changed on disk: another walk draws nothing new", redraws and "📁 lib/ 3" in c.lines())

        # Back in the window: closed folders are looked at again.
        touch(os.path.join(project, "lib/four"))
        c.do('vim.cmd("doautocmd FocusGained")')
        check("focus back: a closed folder's new file counts", wait_for(lambda: c.has("📁 lib/ 4")), c.lines())
        touch(os.path.join(project, "lib/five"))
        c.do('vim.cmd("doautocmd ShellCmdPost")')
        check("after a :! too", wait_for(lambda: c.has("📁 lib/ 5")), c.lines())

        # A folder that appears later.
        os.makedirs(os.path.join(project, "later"))
        touch(os.path.join(project, "later/f"))
        c.do('vim.cmd("doautocmd FocusGained")')
        check("a new folder gets its number", wait_for(lambda: c.has("📁 later/ 1")), c.lines())

        # Prefetched: nothing to read until the sidebar opens.
        other = os.path.realpath(os.path.join(tmp, "other"))
        touch(os.path.join(other, "pkg/f"))
        d = nvim(other)
        d.do("S._prefetch()")
        check("started: the project is counted before the sidebar opens", wait_for(lambda: len(glob.glob(saved + "/*")) == 2), glob.glob(saved + "/*"))
        wait_for(lambda: d.lua("return true"))
        first = [line.strip() for line in d.lua("S.open(); return lines()")]
        check("then the first frame has it", "📁 pkg/ 1" in first, first)
        d.do("S.close()")
        time.sleep(0.3)  # the walk its opening started has ended
        files = glob.glob(saved + "/*")
        stamp = {f: os.stat(f).st_mtime_ns for f in files}
        e = nvim(other)
        e.do("S._prefetch()")
        time.sleep(0.3)
        check("started again right away: no walk", stamp == {f: os.stat(f).st_mtime_ns for f in files})

        # Not at the start in the home folder.
        home_env = dict(env, HOME=other)
        h = nvim(other, home_env)
        for f in files:
            os.utime(f, (time.time() - 3600, time.time() - 3600))
        stamp = {f: os.stat(f).st_mtime_ns for f in files}
        h.do("S._prefetch()")
        time.sleep(0.3)
        check("in the home folder: not until the sidebar opens", stamp == {f: os.stat(f).st_mtime_ns for f in files})
        h.do("S.open()")
        check("then it is", wait_for(lambda: stamp != {f: os.stat(f).st_mtime_ns for f in files}))

        # Gone after a month.
        old = os.path.join(saved, "0123456789abcdef")
        touch(old)
        os.utime(old, (time.time() - 40 * 86400, time.time() - 40 * 86400))
        a.do('S.open(); vim.cmd("doautocmd FocusGained")')
        check("a project not opened for a month is forgotten", wait_for(lambda: not os.path.exists(old)))

        # Off.
        off_state = os.path.join(tmp, "off-state")
        f = nvim(project, dict(env, XDG_STATE_HOME=off_state), ("--cmd", "let g:yeyito_sidebar_counts = v:false"))
        f.do('S.open(); S._prefetch(); vim.cmd("doautocmd FocusGained")')
        time.sleep(0.3)
        check("turned off: no numbers, nothing saved", "📁 src/" in f.lines() and not os.path.exists(os.path.join(off_state, "nvim", "sidebar-counts")), f.lines())

        # Threads end.
        if os.path.exists("/proc/self/task"):
            g = nvim()
            g.do("S.open()")
            wait_for(lambda: g.has("📁 src/ 6"))
            for _ in range(5):
                g.do('vim.cmd("doautocmd FocusGained")')
                time.sleep(0.25)
            time.sleep(0.2)
            tasks = len(os.listdir(f"/proc/{g.proc.pid}/task"))
            base = nvim()
            base_tasks = len(os.listdir(f"/proc/{base.proc.pid}/task"))
            check("walks leave no threads behind", tasks <= base_tasks, (tasks, base_tasks))

        # A frozen Neovim would show only after the walks: luv joins a thread by itself,
        # so joining one too froze it a second later.
        k = nvim()
        k.do("S.open()")
        wait_for(lambda: k.has("📁 src/ 6"))
        for _ in range(3):
            k.do('vim.cmd("doautocmd FocusGained")')
            time.sleep(0.2)
        time.sleep(1.5)
        check("still answering a while after several walks", k.lua("return 1 + 1") == 2)

        # Quitting doesn't wait for a walk.
        worst = 0
        code = 0
        for _ in range(10):
            started = time.time()
            done = subprocess.run([NVIM, "--headless", "-u", "NORC", "-n", "-c", 'lua require("yeyito.sidebar").open()', "-c", "qa!"],
                                  cwd=project, env=dict(env, XDG_STATE_HOME=os.path.join(tmp, "quit-state")),
                                  stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            worst = max(worst, time.time() - started)
            code = code or done.returncode
            shutil.rmtree(os.path.join(tmp, "quit-state"), ignore_errors=True)
        check("quitting in the middle of a walk: at once, cleanly", code == 0 and worst < 2, (code, worst))
    finally:
        for n in nvims:
            n.quit()
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
