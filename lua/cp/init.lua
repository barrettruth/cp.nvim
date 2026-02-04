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
    return
  end
  local user_config = vim.g.cp_config or {}
  local config = config_module.setup(user_config)
  config_module.set_current_config(config)
  initialized = true
end

---@return nil
function M.handle_command(opts)
  ensure_initialized()
  local commands = require('cp.commands')
  commands.handle_command(opts)
end

function M.is_initialized()
  return initialized
end

---@deprecated Use `vim.g.cp_config` instead
function M.setup(user_config)
  vim.deprecate('require("cp").setup()', 'vim.g.cp_config', 'v0.1.0', 'cp.nvim', false)

  if user_config then
    vim.g.cp_config = vim.tbl_deep_extend('force', vim.g.cp_config or {}, user_config)
  end
end

return M
