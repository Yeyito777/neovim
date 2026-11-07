-- Tree-sitter highlighting and indentation for every filetype with a parser.
-- The parsers are compiled into this build (cmake.deps); the queries for
-- languages Neovim doesn't ship come from nvim-treesitter and live in
-- ../../queries.
local M = {}

local pkg = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

-- Directives the vendored nvim-treesitter queries use that core doesn't
-- define. Since 0.12 a capture in `match` is a list of nodes.
local function first_node(capture)
  if type(capture) == "table" then
    return capture[1]
  end
  return capture
end

local html_script_type_languages = {
  importmap = "json",
  module = "javascript",
  ["application/ecmascript"] = "javascript",
  ["text/ecmascript"] = "javascript",
}

local function add_directives()
  local query = vim.treesitter.query

  query.add_directive("set-lang-from-mimetype!", function(match, _, source, pred, metadata)
    local node = first_node(match[pred[2]])
    if not node then
      return
    end
    local type_attr_value = vim.treesitter.get_node_text(node, source)
    local parts = vim.split(type_attr_value, "/", {})
    metadata["injection.language"] = html_script_type_languages[type_attr_value] or parts[#parts]
  end, { force = true })

  query.add_directive("downcase!", function(match, _, source, pred, metadata)
    local id = pred[2]
    local node = first_node(match[id])
    if not node then
      return
    end
    metadata[id] = metadata[id] or {}
    metadata[id].text = string.lower(vim.treesitter.get_node_text(node, source, { metadata = metadata[id] }) or "")
  end, { force = true })

  -- Textobject queries mark ranges spanning several nodes with this; the
  -- textobjects module reads it from the query's pattern info.
  query.add_directive("make-range!", function() end, { force = true })

  -- (#kind-eq? @node "type" ...): used (negated) by the indent queries.
  query.add_predicate("kind-eq?", function(match, _, _, pred)
    local node = first_node(match[pred[2]])
    if not node then
      return true
    end
    return vim.list_contains({ unpack(pred, 3) }, node:type())
  end, { force = true })
end

-- Filetypes (and Markdown fence names) whose parser has another name; the
-- ones nvim-treesitter registered for the bundled parsers.
local aliases = {
  bash = { "sh" },
  javascript = { "javascriptreact", "ecma", "jsx", "js" },
  typescript = { "ts" },
  tsx = { "typescriptreact", "typescript.tsx" },
  python = { "gyp", "py" },
  html = { "html_tags" },
  rust = { "rs" },
}

-- Compiling a query is slow for the big grammars (on the Mac, TSX's
-- highlights 185 ms and injections 177 ms, C++'s highlights 260 ms), and
-- core compiles each one the first time a buffer needs it. This fork can
-- compile them on libuv's thread pool instead (vim._ts_precompile_query);
-- vim._ts_parse_query then takes the result, waiting for it if needed.
local started = {} ---@type table<string, true>

--- Start compiling `lang`'s queries of these kinds in the background, each
--- once a session: the source must be what vim.treesitter.query.get() reads.
function M.precompile(lang, kinds)
  if not vim._ts_precompile_query then
    return
  end
  for _, kind in ipairs(kinds) do
    local key = lang .. "/" .. kind
    if not started[key] then
      started[key] = true
      local parts = {}
      for _, file in ipairs(vim.treesitter.query.get_files(lang, kind)) do
        local f = io.open(file, "r")
        if f then
          parts[#parts + 1] = f:read("*a")
          f:close()
        end
      end
      local source = table.concat(parts, "")
      if source ~= "" then
        pcall(vim._ts_precompile_query, lang, source)
      end
    end
  end
end

function M.setup()
  -- Local overrides of built-in queries (Markdown) must come before
  -- $VIMRUNTIME on the runtime path to win; see overrides/README.md.
  vim.opt.rtp:prepend(pkg .. "/overrides")

  for lang, filetypes in pairs(aliases) do
    vim.treesitter.language.register(lang, filetypes)
  end
  add_directives()

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("yeyito.treesitter", { clear = true }),
    callback = function(args)
      local lang = vim.treesitter.language.get_lang(args.match)
      -- Only languages with a parser and highlight queries; others keep regex syntax.
      if not lang or not vim.treesitter.language.add(lang) or #vim.treesitter.query.get_files(lang, "highlights") == 0 then
        return
      end
      local indents = #vim.treesitter.query.get_files(lang, "indents") > 0
      -- The parser needs the injections query first, compiled right here;
      -- the highlighter's and the first indent's meanwhile on other threads.
      M.precompile(lang, indents and { "highlights", "indents" } or { "highlights" })
      -- Core's own ftplugins already start it for lua, markdown, help, query.
      if not vim.treesitter.highlighter.active[args.buf] then
        pcall(vim.treesitter.start, args.buf, lang)
      end
      -- Tree-sitter indentation where there are indent queries (not bash).
      if indents then
        require("yeyito.ts_indent").attach(args.buf)
      end
    end,
  })
end

return M
