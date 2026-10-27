-- Parsed Markdown links, display-only concealment, and shell-free opening.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('MarkdownLinks')
local expanded_ns = api.nvim_create_namespace('MarkdownLinksExpanded')
local states = {}
-- Opt into the native patch when available; stock Neovim still loads safely.
local compact = vim.fn.has('conceal_compact') == 1

local function text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

local function walk(node, callback)
  callback(node)
  for child in node:iter_children() do walk(child, callback) end
end

local function label_key(s)
  return s:gsub('^%[', ''):gsub('%]$', ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''):lower()
end

local function child_of(node, kind)
  for child in node:iter_children() do
    if child:type() == kind then return child end
  end
end

local function contains(link, row, col)
  return (row > link.sr or row == link.sr and col >= link.sc)
    and (row < link.er or row == link.er and col < link.ec)
end

local function parse(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not ok then return {} end
  parser:parse(true)
  local refs, links = {}, {}
  parser:for_each_tree(function(tree, lang)
    if lang:lang() ~= 'markdown' then return end
    walk(tree:root(), function(node)
      if node:type() ~= 'link_reference_definition' then return end
      local label, dest = child_of(node, 'link_label'), child_of(node, 'link_destination')
      if label and dest then refs[label_key(text(label, buf))] = text(dest, buf) end
    end)
  end)
  parser:for_each_tree(function(tree, lang)
    if lang:lang() ~= 'markdown_inline' then return end
    walk(tree:root(), function(node)
      local kind = node:type()
      local url, label, hide_row, hide_col
      if kind == 'inline_link' then
        local dest = child_of(node, 'link_destination')
        if dest then url = text(dest, buf) end
        label = child_of(node, 'link_text')
      elseif kind == 'full_reference_link' or kind == 'collapsed_reference_link' or kind == 'shortcut_link' then
        label = child_of(node, 'link_text')
        local ref = child_of(node, 'link_label') or label
        if ref then url = refs[label_key(text(ref, buf))] end
      elseif kind == 'uri_autolink' then
        url = text(node, buf):sub(2, -2)
      elseif kind == 'email_autolink' then
        url = 'mailto:' .. text(node, buf):sub(2, -2)
      end
      if not url then return end
      local sr, sc, er, ec = node:range()
      if label then
        -- Keep the opening/closing label brackets; hide only the suffix.
        for child in node:iter_children() do
          if child:type() == ']' then
            local _, _, r, c = child:range()
            hide_row, hide_col = r, c
            break
          end
        end
      end
      links[#links + 1] = {
        sr = sr, sc = sc, er = er, ec = ec, url = url,
        hr = hide_row, hc = hide_col,
      }
    end)
  end)
  return links
end

local function configure_window(win)
  vim.wo[win].conceallevel = 2
  -- Keep links collapsed on the cursor line too; editing is explicit.
  vim.wo[win].concealcursor = 'nvic'
end

function M.refresh(buf)
  buf = buf or api.nvim_get_current_buf()
  local state = states[buf]
  if not state or not api.nvim_buf_is_valid(buf) then return end
  local tick = api.nvim_buf_get_changedtick(buf)
  if state.tick ~= tick then
    state.links = parse(buf)
    state.tick = tick
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local expanded = api.nvim_buf_get_extmarks(buf, expanded_ns, 0, -1, {})
  for _, link in ipairs(state.links) do
    local show = state.all
    for _, mark in ipairs(expanded) do
      if contains(link, mark[2], mark[3]) then show = true end
    end
    api.nvim_buf_set_extmark(buf, ns, link.sr, link.sc, {
      end_row = link.er, end_col = link.ec, hl_group = 'MarkdownLinkText', priority = 220,
    })
    if not show and link.hr and (link.hr < link.er or link.hc < link.ec) then
      api.nvim_buf_set_extmark(buf, ns, link.hr, link.hc, {
        end_row = link.er, end_col = link.ec, conceal = '', priority = 230,
        conceal_compact = compact or nil,
      })
    end
  end
end

local function current_link()
  local buf = api.nvim_get_current_buf()
  if not states[buf] then return end
  M.refresh(buf)
  local pos = api.nvim_win_get_cursor(0)
  for _, link in ipairs(states[buf].links) do
    if contains(link, pos[1] - 1, pos[2]) then return link, buf end
  end
end

function M.open()
  local link, buf = current_link()
  if not link then return false end
  local target = link.url:gsub('^<', ''):gsub('>$', ''):gsub('\\([%p])', '%1')
  -- Decode the entities commonly used in Markdown URLs, not percent escapes.
  target = target:gsub('&amp;', '&'):gsub('&quot;', '"'):gsub('&#39;', "'")
  if target:sub(1, 1) == '#' then
    vim.notify('This is an in-document anchor, not an external link.', vim.log.levels.INFO)
    return true
  end
  if not target:match('^[%a][%w+.-]*:') then
    local name = api.nvim_buf_get_name(buf)
    local base = name ~= '' and vim.fs.dirname(name) or vim.fn.getcwd()
    target = vim.fs.normalize(target:sub(1, 1) == '/' and target or base .. '/' .. target)
  end
  -- This machine has an xdg-open compatibility wrapper; no shell interpolation.
  local opener = vim.fn.executable('xdg-open') == 1 and 'xdg-open'
    or (vim.fn.has('mac') == 1 and '/usr/bin/open' or nil)
  if not opener then
    vim.notify('No system link opener found (xdg-open).', vim.log.levels.ERROR)
    return true
  end
  local ok, err = pcall(vim.system, { opener, target }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify('Could not open link: ' .. (result.stderr or target), vim.log.levels.ERROR)
      end)
    end
  end)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  return true
