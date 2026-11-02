#!/usr/bin/env python3
"""Several Neovims in one folder share the AI conversation through the daemon:
  python3 test/yeyito/test_ai_shared.py
Real Neovims (headless, driven over --listen) on Exocortex's fake daemon
(clients/testing/fake-daemon.ts, needs bun; EXOCORTEX_DIR, else
~/Workspace/exocortex or ~/Desktop/Exocortex), whose scripted model calls a tool
when the prompt is "tool NAME JSON"."""
import json
import os
import shutil
import socket
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


def exo_dir():
    for d in (os.environ.get("EXOCORTEX_DIR", ""), "~/Workspace/exocortex", "~/Desktop/Exocortex"):
        d = os.path.expanduser(d)
        if d and os.path.exists(os.path.join(d, "clients/testing/fake-daemon.ts")):
            return d
    return None


class Neovim:
    # What each one's AI did, how it ended, and its card, for the checks.
    SETUP = """
      _G.ai = require("yeyito.ai")
      ai.context = false
      vim.o.updatetime = 100000 -- no CursorHold checktime in the moment a file changes (it costs that edit's tint)
      _G.did, _G.done = {}, {}
      ai.on_did = function(what) did[#did + 1] = what end
      ai.on_done = function(kind, text) done[#done + 1] = kind .. ": " .. text end
      _G.card = function()
        local c = ai._card
        if not (c.win and vim.api.nvim_win_is_valid(c.win)) then return {} end
        return vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
      end
    """

    def __init__(self, name, cwd, env, tmp):
        self.name = name
        self.sock = os.path.join(tmp, name + ".sock")
        self.env = env
        self.proc = subprocess.Popen(
            [NVIM, "--headless", "--listen", self.sock, "-u", "NORC", "-n"],
            cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: os.path.exists(self.sock), name + " listening")
        self.do(self.SETUP)

    def expr(self, expr):
        out = subprocess.run([NVIM, "--server", self.sock, "--remote-expr", expr], env=self.env,
                             capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(self.name + ": " + out.stderr)
        return out.stdout

    def lua(self, code):
        """The value of Lua expression `code`."""
        chunk = "return vim.json.encode((" + code + "))"
        return json.loads(self.expr("luaeval(" + json.dumps("assert(loadstring(_A))()") + ", " + json.dumps(chunk) + ")"))

    def do(self, code):
        """Run Lua statements."""
        self.expr("luaeval(" + json.dumps("(assert(loadstring(_A))() or 0) and 0") + ", " + json.dumps(code) + ")")

    def ask(self, request):
        self.do("ai.ask(" + lua_str(request) + ")")

    def card(self):
        return self.lua("card()")

    def card_says(self, text):
        return text in "\n".join(self.card())

    def edit(self, path):
        self.do("vim.cmd.edit(" + lua_str(path) + ")")

    def lines(self):
        return self.lua("vim.api.nvim_buf_get_lines(0, 0, -1, false)")

    def green(self):
        return self.lua('#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("yeyito.ai.changed"), 0, -1, {})')

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


def lua_str(s):
    return json.dumps(s)


def wait_for(cond, what="", timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def tool(name, **args):
    return "tool " + name + " " + json.dumps(args)


def daemon_cmd(path, cmd):
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    s.sendall((json.dumps(cmd) + "\n").encode())
    s.close()


def main():
    exo = exo_dir()
    if not exo or not shutil.which("bun"):
        print("skip: no Exocortex checkout or bun")
        return 0
    tmp = tempfile.mkdtemp(prefix="ai-shared-", dir=os.path.expanduser("~/.cache"))
    project = os.path.realpath(os.path.join(tmp, "project"))
    os.makedirs(project)
    sock = os.path.join(tmp, "daemon.sock")
    daemon = subprocess.Popen(["bun", os.path.join(exo, "clients/testing/fake-daemon.ts"), "--socket", sock],
                              stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_for(lambda: os.path.exists(sock), "daemon")
    env = dict(os.environ, EXOCORTEX_SOCKET=sock, VIMRUNTIME=os.path.join(REPO, "runtime"),
               XDG_STATE_HOME=os.path.join(tmp, "state"), XDG_DATA_HOME=os.path.join(tmp, "data"))
    all_nvims = []

    def nvim(name):
        n = Neovim(name, project, env, tmp)
        all_nvims.append(n)
        return n

    def write(name, *lines):
        with open(os.path.join(project, name), "w") as f:
            f.write("\n".join(lines) + "\n")

    def disk(name):
        with open(os.path.join(project, name)) as f:
            return f.read().split("\n")[:-1]

    try:
        a, b = nvim("a"), nvim("b")
        a.do("ai.sync()")
        b.do("ai.sync()")
        time.sleep(0.2)

        # One conversation, from whichever asks first.
        a.ask("count")
        wait_for(lambda: a.lua("done[1]"))
        check("the first request starts the folder's conversation", a.lua("done[1]") == "done: turns: 1", a.lua("done"))
        check("the other Neovim shows the reply", wait_for(lambda: b.card_says("turns: 1")), b.card())
        b.ask("count")
        wait_for(lambda: b.lua("done[1]"))
        check("the other Neovim's request goes in the same conversation", b.lua("done[1]") == "done: turns: 2", b.lua("done"))
        check("and the first shows that reply", wait_for(lambda: a.card_says("turns: 2")), a.card())

        # Each runs the tools of the requests asked in it; the others show them.
        write("app.py", "one", "two", "three")
        a.edit("app.py")
        b.edit("app.py")
        a.do("did = {}")
        b.do("did = {}; done = {}")
        b.ask(tool("edit_file", path="app.py", old_string="two", new_string="TWO"))
        wait_for(lambda: b.lua("done[1]"))
        check("the asker's Neovim runs the tool", b.lua("did") == ["edited app.py"] and a.lua("did") == [], (b.lua("did"), a.lua("did")))
        check("saved", disk("app.py") == ["one", "TWO", "three"], disk("app.py"))
        check("the other buffer has the edit", wait_for(lambda: a.lines() == ["one", "TWO", "three"]), a.lines())
        check("it isn't left modified", a.lua("vim.bo.modified") is False)
        check("tinted there too", a.green() == 1, a.green())
        a.do('vim.cmd("silent! checktime")')
        time.sleep(0.1)
        check("a checktime doesn't read it over the tint", a.green() == 1 and a.lua("vim.bo.autoread") is True, a.green())
        b.do("did = {}; done = {}")
        a.do("did = {}; done = {}")
        a.ask(tool("edit_file", path="app.py", old_string="one", new_string="ONE"))
        wait_for(lambda: a.lua("done[1]"))
        check("the sender changes: now the other's the one running them", a.lua("did") == ["edited app.py"] and b.lua("did") == [],
              (a.lua("did"), b.lua("did")))
        check("and the first follows", wait_for(lambda: b.lines() == ["ONE", "TWO", "three"]), b.lines())
        b.do('vim.cmd("silent normal! u")')
        check("one u undoes what the other's request did", b.lines() == ["one", "TWO", "three"], b.lines())
        b.do('vim.cmd("silent edit!")')

        # Unsaved changes stay.
        b.do('vim.api.nvim_buf_set_lines(0, 2, 3, false, {"three mine"})')
        a.do("done = {}")
        a.ask(tool("edit_file", path="app.py", old_string="TWO", new_string="2"))
        wait_for(lambda: a.lua("done[1]"))
        time.sleep(0.2)
        check("a buffer with unsaved changes is left alone", b.lines() == ["ONE", "TWO", "three mine"] and b.lua("vim.bo.modified") is True, b.lines())
        b.do('vim.cmd("silent edit!")')

        # A new file, a move, a delete.
        a.do("done = {}")
        a.ask(tool("move_path", **{"from": "app.py", "to": "pkg/moved.py"}))
        wait_for(lambda: a.lua("done[1]"))
        check("a move: the other's buffer follows, in its window",
              wait_for(lambda: b.lua("vim.api.nvim_buf_get_name(0)").endswith("pkg/moved.py")) and b.lines()[0] == "ONE",
              b.lua("vim.api.nvim_buf_get_name(0)"))
        check("and the old buffer goes", b.lua('vim.fn.bufnr(' + lua_str(os.path.join(project, "app.py")) + ')') == -1)
        a.do("done = {}")
        a.ask(tool("delete_path", path="pkg/moved.py"))
        wait_for(lambda: a.lua("done[1]"))
        check("a delete: the other closes it", wait_for(lambda: b.lua("vim.api.nvim_buf_get_name(0)") == ""),
              b.lua("vim.api.nvim_buf_get_name(0)"))

        # Progress, the queue, and stopping from either.
        a.do("done = {}")
        b.do("done = {}")
        a.ask("hang")
        check("the other shows it working", wait_for(lambda: b.card_says("thinking")), b.card())
        b.ask("count")
        check("asking there queues it", wait_for(lambda: b.card_says("1 queued")), b.card())
        check("not run yet", b.lua("done") == [], b.lua("done"))
        c = nvim("c")
        c.do("ai.sync()")
        check("a Neovim opened meanwhile shows it working", wait_for(lambda: c.card_says("thinking")), c.card())
        check("Ctrl+Q there stops it", b.lua("ai.stop()") is True)
        check("in the asker: Stopped", wait_for(lambda: a.lua("done[1]") == "error: Stopped."), a.lua("done"))
        check("then the queued one runs", wait_for(lambda: b.lua("done[1]") or False) and b.lua("done[1]").startswith("done: turns:"), b.lua("done"))
        check("the opened one shows that reply", wait_for(lambda: c.card_says("turns:")), c.card())
        c.quit()

        # A send that loses the race waits and runs.
        write("race.txt", "x")
        late = nvim("late")  # hasn't joined: asks in the moment the daemon refuses it
        a.do("done = {}")
        a.ask("hang")
        wait_for(lambda: b.card_says("thinking"))
        late.ask("count")
        check("the refused one waits", wait_for(lambda: late.card_says("1 queued")), late.card())
        check("Ctrl+Q from it", wait_for(lambda: late.lua("ai.stop()") is True))
        check("the refused one runs after it", wait_for(lambda: late.lua("done[1]") or False) and late.lua("done[1]").startswith("done: turns:"), late.lua("done"))
        wait_for(lambda: a.lua("done[1]"))
        a.do("done = {}")

        # The log is the daemon's: everyone's requests.
        late.do('vim.cmd("Ai log")')
        wait_for(lambda: late.lua("vim.bo.filetype") == "markdown")
        log = "\n".join(late.lines())
        check(":Ai log has all the Neovims' requests", "edit_file" in log and "move_path" in log and "## You" in log, log)
        late.quit()

        # Quitting stops your own request.
        a.ask("hang")
        wait_for(lambda: b.card_says("thinking"))
        a.quit()
        check("quitting stops what it was running", wait_for(lambda: b.card_says("Stopped")), b.card())

        # :Ai new is everyone's.
        a = nvim("a2")
        a.do("ai.sync()")
        wait_for(lambda: a.lua("true"))
        time.sleep(0.2)
        a.do("done = {}")
        b.do("done = {}")
        b.ask("hang")
        wait_for(lambda: a.card_says("thinking"))
        a.ask("count")
        a.do('vim.cmd("Ai new")')
        check(":Ai new: the other's running request goes", wait_for(lambda: b.card() == []), b.card())
        time.sleep(0.2)
        check(":Ai new: what was queued doesn't run", a.lua("done") == [], a.lua("done"))
        b.do("done = {}")
        b.ask("count")
        wait_for(lambda: b.lua("done[1]"))
        check(":Ai new: the next request starts a new one", b.lua("done[1]") == "done: turns: 1", b.lua("done"))
        check("and the others are in it", wait_for(lambda: a.card_says("turns: 1")), a.card())

        # The daemon restarts: still shared.
        a.do("done = {}")
        b.do("done = {}")
        daemon_cmd(sock, {"type": "fake_restart", "downMs": 200})
        time.sleep(1)
        a.ask("count")
        check("after a daemon restart: the conversation goes on", wait_for(lambda: a.lua("done[1]") == "done: turns: 2"), a.lua("done"))
        check("after a daemon restart: the other still follows", wait_for(lambda: b.card_says("turns: 2")), b.card())

        # Its end passes unseen: the daemon is asked.
        a.do("done = {}")
        b.do("done = {}")
        a.ask("slow 40")
        wait_for(lambda: b.card_says("thinking"))
        b.ask("count")
        daemon_cmd(sock, {"type": "fake_drop", "refuseMs": 1500})
        check("a result missed while disconnected: it isn't stuck", wait_for(lambda: b.lua("done[1]") or False, timeout=15), (b.lua("done"), b.card()))

        # Not on a Neovim in another folder.
        other = os.path.join(tmp, "other")
        os.makedirs(other)
        o = Neovim("o", other, env, tmp)
        all_nvims.append(o)
        o.do("ai.sync()")
        time.sleep(0.2)
        a.do("done = {}")
        a.ask("count")
        wait_for(lambda: a.lua("done[1]"))
        time.sleep(0.2)
        check("another folder's Neovim shows nothing", o.card() == [], o.card())
        o.ask("count")
        wait_for(lambda: o.lua("done[1]"))
        check("and has its own conversation", o.lua("done[1]") == "done: turns: 1", o.lua("done"))
    finally:
        for n in all_nvims:
            n.quit()
        daemon.terminate()
        try:
            daemon.wait(5)
        except subprocess.TimeoutExpired:
            daemon.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
