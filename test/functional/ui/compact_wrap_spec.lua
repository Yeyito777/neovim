local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')
local api, command, eq = n.api, n.command, t.eq

describe('compact conceal wrapping', function()
  local screen, ns
  before_each(function()
    n.clear()
    screen = Screen.new(20, 8)
    command('set conceallevel=2 concealcursor=nvic noshowmode noruler laststatus=0')
    ns = api.nvim_create_namespace('compact-wrap')
  end)

  local function put(line, first, last)
    api.nvim_buf_set_lines(0, 0, -1, true, { line, 'NEXT' })
    return api.nvim_buf_set_extmark(0, ns, 0, first, {
      end_col = last, conceal = '', conceal_compact = true,
    })
  end

  local function height()
    command('redraw!')
    return api.nvim_win_text_height(0, { start_row = 0, end_row = 0 }).all
  end

  local function row(number)
    command('redraw!')
    return n.exec_lua([[
      local s = ''
      for c = 1, vim.o.columns do s = s .. vim.fn.screenstring(..., c) end
      return s
    ]], number)
  end

  it('does not wrap a hidden URL or add an empty row at an exact margin', function()
    put(string.rep('a', 20) .. string.rep('x', 400), 20, 420)
    eq(1, height())
    eq(string.rep('a', 20), row(1))
    eq('NEXT' .. string.rep(' ', 16), row(2))
  end)

  it('invalidates heights when toggled, including removing the last mark', function()
    local id = put('start' .. string.rep('x', 100) .. 'end', 5, 105)
    eq(1, height())
    api.nvim_buf_del_extmark(0, ns, id)
    eq(6, height())
    api.nvim_buf_set_extmark(0, ns, 0, 5, {
      end_col = 105, conceal = '', conceal_compact = true,
    })
    eq(1, height())
    api.nvim_buf_clear_namespace(0, ns, 0, -1)
    eq(6, height())
  end)

  it('linebreak looks through hidden whitespace to the visible next word', function()
    command('set linebreak')
    put('label ' .. '\tHIDDEN' .. string.rep('a', 21), 6, 13)
    eq('label' .. string.rep(' ', 15), row(1))
    eq(string.rep('a', 20), row(2))
    eq('a' .. string.rep(' ', 19), row(3))
  end)

  it('keeps zero-width TAB and Unicode cursor boundaries monotonic', function()
    local hidden = '\t界🤖'
    put('aa' .. hidden .. 'bb', 2, 2 + #hidden)
    local first = n.fn.screenpos(api.nvim_get_current_win(), 1, 3)
    eq(first.col, first.curscol)
    eq(first.col, first.endcol)
    eq('aabb' .. string.rep(' ', 16), row(1))
  end)

  it('leaves legacy conceal wrapping and buffer source untouched', function()
    local line = 'hello' .. string.rep('x', 100) .. 'end'
    put(line, 5, 105)
    eq({ line, 'NEXT' }, api.nvim_buf_get_lines(0, 0, -1, true))
    api.nvim_buf_clear_namespace(0, ns, 0, -1)
    api.nvim_buf_set_extmark(0, ns, 0, 5, { end_col = 105, conceal = '' })
    eq(6, height())
  end)

  it('validates the opt-in API and reports capability', function()
    eq(1, n.fn.has('conceal_compact'))
    local ok = n.exec_lua([[
      return pcall(vim.api.nvim_buf_set_extmark, 0, ..., 0, 0,
        { conceal = '', conceal_compact = true })
    ]], ns)
    eq(false, ok)
  end)
end)
