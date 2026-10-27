local api = vim.api
local function eq(a,b) assert(vim.deep_equal(a,b),vim.inspect(a)..' ~= '..vim.inspect(b)) end
vim.cmd.enew()
api.nvim_buf_set_name(0, '/tmp/markdown-link-tests/test.md')
local lines = {
  '[Lab](https://example.com/a_(b) "Title") and [Code](https://github.com/a/b)',
  '`[not a link](https://no.test)`',
  '```md', '[not a link](https://no.test)', '```',
  '[Reference][id] and [Short] and <https://auto.test>',
  '', '[id]: https://reference.test', '[Short]: ./local.md',
  '[Danger](https://example.com/$(touch_BAD);x)',
}
api.nvim_buf_set_lines(0,0,-1,false,lines)
vim.bo.filetype = 'markdown'
local m = require('yeyito.markdown_links')
local ns = api.nvim_get_namespaces().MarkdownLinks
local function concealed()
  local result = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(0,ns,0,-1,{details=true})) do
    if mark[4].conceal ~= nil then result[#result+1] = mark end
  end
  return result
end
eq(vim.wo.conceallevel,2)
eq(vim.wo.concealcursor,'nvic')
eq(#concealed(),4)
eq(concealed()[1][3],5) -- preserve [Lab]
local before = api.nvim_buf_get_lines(0,0,-1,false)
api.nvim_win_set_cursor(0,{1,2})
m.toggle_link(); eq(#concealed(),3)
m.toggle_link(); eq(#concealed(),4)
m.toggle_all(); eq(#concealed(),0)
m.toggle_all(); eq(#concealed(),4)
eq(before,api.nvim_buf_get_lines(0,0,-1,false))
local launches = {}
local system = vim.system
vim.system = function(argv,opts,cb)
  launches[#launches+1] = argv
  cb({code=0,stderr=''})
end
api.nvim_win_set_cursor(0,{1,2}); assert(m.open())
eq(launches[#launches],{'xdg-open','https://example.com/a_(b)'})
api.nvim_win_set_cursor(0,{6,2}); assert(m.open())
eq(launches[#launches][2],'https://reference.test')
api.nvim_win_set_cursor(0,{6,22}); assert(m.open())
eq(launches[#launches][2],'/tmp/markdown-link-tests/local.md')
api.nvim_win_set_cursor(0,{6,36}); assert(m.open())
eq(launches[#launches][2],'https://auto.test')
api.nvim_win_set_cursor(0,{10,2}); assert(m.open())
eq(launches[#launches],{'xdg-open','https://example.com/$(touch_BAD);x'})
api.nvim_win_set_cursor(0,{2,4}); assert(not m.open())
api.nvim_win_set_cursor(0,{4,4}); assert(not m.open())
vim.system = system
api.nvim_win_set_cursor(0,{1,2}); m.toggle_link()
api.nvim_buf_set_lines(0,0,0,false,{'Inserted heading',''})
m.refresh(); eq(#concealed(),3)
api.nvim_win_set_cursor(0,{3,2}); m.toggle_link(); eq(#concealed(),4)
eq(vim.fn.maparg(' me','n',false,true).desc,'Expand/collapse this Markdown link')
print('PASS: parsing, code exclusion, conceal ranges, one/all toggles, unchanged source, opener argv, relative paths, references, autolinks, edit tracking, mappings')
vim.cmd('qa!')
