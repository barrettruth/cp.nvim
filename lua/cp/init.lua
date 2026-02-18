local M = {}

local config_module = require('cp.config')
local helpers = require('cp.helpers')
local logger = require('cp.log')

M.helpers = helpers

if vim.fn.has('nvim-0.10.0') == 0 then
  logger.log('Requires nvim-0.10.0+', vim.log.levels.ERROR)
  return {}
end

local initialized = false

local function ensure_initialized()
  if initialized then
    return true
  end
  local user_config = vim.g.cp or {}
  local ok, result = pcall(config_module.setup, user_config)
  if not ok then
    local msg = tostring(result):gsub('^.+:%d+: ', '')
    vim.notify(msg, vim.log.levels.ERROR)
    return false
  end
  config_module.set_current_config(result)
  initialized = true
  return true
end

---@return nil
function M.handle_command(opts)
  if not ensure_initialized() then
    return
  end
  local commands = require('cp.commands')
  commands.handle_command(opts)
end

function M.is_initialized()
  return initialized
end

---@deprecated Use `vim.g.cp` instead
function M.setup(user_config)
  vim.deprecate('require("cp").setup()', 'vim.g.cp', 'v0.7.7', 'cp.nvim', false)

  if user_config then
    vim.g.cp = vim.tbl_deep_extend('force', vim.g.cp or {}, user_config)
  end
end

return M
