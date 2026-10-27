local M = {}

local function add_to_lines(text, line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()

  for i = line1 - 1, line2 - 1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
    if line then
      -- Find first non-blank character
      local first_nonblank = line:find("%S")
      if first_nonblank then
        -- Insert text before first non-blank
        local new_line = line:sub(1, first_nonblank - 1) .. text .. line:sub(first_nonblank)
        vim.api.nvim_buf_set_lines(bufnr, i, i + 1, false, { new_line })
      else
        -- Blank line, just leave it blank (or you could insert text if desired)
        vim.api.nvim_buf_set_lines(bufnr, i, i + 1, false, { text })
      end
    end
  end
end

-- ANSI ESCAPE COMMANDS
local function ansi_cmd(name, code)
  vim.api.nvim_create_user_command(name, function()
    vim.api.nvim_put({ "\\x1b" .. "[" .. code .. "m" }, "c", true, true)
  end, {})
end

function M.setup()
  -- :PP {text} prefixes lines (whole buffer, or a range) before the first non-blank
  vim.api.nvim_create_user_command("PP", function(opts)
    add_to_lines(opts.args, opts.line1, opts.line2)
  end, { nargs = 1, range = "%" })

  ansi_cmd("Black", "30")
  ansi_cmd("Red", "31")
  ansi_cmd("Green", "32")
  ansi_cmd("Yellow", "33")
  ansi_cmd("Blue", "34")
  ansi_cmd("Magenta", "35")
  ansi_cmd("Cyan", "36")
  ansi_cmd("White", "37")
  ansi_cmd("Bold", "1")
  ansi_cmd("Reset", "0")

  -- Cool separators:
  vim.api.nvim_create_user_command("Sep", function()
    local left  = "/* ───────────────────────────────   "
    local right = "   ─────────────────────────────────────────── */"
    local line = left .. right
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_buf_set_lines(0, row, row, false, { line })
    local col = #left
    vim.api.nvim_win_set_cursor(0, { row + 1, col })
    vim.cmd("startinsert")
  end, {})

  -- Compile the current LaTeX file, keep diagnostics if it fails, and remove
  -- auxiliary files after a successful build.
  vim.api.nvim_create_user_command("LatexBuild", function()
    local tex_file = vim.fn.expand("%:p")
    if tex_file == "" or vim.fn.fnamemodify(tex_file, ":e") ~= "tex" then
      vim.notify("LatexBuild must be run from a .tex file", vim.log.levels.ERROR, { title = "LaTeX" })
      return
    end

    vim.cmd("write")

    local tex_dir = vim.fn.fnamemodify(tex_file, ":h")
    local tex_name = vim.fn.fnamemodify(tex_file, ":t")
    local pdf_file = vim.fn.fnamemodify(tex_file, ":r") .. ".pdf"
    local build = vim.system({
      "latexmk",
      "-pdf",
      "-interaction=nonstopmode",
      "-halt-on-error",
      tex_name,
    }, { cwd = tex_dir, text = true }):wait()

    if build.code ~= 0 then
      local details = vim.trim((build.stdout or "") .. "\n" .. (build.stderr or ""))
      vim.notify(details ~= "" and details or "LaTeX build failed", vim.log.levels.ERROR, { title = "LaTeX" })
      return
    end

    local cleanup = vim.system({ "latexmk", "-c", tex_name }, {
      cwd = tex_dir,
      text = true,
    }):wait()

    if cleanup.code ~= 0 then
      vim.notify("PDF built, but auxiliary-file cleanup failed", vim.log.levels.WARN, { title = "LaTeX" })
    else
      vim.notify("Built " .. pdf_file, vim.log.levels.INFO, { title = "LaTeX" })
    end

    if vim.fn.filereadable(pdf_file) == 1 then
      vim.ui.open(pdf_file)
    end
  end, { desc = "Build LaTeX, clean auxiliaries, and open the PDF" })
end

return M
