import os,random,pynvim
BIN=os.environ.get('NVIM_TEST_BIN',os.path.abspath('build/bin/nvim'))
def boot():
 n=pynvim.attach('child',argv=[BIN,'-u','NONE','-i','NONE','-n','--embed'])
 n.ui_attach(60,18,rgb=True)
 n.command('set conceallevel=2 concealcursor=nvic noshowmode noruler laststatus=0 scrolloff=0 mouse=a')
 return n
raw,ref=boot(),boot()
ns=raw.api.create_namespace('compact')
rng=random.Random(32)
cases=[
 ['[Robot Vision and Learning]',('https://rvl.cs.toronto.edu/'), ' · [Lab joining FAQ]',('https://rvl.cs.toronto.edu/joining')],
 ['Start ',('x'*1200),' end'],
 ['  [Alpha]',('x'*140),' · [東京 🤖]',('abcdef'*10),' tab\t END words words words words'],
 ['before [label]',('hidden\t🤖東京 \ttext'),' after'],
 ['x'*19,('y'*90),'界 word word word word'],
]
# Mark hidden pieces as tuples, leave visible parts strings.
cases=[
 [('visible',s) if i%2==0 else ('hidden',s) for i,s in enumerate(case)] for case in cases
]
for _ in range(15):
 case=[]
 for j in range(5):
  case.append(('visible',rng.choice([' label ', '[Hello] ', '🤖 ', 'words 東京 ', '\tfoo ', 'a'*21])))
  case.append(('hidden',rng.choice(['https://test/'+('foo/'*20),'URL','\twide界🤖','hide me '*12])))
 cases.append(case)
def prepare(case):
 s='';v='';mapping={};ranges=[];rp=vp=0
 for kind,part in case:
  if kind=='hidden': ranges.append((rp,rp+len(part.encode())))
  else:
   for ch in part:
    mapping[vp]=rp;rp+=len(ch.encode());vp+=len(ch.encode())
   v+=part;s+=part;continue
  s+=part;rp+=len(part.encode())
 for n,line in [(raw,s),(ref,v)]:
  n.api.set_current_buf(n.api.create_buf(True,False))
  n.current.buffer[:]=[line]+['next line '+str(i) for i in range(25)]
  n.current.window.cursor=(1,0)
 for a,b in ranges:raw.api.buf_set_extmark(0,ns,0,a,{'end_col':b,'conceal':'','conceal_compact':True})
 return mapping
def grid(n):
 n.command('redraw!')
 return n.exec_lua("local out={};for r=1,15 do local s='';for c=1,vim.o.columns do s=s..vim.fn.screenstring(r,c) end;out[r]=s end;return out")
count=0
try:
 for config in ['set nolinebreak nobreakindent showbreak=','set linebreak nobreakindent showbreak=','set linebreak breakindent showbreak=>','set nolinebreak nobreakindent showbreak= number relativenumber']:
  for n in [raw,ref]:n.command(config)
  for width in [20,31,60,85]:
   for n in [raw,ref]:n.ui_try_resize(width,18)
   for index,case in enumerate(cases):
    if os.environ.get('NVIM_TEST_VERBOSE'): print('case',config,width,index,flush=True)
    mapping=prepare(case)
    ga,gb=grid(raw),grid(ref)
    assert ga==gb,('grid',config,width,index,ga,gb)
    for vc,rc in list(mapping.items())[::max(1,len(mapping)//7)]:
     raw.current.window.cursor=(1,rc);ref.current.window.cursor=(1,vc)
     ga,gb=grid(raw),grid(ref)
     assert ga==gb,('cursor grid',config,width,index,vc,rc,ga,gb)
     sa=raw.funcs.screenpos(raw.current.window.handle,1,rc+1)
     sb=ref.funcs.screenpos(ref.current.window.handle,1,vc+1)
     assert sa==sb,('screenpos',config,width,index,vc,rc,sa,sb)
     if sa['row']>0 and sa['col']>0:
      raw.api.input_mouse('left','press','',0,sa['row']-1,sa['col']-1);raw.command('redraw')
      raw.api.input_mouse('left','release','',0,sa['row']-1,sa['col']-1);raw.command('redraw')
      assert raw.current.window.cursor==(1,rc),('mouse',config,width,index,vc,rc,raw.current.window.cursor,sa)
    count+=1
 print('PASS',count,'projection cases: grids, scrolling, screenpos, mouse, Unicode/tabs, linebreak, breakindent, showbreak, number columns')
finally:
 for n in [raw,ref]:
  try:n.command('qa!')
  except Exception:pass
