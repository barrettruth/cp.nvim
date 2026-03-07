local M = {}

local cache = require('cp.cache')
local config = require('cp.config')
local constants = require('cp.constants')
local logger = require('cp.log')
local state = require('cp.state')

local STATUS_MSGS = {
  installing_browser = 'Installing browser (first time setup)...',
  checking_login = 'Checking login...',
  logging_in = 'Logging in...',
  submitting = 'Submitting...',
}

local function prompt_credentials(platform, callback)
  local saved = cache.get_credentials(platform)
  if saved and saved.username and saved.password then
    callback(saved)
    return
  end
  local display = constants.PLATFORM_DISPLAY_NAMES[platform] or platform
  vim.ui.input(
    { prompt = '[cp.nvim]: ' .. display .. ' username (<Esc> to cancel): ' },
    function(username)
      if not username or username == '' then
        logger.log('Submit cancelled', { level = vim.log.levels.WARN })
        return
      end
      vim.fn.inputsave()
      local password = vim.fn.inputsecret('[cp.nvim]: ' .. display .. ' password: ')
      vim.fn.inputrestore()
      vim.cmd.redraw()
      if not password or password == '' then
        logger.log('Submit cancelled', { level = vim.log.levels.WARN })
        return
      end
      local creds = { username = username, password = password }
      cache.set_credentials(platform, creds)
      callback(creds)
    end
  )
end

---@param opts { language?: string }?
function M.submit(opts)
  local platform = state.get_platform()
  local contest_id = state.get_contest_id()
  local problem_id = state.get_problem_id()
  local language = (opts and opts.language) or state.get_language()
  if not platform or not contest_id or not problem_id or not language then
    logger.log(
      'No active problem. Use :CP <platform> <contest> first.',
      { level = vim.log.levels.ERROR }
    )
    return
  end

  local source_file = state.get_source_file()
  if not source_file then
    logger.log('Source file not found', { level = vim.log.levels.ERROR })
    return
  end
  source_file = vim.fn.fnamemodify(source_file, ':p')
  local _stat = vim.uv.fs_stat(source_file)
  if not _stat then
    logger.log('Source file not found', { level = vim.log.levels.ERROR })
    return
  end
  if _stat.size == 0 then
    logger.log('Submit aborted: source file has no content', { level = vim.log.levels.WARN })
    return
  end

  local submit_language = language
  local cfg = config.get_config()
  local plat_effective = cfg.runtime and cfg.runtime.effective and cfg.runtime.effective[platform]
  local eff = plat_effective and plat_effective[language]
  if eff then
    if eff.submit_id then
      submit_language = eff.submit_id or submit_language
    else
      local ver = eff.version or constants.DEFAULT_VERSIONS[language]
      if ver then
        local versions = (constants.LANGUAGE_VERSIONS[platform] or {})[language]
        if versions and versions[ver] then
          submit_language = versions[ver] or submit_language
        end
      end
    end
  end

  local function do_submit(creds)
    vim.cmd.update()

    require('cp.scraper').submit(
      platform,
      contest_id,
      problem_id,
      submit_language,
      source_file,
      creds,
      function(ev)
        vim.schedule(function()
          logger.log(
            STATUS_MSGS[ev.status] or ev.status,
            { level = vim.log.levels.INFO, override = true }
          )
        end)
      end,
      function(result)
        vim.schedule(function()
          if result and result.success then
            logger.log('Submitted successfully', { level = vim.log.levels.INFO, override = true })
          else
            local err = result and result.error or 'unknown error'
            if err == 'bad_credentials' or err:match('^Login failed') then
              cache.clear_credentials(platform)
              logger.log(
                'Submit failed: ' .. (constants.LOGIN_ERRORS[err] or err),
                { level = vim.log.levels.ERROR }
              )
              prompt_credentials(platform, do_submit)
            else
              logger.log(
                'Submit failed: ' .. (constants.LOGIN_ERRORS[err] or err),
                { level = vim.log.levels.ERROR }
              )
            end
          end
        end)
      end
    )
  end

  prompt_credentials(platform, do_submit)
end

return M
