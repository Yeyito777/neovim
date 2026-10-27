-- Language servers. Their base definitions (cmd, filetypes, root detection)
-- are in ../../lsp/<name>.lua, which vim.lsp.config picks up from the
-- runtime path; only personal settings live here. Servers that aren't
-- installed are skipped silently.
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
  vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
  vim.keymap.set("n", "<leader>r", vim.lsp.buf.rename, opts)
  vim.keymap.set("n", "<leader>c", vim.lsp.buf.code_action, opts)
  vim.keymap.set("n", "<leader>g", vim.lsp.buf.references, opts)
end

function M.setup()
  for name, conf in pairs(servers) do
    vim.lsp.config(name, conf)
  end
  vim.lsp.enable(vim.tbl_keys(servers))

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("yeyito.lsp", { clear = true }),
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
