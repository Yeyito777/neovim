-- Parsed Markdown links, display-only concealment, and shell-free opening.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('MarkdownLinks')
local expanded_ns = api.nvim_create_namespace('MarkdownLinksExpanded')
local states = {}
local edits = require('yeyito.markdown_refresh') -- which rows changed
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

local refs_query
local refs_ns = api.nvim_create_namespace('MarkdownLinksRefs')

-- Reference definitions ([id]: url) in rows first..last (all of them
-- without), as nodes.
local function definitions(parser, first, last)
  refs_query = refs_query or vim.treesitter.query.parse('markdown', '(link_reference_definition) @def')
  local defs = {}
  parser:for_each_tree(function(tree, lang)
    if lang:lang() ~= 'markdown' then return end
    for _, node in refs_query:iter_captures(tree:root(), parser:source(), first, last and last + 1) do
      defs[#defs + 1] = node
    end
  end)
  return defs
end

-- All the reference definitions, by label. Each is marked, so an edit that
-- removes one is seen.
local function references(buf, parser)
  local refs = {}
  api.nvim_buf_clear_namespace(buf, refs_ns, 0, -1)
  for _, node in ipairs(definitions(parser)) do
    local label, dest = child_of(node, 'link_label'), child_of(node, 'link_destination')
    if label and dest then refs[label_key(text(label, buf))] = text(dest, buf) end
    local row = node:range()
    api.nvim_buf_set_extmark(buf, refs_ns, row, 0, {})
  end
  return refs
end

-- The links in the inline trees that reach rows first..last (all of them
-- without), and the rows those trees cover.
local function parse(buf, parser, refs, first, last)
  local links = {}
  local from, to = first, last
  parser:for_each_tree(function(tree, lang)
    if lang:lang() ~= 'markdown_inline' then return end
    local root = tree:root()
    if first then
      local sr, _, er = root:range()
      if sr > last or er < first then return end
      from, to = math.min(from, sr), math.max(to, er)
    end
    walk(root, function(node)
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
  return links, from, to
end

local function configure_window(win)
  vim.wo[win].conceallevel = 2
  -- Keep links collapsed on the cursor line too; editing is explicit.
  vim.wo[win].concealcursor = 'nvic'
end

local function draw(buf, state, links)
  local expanded = api.nvim_buf_get_extmarks(buf, expanded_ns, 0, -1, {})
  for _, link in ipairs(links) do
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

-- The rows windows show this buffer in, as the highlighter parses them (its
-- _on_start), and `span`'s: parsing just these, it finds them parsed. A
-- partial parse drops the regions outside it, so with only `span` every key
-- would reparse the whole view.
local function with_views(buf, span)
  local ranges = span and { { span[1], span[2] + 1 } } or {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == buf then
      ranges[#ranges + 1] = { vim.fn.line('w0', win) - 1, vim.fn.line('w$', win) + 1 }
    end
  end
  if #ranges == 0 then return nil end
  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  -- Overlapping ranges would find a region twice, and a different number of
  -- regions drops them all.
  local merged = { ranges[1] }
  for i = 2, #ranges do
    local last, r = merged[#merged], ranges[i]
    if r[1] <= last[2] then
      last[2] = math.max(last[2], r[2])
    else
      merged[#merged + 1] = r
    end
  end
  return merged
end

-- Rows whose links aren't marked yet (`state.todo`, {first, last} pairs):
-- links are marked as they come into view, since parsing a long draft's
-- every paragraph costs ~100 ms. Edits move them.
local function shift(todo, row, old_rows, new_rows)
  local delta = new_rows - old_rows
  for _, r in ipairs(todo) do
    if row < r[1] then
      r[1], r[2] = math.max(row, r[1] + delta), math.max(row, r[2] + delta)
    elseif row <= r[2] then
      r[2] = math.max(r[1], r[2] + delta, row + new_rows)
    end
  end
end

local function done(todo, from, to)
  local left = {}
  for _, r in ipairs(todo) do
    if r[2] < from or r[1] > to then
      left[#left + 1] = r
    else
      if r[1] < from then left[#left + 1] = { r[1], from - 1 } end
      if r[2] > to then left[#left + 1] = { to + 1, r[2] } end
    end
  end
  return left
end

-- Mark the links in the (parsed) paragraphs reaching rows first..last again.
local function mark_rows(buf, state, parser, first, last)
  local links, from, to = parse(buf, parser, state.refs, first, last)
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { from, 0 }, { to, -1 }, {})) do
    api.nvim_buf_del_extmark(buf, ns, mark[1])
  end
  draw(buf, state, links)
  state.todo = done(state.todo, from, to)
end

-- Mark what windows show that isn't marked yet.
local function show(buf, parser)
  local state = states[buf]
  local views = state and #state.todo > 0 and with_views(buf)
  if not views then return end
  local rows = {}
  for _, v in ipairs(views) do
    for _, r in ipairs(state.todo) do
      local a, b = math.max(v[1], r[1]), math.min(v[2], r[2])
      if a <= b then rows[#rows + 1] = { a, b } end
    end
  end
  if #rows == 0 then return end
  if not parser then
    local ok
    ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if not ok then return end
  end
  parser:parse(views)
  for _, r in ipairs(rows) do
    mark_rows(buf, state, parser, r[1], r[2])
  end
end

-- Marks the links. After an edit, only the paragraphs it touched are parsed
-- and marked again (the other marks moved with the text): all of them cost
-- ~10 ms a key in a long draft. `full`: every link (a toggle changed them).
function M.refresh(buf, full)
  buf = buf or api.nvim_get_current_buf()
  local state = states[buf]
  if not state or not api.nvim_buf_is_valid(buf) then return end
  local tick = api.nvim_buf_get_changedtick(buf)
  if state.tick == tick and not full then
    edits.take(buf, 'links')
    return
  end
  state.tick = tick
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not ok then return end
  -- Parsing tells which rows the block structure changed in (they're
  -- added to the span): parse those too.
  local span = edits.take(buf, 'links', true)
  parser:parse(with_views(buf, span) or { { 0, 1 } })
  while span do
    local grown = edits.take(buf, 'links', true)
    if grown[1] >= span[1] and grown[2] <= span[2] then break end
    span = grown
    parser:parse(with_views(buf, span))
  end
  span = not full and edits.take(buf, 'links') or nil
  local refs = state.refs
  if not span
    or #api.nvim_buf_get_extmarks(buf, refs_ns, { span[1], 0 }, { span[2], -1 }, { limit = 1 }) > 0
    or #definitions(parser, span[1], span[2]) > 0
  then
    -- A definition was or is among the rows edited.
    refs = references(buf, parser)
  end
  if span and vim.deep_equal(refs, state.refs) then
    mark_rows(buf, state, parser, span[1], span[2])
  else
    state.refs = refs
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    state.todo = { { 0, api.nvim_buf_line_count(buf) - 1 } }
  end
  show(buf, parser)
end

-- The links on a row (one in view: parsed with the view's).
local function links_at(buf, row)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not ok then return {} end
  parser:parse(with_views(buf, { row, row }))
  return (parse(buf, parser, states[buf].refs, row, row))
end

local function current_link()
  local buf = api.nvim_get_current_buf()
  if not states[buf] then return end
  M.refresh(buf)
  local pos = api.nvim_win_get_cursor(0)
  for _, link in ipairs(links_at(buf, pos[1] - 1)) do
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
      M.refresh(buf, true)
      return
    end
  end
  api.nvim_buf_set_extmark(buf, expanded_ns, link.sr, link.sc, { right_gravity = true })
  M.refresh(buf, true)
end

function M.toggle_all()
  local buf = api.nvim_get_current_buf()
  local state = states[buf]
  if not state then return end
  state.all = not state.all
  api.nvim_buf_clear_namespace(buf, expanded_ns, 0, -1)
  M.refresh(buf, true)
  vim.notify(state.all and 'Markdown links expanded' or 'Markdown links collapsed')
end

function M.enter()
  if not M.open() then vim.cmd.normal({ args = { tostring(vim.v.count1) .. '+' }, bang = true }) end
end

local function attach(buf)
  if states[buf] then return end
  states[buf] = { all = false, todo = {} }
  edits.track(buf)
  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, b, _, row, _, _, old_rows, _, _, new_rows)
      if not states[b] then return true end
      shift(states[b].todo, row, old_rows, new_rows)
    end,
  })
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
      if states[args.buf] then
        configure_window(api.nvim_get_current_win())
        show(args.buf)
      end
    end,
  })
  -- Before the redraw, so what comes into view is drawn with its links.
  api.nvim_create_autocmd({ 'WinScrolled', 'WinResized' }, {
    group = group, callback = function()
      for id in pairs(vim.v.event) do
        local win = tonumber(id)
        if win and api.nvim_win_is_valid(win) then
          local buf = api.nvim_win_get_buf(win)
          if states[buf] then show(buf) end
        end
      end
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
