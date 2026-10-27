local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local eq = t.eq

describe('ttyfast startup control', function()
  it('retains the default when the environment variable is absent', function()
    n.clear({ env = {} })
    eq(true, n.api.nvim_get_option_value('ttyfast', {}))
  end)

  it('disables ttyfast before user configuration for slow terminals', function()
    n.clear({ env = { NVIM_NOTTYFAST = '1' } })
    eq(false, n.api.nvim_get_option_value('ttyfast', {}))
    eq(1, n.fn.has('conceal_compact'))
  end)

  it('accepts any nonempty environment value', function()
    n.clear({ env = { NVIM_NOTTYFAST = 'ssh' } })
    eq(false, n.api.nvim_get_option_value('ttyfast', {}))
  end)

  it('also disables probing when the variable exists but is empty', function()
    n.clear({ env = { NVIM_NOTTYFAST = '' } })
    eq(false, n.api.nvim_get_option_value('ttyfast', {}))
  end)

  it('restores the mutable option and its short name', function()
    n.clear({ env = {} })
    n.command('set nottyfast')
    eq(false, n.api.nvim_get_option_value('ttyfast', {}))
    n.command('set tf')
    eq(true, n.api.nvim_get_option_value('ttyfast', {}))
  end)
end)
