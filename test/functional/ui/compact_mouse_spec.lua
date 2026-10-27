local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local clear, api, command, fn = n.clear, n.api, n.command, n.fn
local eq = t.eq

describe('compact conceal mouse geometry', function()
  local screen
  local ns

  before_each(function()
    clear()
    screen = Screen.new(30, 5)
    api.nvim_set_option_value('mouse', 'a', {})
    command('set conceallevel=2 concealcursor=')
    api.nvim_buf_set_lines(0, 0, -1, true, { 'current', 'aaHIDDENbb' })
    ns = api.nvim_create_namespace('compact-mouse')
    api.nvim_buf_set_extmark(0, ns, 1, 2, {
      end_col = 8,
      conceal = '',
      conceal_compact = true,
    })
    command('redraw')
  end)

  it('keeps the drawn geometry when the click reveals the target line', function()
    api.nvim_input_mouse('left', 'press', '', 0, 1, 2)
    eq({ 2, 8 }, api.nvim_win_get_cursor(0))
  end)

  it('getmousepos skips zero-width bytes at an exact vcol tie', function()
    api.nvim_input_mouse('move', '', '', 0, 1, 2)
    local pos = fn.getmousepos()
    eq(2, pos.line)
    eq(9, pos.column)
  end)

  it('handles a visible tab and wide character after compact conceal', function()
    api.nvim_buf_set_lines(0, 1, 2, true, { 'a\tHIDDEN界z' })
    api.nvim_buf_clear_namespace(0, ns, 0, -1)
    api.nvim_buf_set_extmark(0, ns, 1, 2, {
      end_col = 8,
      conceal = '',
      conceal_compact = true,
    })
    command('set tabstop=4')
    command('redraw')

    -- "a<Tab>界z" puts z in screen column 6 (zero-based).
    api.nvim_input_mouse('left', 'press', '', 0, 1, 6)
    eq({ 2, 11 }, api.nvim_win_get_cursor(0))
  end)

  it('uses compact rows when source-width wrapping would add a row', function()
    screen:try_resize(10, 5)
    api.nvim_buf_set_lines(0, 1, 2, true, { '12345HIDDEN67890' })
    api.nvim_buf_clear_namespace(0, ns, 0, -1)
    api.nvim_buf_set_extmark(0, ns, 1, 5, {
      end_col = 11,
      conceal = '',
      conceal_compact = true,
    })
    command('set wrap')
    command('redraw')

    -- The compact display is exactly one ten-cell row; '8' is column 7.
    api.nvim_input_mouse('left', 'press', '', 0, 1, 7)
    eq({ 2, 13 }, api.nvim_win_get_cursor(0))
  end)
end)
