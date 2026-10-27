import os, pynvim
argv = [os.environ.get('NVIM_TEST_BIN', 'nvim'), '-n', '--embed']
if os.environ.get('NVIM_TEST_SSH'): argv = ['ssh', '-T', os.environ['NVIM_TEST_SSH']] + argv
n = pynvim.attach('child', argv=argv)
try:
    n.ui_attach(90, 25, rgb=True)
    n.current.buffer[:] = ['[Lab](https://example.test) and [Code](https://code.test)', 'plain text']
    n.command('setfiletype markdown')
    n.exec_lua('launched={}; vim.system=function(argv,_,cb) table.insert(launched,argv[2]); cb({code=0}) end')
    def screen():
        n.command('redraw')
        return n.exec_lua("local s=''; for c=1,vim.o.columns do s=s..vim.fn.screenstring(1,c) end; return s")
    s=screen()
    assert '[Lab] and [Code]' in s and 'https' not in s,repr(s)
    col=s.index('Code')+1
    n.api.input_mouse('left','press','',0,0,col)
    n.command('redraw')
    n.api.input_mouse('left','release','',0,0,col)
    n.command('redraw')
    assert n.exec_lua('return launched')==['https://code.test'], (n.exec_lua('return launched'), n.current.window.cursor)
    n.current.window.cursor=(1,2)
    n.input('\r'); n.command('redraw')
    assert n.exec_lua('return launched')==['https://code.test','https://example.test']
    n.input(' me'); n.command('redraw')
    s=screen()
    assert '[Lab](https://example.test)' in s and 'https://code' not in s,repr(s)
    n.input(' ma'); n.command('redraw')
    s=screen()
    assert '[Code](https://code.test)' in s,repr(s)
    n.input(' ma'); n.command('redraw')
    s=screen()
    assert '[Lab] and [Code]' in s and 'https' not in s,repr(s)
    n.current.window.cursor=(2,1)
    n.input('\r'); n.command('redraw')
    assert len(n.exec_lua('return launched'))==2
    if n.funcs.has('conceal_compact'):
        n.current.buffer[:] = ['[Robot Vision and Learning](https://rvl.cs.toronto.edu/) · [Lab joining FAQ](https://rvl.cs.toronto.edu/joining)', 'next line']
        n.exec_lua('require("yeyito.markdown_links").refresh()')
        n.ui_try_resize(80,25)
        s=screen()
        assert '[Robot Vision and Learning] · [Lab joining FAQ]' in s,repr(s)
        assert n.api.win_text_height(0,{'start_row':0,'end_row':0})['all']==1
    print('PASS: rendered labels, native visible-width wrapping, mouse, Enter, one/all expansion, non-link Enter')
finally:
    try: n.command('qa!')
    except EOFError: pass