end

function M.toggle_link()
  local link, buf = current_link()
  if not link then
    vim.notify('Place the cursor on a Markdown link first.')
    return
  end
  local state = states[buf]
  if state.all then
    vim.notify('All links are expanded. Use Space m a to collapse them first.')
    return
  end
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, expanded_ns, 0, -1, {})) do
    if contains(link, mark[2], mark[3]) then
      api.nvim_buf_del_extmark(buf, expanded_ns, mark[1])
      -- Move out of the soon-to-be-hidden URL.
      api.nvim_win_set_cursor(0, { link.sr + 1, link.sc })
      M.refresh(buf)
      return
    end
  end
  api.nvim_buf_set_extmark(buf, expanded_ns, link.sr, link.sc, { right_gravity = true })
  M.refresh(buf)
end

function M.toggle_all()
  local buf = api.nvim_get_current_buf()
  local state = states[buf]
  if not state then return end
  state.all = not state.all
  api.nvim_buf_clear_namespace(buf, expanded_ns, 0, -1)
  M.refresh(buf)
  vim.notify(state.all and 'Markdown links expanded' or 'Markdown links collapsed')
end

function M.enter()
  if not M.open() then vim.cmd.normal({ args = { tostring(vim.v.count1) .. '+' }, bang = true }) end
end

local function attach(buf)
  if states[buf] then return end
  states[buf] = { links = {}, all = false }
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map('<CR>', M.enter, 'Open Markdown link (otherwise normal Enter)')
  map('gx', M.open, 'Open Markdown link')
  map('<leader>me', M.toggle_link, 'Expand/collapse this Markdown link')
  map('<leader>ma', M.toggle_all, 'Expand/collapse all Markdown links')
  -- Native mouse handling resolves screen positions through concealed/wrapped text.
  map('<LeftMouse>', '<LeftMouse><Cmd>lua require("yeyito.markdown_links").open()<CR>', 'Click Markdown link')
  api.nvim_buf_create_user_command(buf, 'MarkdownLinkToggle', M.toggle_link, {})
  api.nvim_buf_create_user_command(buf, 'MarkdownLinksToggle', M.toggle_all, {})
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do configure_window(win) end
  M.refresh(buf)
end

function M.setup()
  local function highlights()
    -- Inherit the user's cyan Type color, including its 16/256-color fallback.
    local opts = api.nvim_get_hl(0, { name = 'Type', link = false })
    opts.underline = true
    api.nvim_set_hl(0, 'MarkdownLinkText', opts)
  end
  highlights()
  vim.opt.mouse = 'a'
  local group = api.nvim_create_augroup('MarkdownLinks', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
  api.nvim_create_autocmd('FileType', {
    group = group, pattern = 'markdown', callback = function(args) attach(args.buf) end,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
    group = group, callback = function(args) M.refresh(args.buf) end,
  })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group, callback = function(args)
      if states[args.buf] then configure_window(api.nvim_get_current_win()) end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group, callback = function(args) states[args.buf] = nil end,
  })
  -- Also supports loading this module into an already-open Markdown buffer.
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'markdown' then attach(buf) end
  end
end

return M
