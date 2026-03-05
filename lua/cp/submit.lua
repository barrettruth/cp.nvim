local M = {}

local cache = require('cp.cache')
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
  vim.ui.input({ prompt = platform .. ' username: ' }, function(username)
    if not username or username == '' then
      logger.log('Submit cancelled', { level = vim.log.levels.WARN })
      return
    end
    vim.fn.inputsave()
    local password = vim.fn.inputsecret(platform .. ' password: ')
    vim.fn.inputrestore()
    vim.cmd.redraw()
    if not password or password == '' then
      logger.log('Submit cancelled', { level = vim.log.levels.WARN })
      return
    end
    local creds = { username = username, password = password }
    cache.set_credentials(platform, creds)
    callback(creds)
  end)
end

function M.submit(opts)
  local platform = state.get_platform()
  local contest_id = state.get_contest_id()
  local problem_id = state.get_problem_id()
  local language = (opts and opts.language) or state.get_language()
  if not platform or not contest_id or not problem_id or not language then
    logger.log('No active problem. Use :CP <platform> <contest> first.', { level = vim.log.levels.ERROR })
    return
  end

  local source_file = state.get_source_file()
  if not source_file or vim.fn.filereadable(source_file) ~= 1 then
    logger.log('Source file not found', { level = vim.log.levels.ERROR })
    return
  end

  prompt_credentials(platform, function(creds)
    local source_lines = vim.fn.readfile(source_file)
    local source_code = table.concat(source_lines, '\n')

    vim.notify('[cp.nvim] Submitting...', vim.log.levels.INFO)

    require('cp.scraper').submit(
      platform,
      contest_id,
      problem_id,
      language,
      source_code,
      creds,
      function(ev)
        vim.schedule(function()
          vim.notify('[cp.nvim] ' .. (STATUS_MSGS[ev.status] or ev.status), vim.log.levels.INFO)
        end)
      end,
      function(result)
        vim.schedule(function()
          if result and result.success then
            logger.log('Submitted successfully', { level = vim.log.levels.INFO, override = true })
          else
            logger.log(
              'Submit failed: ' .. (result and result.error or 'unknown error'),
              { level = vim.log.levels.ERROR }
            )
          end
        end)
      end
    )
  end)
end

return M
