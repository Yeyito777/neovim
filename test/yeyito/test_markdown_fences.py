import os
import pynvim

argv = [os.environ.get("NVIM_TEST_BIN", "nvim"), "-n", "-i", "NONE", "--embed"]
if os.environ.get("NVIM_TEST_SSH"):
    argv = ["ssh", "-T", os.environ["NVIM_TEST_SSH"]] + argv
n = pynvim.attach("child", argv=argv)


def rows():
    n.command("redraw!")
    return n.exec_lua("""
      local out = {}
      for row = 1, 12 do
        local s = ''
        for col = 1, vim.o.columns do
          s = s .. vim.fn.screenstring(row, col)
        end
        out[row] = s
      end
      return out
    """)


try:
    n.ui_attach(90, 24, rgb=True)
    n.command("setfiletype markdown")
    n.input("i```")
    screen = rows()
    assert n.current.buffer[0] == "```"
    assert "```" in screen[0], ("typed fence hidden in Insert mode", screen)
    n.input("\x1b")
    assert "```" in rows()[0], "fence hidden in Normal mode"
    n.input("Alua\x1b")
    assert "```lua" in rows()[0], "language annotation hidden"

    for fence in ["```", "~~~"]:
        lines = [
            "# Fence regression",
            "",
            fence + "lua",
            'local answer = 42 -- syntax highlighting stays enabled',
            fence,
            "",
            fence,
            "[Literal](https://example.com/inside-code)",
            fence,
            "",
            "[Link](https://example.com/outside-code)",
        ]
        n.current.buffer[:] = lines
        n.current.window.cursor = (1, 0)
        n.exec_lua('require("yeyito.markdown_links").refresh()')
        screen = rows()
        assert fence + "lua" in screen[2], screen
        for row in [4, 6, 8]:
            assert fence in screen[row], (row, screen)
        assert "[Literal](https://example.com/inside-code)" in screen[7], screen
        assert "[Link]" in screen[10] and "https:" not in screen[10], screen
        assert list(n.current.buffer[:]) == lines
        assert n.exec_lua("""
          local p = vim.treesitter.get_parser(0, 'markdown')
          p:parse(true)
          return p:children().lua ~= nil
        """), "Lua code highlighting injection missing"
    print("PASS: typed fences in Insert/Normal mode, language tags, backtick/tilde "
          "blocks, literal code links, normal link concealment, source intact")
finally:
    try:
        n.command("qa!")
    except EOFError:
        pass
