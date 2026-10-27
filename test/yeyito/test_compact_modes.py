import os,pynvim
BIN=os.environ.get('NVIM_TEST_BIN',os.path.abspath('build/bin/nvim'))
n=pynvim.attach('child',argv=[BIN,'-u','NONE','-i','NONE','-n','--embed'])
try:
 n.ui_attach(35,15,rgb=True)
 n.command('set conceallevel=2 concealcursor=nvic noshowmode noruler laststatus=0 mouse=a')
 ns=n.api.create_namespace('modes')
 raw='one [Label](https://example.test/'+'x'*200+') after word word word word word'
 start=raw.index('(');end=raw.index(')')+1
 n.current.buffer[:]=[raw,'second line','third line']
 def marks():return n.api.buf_set_extmark(0,ns,0,start,{'end_col':end,'conceal':'','conceal_compact':True})
 mark=marks()
 n.command('redraw!')
 compact_height=n.api.win_text_height(0,{'start_row':0,'end_row':0})['all']
 assert compact_height==2,compact_height
 n.api.buf_del_extmark(0,ns,mark)
 n.command('redraw!')
 assert n.api.win_text_height(0,{'start_row':0,'end_row':0})['all']>5
 mark=marks();n.command('redraw!')
 assert n.api.win_text_height(0,{'start_row':0,'end_row':0})['all']==compact_height
 # Cursor stays on the correct source bytes while screen motion uses compact cells.
 n.current.window.cursor=(1,end+1)
 n.command('normal! gj')
 assert n.current.window.cursor[0]==1,n.current.window.cursor
 n.command('normal! gk')
 assert n.current.window.cursor==(1,end+1),n.current.window.cursor
 # Native selection and registers retain the complete source, including the URL.
 n.command('normal! 0v$y')
 assert n.funcs.getreg('"').rstrip('\n')==raw,repr(n.funcs.getreg('"'))
 n.command('normal! \x1b')
 # Expansion/edit/undo/re-collapse never rewrites display text into the source.
 n.api.buf_clear_namespace(0,ns,0,-1)
 n.current.window.cursor=(1,start+1)
 n.input('iNEW\x1b');n.command('redraw!')
 assert n.current.buffer[0][start+1:start+4]=='NEW'
 n.command('normal! u')
 assert n.current.buffer[0]==raw
 marks();n.command('redraw!')
 assert n.api.win_text_height(0,{'start_row':0,'end_row':0})['all']==compact_height
 # level 0/1 retain ordinary legacy conceal behavior; level 2/3 compact.
 for level in [0,1,2,3]:
  n.command('set conceallevel='+str(level));n.command('redraw!')
  height=n.api.win_text_height(0,{'start_row':0,'end_row':0})['all']
  assert (height==compact_height)==(level>=2),(level,height)
 n.command('set conceallevel=2')
 # Preserve sources across writing.
 path=os.path.abspath('compact-native-write-test.md')
 n.command('write! '+n.funcs.fnameescape(path))
 assert open(path).read()=='\n'.join([raw,'second line','third line'])+'\n'
 os.unlink(path)
 print('PASS: geometry invalidation, gj/gk, source selection/yank, insert/undo, levels 0–3, unchanged on-disk Markdown')
finally:
 try:n.command('qa!')
 except Exception:pass
