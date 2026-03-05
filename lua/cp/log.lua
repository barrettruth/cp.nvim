local M = {}

---@class LogOpts
---@field level? integer
---@field override? boolean
---@field sync? boolean

---@param msg string
---@param opts? LogOpts
function M.log(msg, opts)
  local debug = require('cp.config').get_config().debug or false
  opts = opts or {}
  local level = opts.level or vim.log.levels.INFO
  local override = opts.override or false
  local sync = opts.sync or false
  if level >= vim.log.levels.WARN or override or debug then
    local notify = function()
      vim.notify(('[cp.nvim]: %s'):format(msg), level)
    end
    if sync then
      notify()
    else
      vim.schedule(notify)
    end
  end
end

return M
