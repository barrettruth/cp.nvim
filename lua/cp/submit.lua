local M = {}

local logger = require('cp.log')
local state = require('cp.state')

local credentials_file = vim.fn.stdpath('data') .. '/cp-nvim-credentials.json'

local function load_credentials(platform)
  if vim.fn.filereadable(credentials_file) ~= 1 then
    return nil
  end
  local content = vim.fn.readfile(credentials_file)
  if #content == 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(content, '\n'))
  if not ok then
    return nil
  end
  return data[platform]
end

local function save_credentials(platform, creds)
  local data = {}
  if vim.fn.filereadable(credentials_file) == 1 then
    local content = vim.fn.readfile(credentials_file)
    if #content > 0 then
      local ok, decoded = pcall(vim.json.decode, table.concat(content, '\n'))
      if ok then
        data = decoded
      end
    end
  end
  data[platform] = creds
  vim.fn.mkdir(vim.fn.fnamemodify(credentials_file, ':h'), 'p')
  vim.fn.writefile({ vim.json.encode(data) }, credentials_file)
end

local function prompt_credentials(platform, callback)
  local saved = load_credentials(platform)
  if saved and saved.username and saved.password then
    callback(saved)
    return
  end
  vim.ui.input({ prompt = platform .. ' username: ' }, function(username)
    if not username or username == '' then
      logger.log('Submit cancelled', vim.log.levels.WARN)
      return
    end
    vim.fn.inputsave()
    local password = vim.fn.inputsecret(platform .. ' password: ')
    vim.fn.inputrestore()
    if not password or password == '' then
      logger.log('Submit cancelled', vim.log.levels.WARN)
      return
    end
    local creds = { username = username, password = password }
    save_credentials(platform, creds)
    callback(creds)
  end)
end

function M.submit(opts)
  local platform = state.get_platform()
  local contest_id = state.get_contest_id()
  local problem_id = state.get_problem_id()
  local language = (opts and opts.language) or state.get_language()
  if not platform or not contest_id or not problem_id or not language then
    logger.log('No active problem. Use :CP <platform> <contest> first.', vim.log.levels.ERROR)
    return
  end

  local source_file = state.get_source_file()
  if not source_file or vim.fn.filereadable(source_file) ~= 1 then
    logger.log('Source file not found', vim.log.levels.ERROR)
    return
  end

  prompt_credentials(platform, function(creds)
    local source_lines = vim.fn.readfile(source_file)
    local source_code = table.concat(source_lines, '\n')

    require('cp.scraper').submit(
      platform,
      contest_id,
      problem_id,
      language,
      source_code,
      creds,
      function(result)
        vim.schedule(function()
          if result and result.success then
            logger.log('Submitted successfully', vim.log.levels.INFO, true)
          else
            logger.log(
              'Submit failed: ' .. (result and result.error or 'unknown error'),
              vim.log.levels.ERROR
            )
          end
        end)
      end
    )
  end)
end

return M
