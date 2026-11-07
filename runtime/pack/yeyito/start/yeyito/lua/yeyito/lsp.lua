-- Language servers. Their base definitions (cmd, filetypes, root detection)
-- are servers/<name>.lua, from nvim-lspconfig; only personal settings live
-- here. (Not in an lsp/ runtime dir, which every Neovim instance would list
-- in vim.lsp.get_configs().) Servers that aren't installed are skipped
-- silently.
local M = {}

local servers = {
  pyright = {
    settings = {
      python = {
        analysis = {
          autoImportCompletions = true,
          diagnosticMode = "workspace",
        },
      },
    },
  },
  clangd = {}, -- C/C++
  ts_ls = {}, -- JS/TS
  html = {},
  cssls = {},
  rust_analyzer = {
    settings = {
      ["rust-analyzer"] = {
        cargo = {
          allFeatures = true,
        },
        checkOnSave = true,
        check = {
          command = "clippy",
        },
      },
    },
    before_init = function(init_params, config)
      -- Share the workspace's own target/ dir (root_dir is the cargo
      -- workspace root). rust-analyzer reads its settings from
      -- initializationOptions, as in nvim-lspconfig's before_init.
      local settings = config.settings["rust-analyzer"]
      settings.cargo.targetDir = (config.root_dir or vim.fn.getcwd()) .. "/target"
      init_params.initializationOptions = settings
    end,
  },
  lua_ls = {
    settings = {
      Lua = {
        diagnostics = {
          globals = { "vim" },
        },
        workspace = {
          checkThirdParty = false,
        },
      },
    },
  },
}

local function on_attach(args)
  local bufnr = args.buf
  local opts = { buffer = bufnr, noremap = true, silent = true }
  vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
  vim.keymap.set("n", "<leader>r", vim.lsp.buf.rename, opts)
  vim.keymap.set("n", "<leader>c", vim.lsp.buf.code_action, opts)
  vim.keymap.set("n", "<leader>g", vim.lsp.buf.references, opts)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("yeyito.lsp", { clear = true })
  -- vim.lsp takes a while to load (12-18 ms on the Mac), so it loads with the
  -- first file one of the servers is for, not with Neovim. Scheduled, out of
  -- that FileType event; then the servers start for the buffers already
  -- open, that one included.
  local defs, filetypes = {}, {}
  for name in pairs(servers) do
    defs[name] = require("yeyito.servers." .. name)
    vim.list_extend(filetypes, defs[name].filetypes or {})
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = filetypes,
    once = true,
    callback = vim.schedule_wrap(function()
      for name, conf in pairs(servers) do
        vim.lsp.config(name, defs[name])
        vim.lsp.config(name, conf)
      end
      vim.lsp.enable(vim.tbl_keys(servers))
      if vim.v.vim_did_enter == 0 then -- enable() leaves the open buffers to VimEnter's
        vim.cmd.doautoall("nvim.lsp.enable FileType")
      end
    end),
  })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = on_attach,
  })

  -- nvim-lspconfig's commands, as aliases of core's :lsp and :checkhealth.
  local cmd = vim.api.nvim_create_user_command
  cmd("LspInfo", "checkhealth vim.lsp", { desc = "LSP status (:checkhealth vim.lsp)" })
  cmd("LspLog", function()
    vim.cmd.tabnew(vim.lsp.log.get_filename())
  end, { desc = "Open the LSP log" })
  for name, sub in pairs({ LspStart = "enable", LspStop = "stop", LspRestart = "restart" }) do
    cmd(name, function(o)
      vim.cmd("lsp " .. sub .. " " .. o.args)
    end, { nargs = "*", desc = ":lsp " .. sub })
  end
end

return M
