local M = {}

local cache = require('cp.cache')
local logger = require('cp.log')
local state = require('cp.state')

function M.login(platform)
  platform = platform or state.get_platform()
  if not platform then
    logger.log(
      'No platform specified. Usage: :CP login <platform>',
      { level = vim.log.levels.ERROR }
    )
    return
  end

  vim.ui.input({ prompt = platform .. ' username: ' }, function(username)
    if not username or username == '' then
      logger.log('Cancelled', { level = vim.log.levels.WARN })
      return
    end
    vim.fn.inputsave()
    local password = vim.fn.inputsecret(platform .. ' password: ')
    vim.fn.inputrestore()
    if not password or password == '' then
      logger.log('Cancelled', { level = vim.log.levels.WARN })
      return
    end
    cache.load()
    cache.set_credentials(platform, { username = username, password = password })
    logger.log(platform .. ' credentials saved', { level = vim.log.levels.INFO, override = true })
  end)
end

function M.logout(platform)
  platform = platform or state.get_platform()
  if not platform then
    logger.log(
      'No platform specified. Usage: :CP logout <platform>',
      { level = vim.log.levels.ERROR }
    )
    return
  end
  cache.load()
  cache.clear_credentials(platform)
  logger.log(platform .. ' credentials cleared', { level = vim.log.levels.INFO, override = true })
end

return M
