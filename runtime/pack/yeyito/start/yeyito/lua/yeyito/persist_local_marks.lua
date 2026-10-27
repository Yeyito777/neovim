
-- lua/persist_local_marks.lua
-- Persist lowercase (file-local) marks per file across restarts.
-- No deps. Uses real Vim marks so marks.nvim renders them normally.

local M = {}

local json_path = (vim.fn.stdpath("state") .. "/localmarks.json")
local function read_db()
  local f = io.open(json_path, "r")
  if not f then return {} end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and (data or {}) or {}
end

local function write_db(db)
  vim.fn.mkdir(vim.fn.stdpath("state"), "p")
  local f = assert(io.open(json_path, "w"))
  f:write(vim.json.encode(db))
  f:close()
end

local function bufpath(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  -- Use absolute path; if empty (unnamed), skip persistence.
  if name == "" then return nil end
  return vim.loop.fs_realpath(name) or name
end

-- Save lowercase marks for one buffer
function M.save_buf(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local path = bufpath(buf); if not path then return end

  local db = read_db()
  db[path] = db[path] or {}

  -- Gather a..z marks that actually exist
  local saved = {}
  for byte = string.byte("a"), string.byte("z") do
    local m = string.char(byte)
    local pos = vim.api.nvim_buf_get_mark(buf, m)  -- {lnum, col}
    local lnum, col = pos[1], pos[2]
    if lnum ~= 0 then
      saved[m] = { lnum = lnum, col = col }
    end
  end
  if next(saved) then
    db[path] = saved
  else
    db[path] = nil -- no local marks -> clear record
  end
  write_db(db)
end

-- Restore lowercase marks for one buffer
function M.restore_buf(buf)
  local path = bufpath(buf); if not path then return end
  local db = read_db()
  local saved = db[path]; if not saved then return end
  for m, pos in pairs(saved) do
    pcall(vim.api.nvim_buf_set_mark, buf, m, pos.lnum, pos.col, {})
  end
end

-- User commands for convenience
vim.api.nvim_create_user_command("LocalMarksSave", function()
  M.save_buf(0)
end, {})
vim.api.nvim_create_user_command("LocalMarksReload", function()
  M.restore_buf(0)
end, {})
vim.api.nvim_create_user_command("LocalMarksClear", function()
  local path = bufpath(0); if not path then return end
  local db = read_db(); db[path] = nil; write_db(db)
end, {})

-- Autocommands: restore on read, save on write and on exit
local aug = vim.api.nvim_create_augroup("PersistLocalMarks", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = aug,
  callback = function(args) M.restore_buf(args.buf) end,
})
vim.api.nvim_create_autocmd("BufWritePost", {
  group = aug,
  callback = function(args) M.save_buf(args.buf) end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = aug,
  callback = function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      pcall(M.save_buf, b)
    end
  end,
})
return M
