local M = {}

local cache = require('cp.cache')
local logger = require('cp.log')
local state = require('cp.state')

function M.login(platform)
  platform = platform or state.get_platform()
  if not platform then
    logger.log(
      'No platform specified. Usage: :CP credentials login <platform>',
      vim.log.levels.ERROR
    )
    return
  end

  vim.ui.input({ prompt = platform .. ' username: ' }, function(username)
    if not username or username == '' then
      logger.log('Cancelled', vim.log.levels.WARN)
      return
    end
    vim.fn.inputsave()
    local password = vim.fn.inputsecret(platform .. ' password: ')
    vim.fn.inputrestore()
    if not password or password == '' then
      logger.log('Cancelled', vim.log.levels.WARN)
      return
    end
    cache.load()
    cache.set_credentials(platform, { username = username, password = password })
    logger.log(platform .. ' credentials saved', vim.log.levels.INFO, true)
  end)
end

function M.logout(platform)
  platform = platform or state.get_platform()
  if not platform then
    logger.log(
      'No platform specified. Usage: :CP credentials logout <platform>',
      vim.log.levels.ERROR
    )
    return
  end
  cache.load()
  cache.clear_credentials(platform)
  logger.log(platform .. ' credentials cleared', vim.log.levels.INFO, true)
end

function M.clear()
  cache.load()
  cache.clear_credentials(nil)
  logger.log('all credentials cleared', vim.log.levels.INFO, true)
end

return M
