local M = {}

local constants = require('cp.constants')
local logger = require('cp.log')
local utils = require('cp.utils')

local function syshandle(result)
  local ok, data = pcall(vim.json.decode, result.stdout or '')
  if ok then
    return { success = true, data = data }
  end

  if result.code ~= 0 then
    local msg = 'Scraper failed: ' .. (result.stderr or 'Unknown error')
    return { success = false, error = msg }
  end

  local msg = 'Failed to parse scraper output: ' .. tostring(data)
  logger.log(msg, vim.log.levels.ERROR)
  return { success = false, error = msg }
end

---@param env_map table<string, string>
---@return string[]
local function spawn_env_list(env_map)
  local out = {}
  for key, value in pairs(env_map) do
    out[#out + 1] = tostring(key) .. '=' .. tostring(value)
  end
  return out
end

---@param platform string
---@param subcommand string
---@param args string[]
---@param opts { sync?: boolean, ndjson?: boolean, on_event?: fun(ev: table), on_exit?: fun(result: table), env_extra?: table<string, string>, stdin?: string }
local function run_scraper(platform, subcommand, args, opts)
  if not utils.setup_python_env() then
    local msg = 'no Python environment available (install uv or nix)'
    logger.log(msg, vim.log.levels.ERROR)
    if opts and opts.on_exit then
      opts.on_exit({ success = false, error = msg })
    end
    return { success = false, error = msg }
  end

  if subcommand == 'submit' then
    utils.setup_nix_submit_env()
  end

  local plugin_path = utils.get_plugin_path()
  local cmd
  if subcommand == 'submit' then
    cmd = utils.get_python_submit_cmd(platform, plugin_path)
  else
    cmd = utils.get_python_cmd(platform, plugin_path)
  end
  vim.list_extend(cmd, { subcommand })
  vim.list_extend(cmd, args)

  logger.log('scraper cmd: ' .. table.concat(cmd, ' '))

  local env = vim.fn.environ()
  env.VIRTUAL_ENV = ''
  env.PYTHONPATH = ''
  env.CONDA_PREFIX = ''

  if opts and opts.env_extra then
    for k, v in pairs(opts.env_extra) do
      env[k] = v
    end
  end

  if subcommand == 'submit' and utils.is_nix_build() then
    env.UV_PROJECT_ENVIRONMENT = vim.fn.stdpath('cache') .. '/cp-nvim/submit-env'
  end

  if opts and opts.ndjson then
    local uv = vim.uv
    local stdin_pipe = nil
    if opts.stdin then
      stdin_pipe = uv.new_pipe(false)
    end
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    local buf = ''

    local handle
    handle = uv.spawn(cmd[1], {
      args = vim.list_slice(cmd, 2),
      stdio = { stdin_pipe, stdout, stderr },
      env = spawn_env_list(env),
      cwd = plugin_path,
    }, function(code, signal)
      if buf ~= '' and opts.on_event then
        local ok_tail, ev_tail = pcall(vim.json.decode, buf)
        if ok_tail then
          opts.on_event(ev_tail)
        end
        buf = ''
      end
      if opts.on_exit then
        opts.on_exit({ success = (code == 0), code = code, signal = signal })
      end
      if stdin_pipe and not stdin_pipe:is_closing() then
        stdin_pipe:close()
      end
      if not stdout:is_closing() then
        stdout:close()
      end
      if not stderr:is_closing() then
        stderr:close()
      end
      if handle and not handle:is_closing() then
        handle:close()
      end
    end)

    if not handle then
      if stdin_pipe and not stdin_pipe:is_closing() then
        stdin_pipe:close()
      end
      logger.log('Failed to start scraper process', vim.log.levels.ERROR)
      return { success = false, error = 'spawn failed' }
    end

    if stdin_pipe then
      uv.write(stdin_pipe, opts.stdin, function()
        uv.shutdown(stdin_pipe, function()
          stdin_pipe:close()
        end)
      end)
    end

    uv.read_start(stdout, function(_, data)
      if data == nil then
        if buf ~= '' and opts.on_event then
          local ok_tail, ev_tail = pcall(vim.json.decode, buf)
          if ok_tail then
            opts.on_event(ev_tail)
          end
          buf = ''
        end
        return
      end
      buf = buf .. data
      while true do
        local s, e = buf:find('\n', 1, true)
        if not s then
          break
        end
        local line = buf:sub(1, s - 1)
        buf = buf:sub(e + 1)
        local ok, ev = pcall(vim.json.decode, line)
        if ok and opts.on_event then
          opts.on_event(ev)
        end
      end
    end)

    uv.read_start(stderr, function(_, _) end)
    return
  end

  local sysopts = {
    text = true,
    timeout = (subcommand == 'submit') and 120000 or 30000,
    env = env,
    cwd = plugin_path,
  }
  if opts and opts.stdin then
    sysopts.stdin = opts.stdin
  end
  if opts and opts.sync then
    local result = vim.system(cmd, sysopts):wait()
    return syshandle(result)
  else
    vim.system(cmd, sysopts, function(result)
      if opts and opts.on_exit then
        return opts.on_exit(syshandle(result))
      end
    end)
  end
end

function M.scrape_contest_metadata(platform, contest_id, callback)
  run_scraper(platform, 'metadata', { contest_id }, {
    on_exit = function(result)
      if not result or not result.success then
        logger.log(
          ("Failed to scrape metadata for %s contest '%s'."):format(
            constants.PLATFORM_DISPLAY_NAMES[platform],
            contest_id
          ),
          vim.log.levels.ERROR
        )
        return
      end
      local data = result.data or {}
      if not data.problems or #data.problems == 0 then
        logger.log(
          ("No problems returned for %s contest '%s'."):format(
            constants.PLATFORM_DISPLAY_NAMES[platform],
            contest_id
          ),
          vim.log.levels.ERROR
        )
        return
      end
      if type(callback) == 'function' then
        callback(data)
      end
    end,
  })
end

function M.scrape_contest_list(platform)
  local result = run_scraper(platform, 'contests', {}, { sync = true })
  if not result or not result.success or not (result.data and result.data.contests) then
    logger.log(
      ('Could not scrape contests list for platform %s: %s'):format(
        platform,
        (result and result.error) or 'unknown'
      ),
      vim.log.levels.ERROR
    )
    return {}
  end
  return result.data.contests
end

---@param platform string
---@param contest_id string
---@param callback fun(data: table)|nil
function M.scrape_all_tests(platform, contest_id, callback)
  run_scraper(platform, 'tests', { contest_id }, {
    ndjson = true,
    on_event = function(ev)
      if ev.done then
        return
      end
      if ev.error and ev.problem_id then
        logger.log(
          ("Failed to load tests for problem '%s' in contest '%s': %s"):format(
            ev.problem_id,
            contest_id,
            ev.error
          ),
          vim.log.levels.WARN
        )
        return
      end
      if not ev.problem_id or not ev.tests then
        return
      end
      vim.schedule(function()
        require('cp.utils').ensure_dirs()
        local config = require('cp.config')
        local base_name = config.default_filename(contest_id, ev.problem_id)
        for i, t in ipairs(ev.tests) do
          local input_file = 'io/' .. base_name .. '.' .. i .. '.cpin'
          local expected_file = 'io/' .. base_name .. '.' .. i .. '.cpout'
          local input_content = t.input:gsub('\r', '')
          local expected_content = t.expected:gsub('\r', '')
          vim.fn.writefile(vim.split(input_content, '\n'), input_file)
          vim.fn.writefile(vim.split(expected_content, '\n'), expected_file)
        end
        if type(callback) == 'function' then
          callback({
            combined = ev.combined,
            tests = ev.tests,
            timeout_ms = ev.timeout_ms or 0,
            memory_mb = ev.memory_mb or 0,
            interactive = ev.interactive or false,
            multi_test = ev.multi_test or false,
            precision = ev.precision ~= vim.NIL and ev.precision or nil,
            problem_id = ev.problem_id,
          })
        end
      end)
    end,
  })
end

function M.submit(
  platform,
  contest_id,
  problem_id,
  language,
  source_code,
  credentials,
  on_status,
  callback
)
  local done = false
  run_scraper(platform, 'submit', { contest_id, problem_id, language }, {
    ndjson = true,
    stdin = source_code,
    env_extra = { CP_CREDENTIALS = vim.json.encode(credentials) },
    on_event = function(ev)
      if ev.status ~= nil then
        if type(on_status) == 'function' then
          on_status(ev.status)
        end
      elseif ev.success ~= nil then
        done = true
        if type(callback) == 'function' then
          callback(ev)
        end
      end
    end,
    on_exit = function(proc)
      if not done and type(callback) == 'function' then
        callback({
          success = false,
          error = 'submit process exited (code=' .. tostring(proc.code) .. ')',
        })
      end
    end,
  })
end

return M
