"""Exercise real TUI startup with an intentionally unresponsive terminal."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import termios
import time

parser = argparse.ArgumentParser()
parser.add_argument("binary")
parser.add_argument("report_dir")
parser.add_argument("--runtime")
args = parser.parse_args()
report_dir = Path(args.report_dir)
report_dir.mkdir(parents=True, exist_ok=True)


def start(label, slow, full_config=False):
    env = os.environ.copy()
    for key in ("NVIM_TEST", "NVIM_NOTTYFAST", "COLORTERM", "TERM_PROGRAM"):
        env.pop(key, None)
    env["TERM"] = "xterm-256color"
    if args.runtime:
        env["VIMRUNTIME"] = args.runtime
    if slow:
        env["NVIM_NOTTYFAST"] = "1"
    assertion = (
        "assert(vim.o.ttyfast == "
        + ("false" if slow else "true")
        + "); assert(vim.fn.has('conceal_compact') == 1)"
    )
    command = [args.binary, "-n", "-i", "NONE"]
    if full_config:
        sample = report_dir / "terminal-probe-test.md"
        lines = ["[Label](https://example.test/" + "x" * 300 + ")", "next line"]
        sample.write_text("\n".join(lines) + "\n")
        command.append(str(sample))
        assertion += (
            "; assert(vim.bo.filetype == 'markdown')"
            "; require('yeyito.markdown_links').refresh(); vim.cmd('redraw!')"
            "; assert(vim.api.nvim_win_text_height(0, "
            "{start_row=0,end_row=0}).all == 1)"
            "; assert(vim.api.nvim_buf_get_lines(0,0,-1,true)[2] == 'next line')"
        )
    else:
        command += ["-u", "NONE"]
    command += ["+lua vim.wait(300); " + assertion, "+qa"]

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 25, 80, 0, 0))
    started = time.monotonic()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()
    timed_out = False
    try:
        while time.monotonic() - started < 25:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            elif process.poll() is not None:
                break
        if process.poll() is None:
            timed_out = True
            process.kill()
        process.wait()
    finally:
        os.close(master)
    (report_dir / (label + ".pty")).write_bytes(output)
    result = {
        "case": label,
        "exit": process.returncode,
        "timed_out": timed_out,
        "seconds": round(time.monotonic() - started, 3),
        "warning": b"Did not detect DSR response" in output,
        "dsr_probe": b"\x1b[5n" in output,
        "background_probe": b"\x1b]11;?" in output,
        "dsr_probe_count": output.count(b"\x1b[5n"),
        "background_probe_count": output.count(b"\x1b]11;?"),
        "lua_error": b"E5108" in output,
    }
    print(json.dumps(result), flush=True)
    assert result["exit"] == 0 and not result["timed_out"] and not result["lua_error"], result
    # The TUI still sends one asynchronous OSC 11/DSR pair. ttyfast controls
    # the extra Lua-level query and its blocking 100 ms startup wait.
    if slow:
        assert not result["warning"], result
        assert result["dsr_probe_count"] == result["background_probe_count"] == 1, result
    else:
        assert result["warning"], result
        assert result["dsr_probe_count"] == result["background_probe_count"] == 2, result
    if full_config:
        assert sample.read_text() == "\n".join(lines) + "\n"
    return result


results = [
    start("normal-unresponsive-terminal", False),
    start("slow-unresponsive-terminal", True),
    start("slow-user-config-markdown", True, True),
]
(report_dir / "terminal-probes.json").write_text(json.dumps(results, indent=2) + "\n")
print("PASS: startup probe control and real-config Markdown wrapping/source preservation")
