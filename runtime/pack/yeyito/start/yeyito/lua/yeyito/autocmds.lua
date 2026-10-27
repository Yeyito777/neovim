local M = {}

local autocmd = vim.api.nvim_create_autocmd

function M.setup()
  local group = vim.api.nvim_create_augroup("yeyito", { clear = true })

  autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function()
      vim.opt_local.formatoptions:remove({ "t", "c" })
    end,
  })

  -- When pressing enter on comments do not create a new comment
  autocmd("FileType", {
    group = group,
    pattern = "*",
    callback = function()
      -- Don't continue comments when pressing <CR> or using 'o' / 'O'
      vim.opt_local.formatoptions:remove({ "r", "o" })
    end,
  })

  -- == Keep cursor position.
  local ignore_ft = { "gitcommit", "gitrebase", "help", "nofile", "quickfix", "yeyito-sidebar" }
  -- Save view (cursor, folds, scroll position, etc.) when leaving a buffer
  autocmd("BufWinLeave", {
    group = group,
    callback = function()
      if not vim.tbl_contains(ignore_ft, vim.bo.filetype) then
        vim.cmd("silent! mkview")
      end
    end,
  })
  -- Load view (restore everything) when re-entering a buffer
  autocmd("BufWinEnter", {
    group = group,
    callback = function()
      if not vim.tbl_contains(ignore_ft, vim.bo.filetype) then
        vim.cmd("silent! loadview")
      end
    end,
  })
  -- Also restore last known cursor position (based on mark `"`),
  -- in case view files don't exist yet (new files, etc.)
  autocmd("BufReadPost", {
    group = group,
    callback = function()
      local mark = vim.api.nvim_buf_get_mark(0, '"')
      local lcount = vim.api.nvim_buf_line_count(0)
      if mark[1] > 0 and mark[1] <= lcount then
        pcall(vim.api.nvim_win_set_cursor, 0, mark)
      end
    end,
  })

  -- Auto-reload files changed outside of Neovim
  autocmd({ "BufEnter", "CursorHold" }, { group = group, command = "checktime" })
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(500, 500, vim.schedule_wrap(function()
    if vim.api.nvim_get_mode().mode == "n" then
      local old_tick = vim.b.changedtick
      vim.cmd("silent! checktime")
      if vim.b.changedtick ~= old_tick then
        vim.notify("File changed on disk. Buffer reloaded.", vim.log.levels.WARN)
      end
    end
  end))
end

return M
