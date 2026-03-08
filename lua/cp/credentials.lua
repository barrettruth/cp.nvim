local M = {}

local cache = require('cp.cache')
local constants = require('cp.constants')
local logger = require('cp.log')
local state = require('cp.state')

local STATUS_MESSAGES = {
  checking_login = 'Checking existing session...',
  logging_in = 'Logging in...',
  installing_browser = 'Installing browser...',
}

---@param platform string
---@param display string
local function prompt_and_login(platform, display)
  vim.ui.input(
    { prompt = '[cp.nvim]: ' .. display .. ' username (<Esc> to cancel): ' },
    function(username)
      if not username or username == '' then
        logger.log(display .. ' login cancelled', { level = vim.log.levels.WARN })
        return
      end
      vim.fn.inputsave()
      local password = vim.fn.inputsecret('[cp.nvim]: ' .. display .. ' password: ')
      vim.fn.inputrestore()
      if not password or password == '' then
        logger.log(display .. ' login cancelled', { level = vim.log.levels.WARN })
        return
      end

      local credentials = { username = username, password = password }

      local scraper = require('cp.scraper')
      scraper.login(platform, credentials, function(ev)
        vim.schedule(function()
          local msg = STATUS_MESSAGES[ev.status] or ev.status
          logger.log(display .. ': ' .. msg, { level = vim.log.levels.INFO, override = true })
        end)
      end, function(result)
        vim.schedule(function()
          if result.success then
            cache.set_credentials(platform, credentials)
            logger.log(
              display .. ' login successful',
              { level = vim.log.levels.INFO, override = true }
            )
          else
            local err = result.error or 'unknown error'
            cache.clear_credentials(platform)
            logger.log(
              display .. ' login failed: ' .. (constants.LOGIN_ERRORS[err] or err),
              { level = vim.log.levels.ERROR }
            )
            prompt_and_login(platform, display)
          end
        end)
      end)
    end
  )
end

---@param platform string?
function M.login(platform)
  platform = platform or state.get_platform()
  if not platform then
    logger.log(
      'No platform specified. Usage: :CP <platform> login',
      { level = vim.log.levels.ERROR }
    )
    return
  end

  local display = constants.PLATFORM_DISPLAY_NAMES[platform] or platform

  cache.load()
  local existing = cache.get_credentials(platform) or {}

  if existing.username and existing.password then
    local scraper = require('cp.scraper')
    scraper.login(platform, existing, function(ev)
      vim.schedule(function()
        local msg = STATUS_MESSAGES[ev.status] or ev.status
        logger.log(display .. ': ' .. msg, { level = vim.log.levels.INFO, override = true })
      end)
    end, function(result)
      vim.schedule(function()
        if result.success then
          logger.log(
            display .. ' login successful',
            { level = vim.log.levels.INFO, override = true }
          )
        else
          cache.clear_credentials(platform)
          prompt_and_login(platform, display)
        end
      end)
    end)
    return
  end

  prompt_and_login(platform, display)
end

---@param platform string?
function M.logout(platform)
  platform = platform or state.get_platform()
  if not platform then
    logger.log(
      'No platform specified. Usage: :CP <platform> logout',
      { level = vim.log.levels.ERROR }
    )
    return
  end
  local display = constants.PLATFORM_DISPLAY_NAMES[platform] or platform
  cache.load()
  cache.clear_credentials(platform)
  local cookie_file = constants.COOKIE_FILE
  if vim.fn.filereadable(cookie_file) == 1 then
    local ok, data = pcall(vim.fn.json_decode, vim.fn.readfile(cookie_file, 'b'))
    if ok and type(data) == 'table' then
      data[platform] = nil
      local tmpfile = vim.fn.tempname()
      vim.fn.writefile({ vim.fn.json_encode(data) }, tmpfile)
      vim.fn.setfperm(tmpfile, 'rw-------')
      vim.uv.fs_rename(tmpfile, cookie_file)
    end
  end
  logger.log(display .. ' credentials cleared', { level = vim.log.levels.INFO, override = true })
end

return M
