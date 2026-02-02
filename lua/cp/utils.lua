local M = {}

local logger = require('cp.log')

local uname = vim.loop.os_uname()

local _time_cached = false
local _time_path = nil
local _time_reason = nil
local _timeout_cached = false
local _timeout_path = nil
local _timeout_reason = nil

local function is_windows()
  return uname.sysname == 'Windows_NT'
end

local function check_time_is_gnu_time(bin)
  local ok = vim.fn.executable(bin) == 1
  if not ok then
    return false
  end
  local r = vim.system({ bin, '--version' }, { text = true }):wait()
  if r and r.code == 0 and r.stdout and r.stdout:lower():find('gnu time', 1, true) then
    return true
  end
  return false
end

local function find_gnu_time()
  if _time_cached then
    return _time_path, _time_reason
  end

  if is_windows() then
    _time_cached = true
    _time_path = nil
    _time_reason = 'unsupported on Windows'
    return _time_path, _time_reason
  end

  local candidates
  if uname and uname.sysname == 'Darwin' then
    candidates = { 'gtime', '/opt/homebrew/bin/gtime', '/usr/local/bin/gtime' }
  else
    candidates = { '/usr/bin/time', 'time' }
  end

  for _, bin in ipairs(candidates) do
    if check_time_is_gnu_time(bin) then
      _time_cached = true
      _time_path = bin
      _time_reason = nil
      return _time_path, _time_reason
    end
  end

  _time_cached = true
  _time_path = nil
  _time_reason = 'GNU time not found'
  return _time_path, _time_reason
end

---@return string|nil path to GNU time binary
function M.time_path()
  local path = find_gnu_time()
  return path
end

---@return {ok:boolean, path:string|nil, reason:string|nil}
function M.time_capability()
  local path, reason = find_gnu_time()
  return { ok = path ~= nil, path = path, reason = reason }
end

---@return string
function M.get_plugin_path()
  local plugin_path = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(plugin_path, ':h:h:h')
end

local python_env_setup = false

---@return boolean success
function M.setup_python_env()
  if python_env_setup then
    return true
  end

  local plugin_path = M.get_plugin_path()
  local venv_dir = plugin_path .. '/.venv'

  if vim.fn.executable('uv') == 0 then
    logger.log(
      'uv is not installed. Install it to enable problem scraping: https://docs.astral.sh/uv/',
      vim.log.levels.WARN
    )
    return false
  end

  if vim.fn.isdirectory(venv_dir) == 0 then
    logger.log('Setting up Python environment for scrapers...')
    local env = vim.fn.environ()
    env.VIRTUAL_ENV = ''
    env.PYTHONPATH = ''
    env.CONDA_PREFIX = ''
    local result = vim
      .system({ 'uv', 'sync' }, { cwd = plugin_path, text = true, env = env })
      :wait()
    if result.code ~= 0 then
      logger.log('Failed to setup Python environment: ' .. result.stderr, vim.log.levels.ERROR)
      return false
    end
    logger.log('Python environment setup complete.')
  end

  python_env_setup = true
  return true
end

--- Configure the buffer with good defaults
---@param filetype? string
function M.create_buffer_with_options(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = buf })
  vim.api.nvim_set_option_value('readonly', true, { buf = buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  if filetype then
    vim.api.nvim_set_option_value('filetype', filetype, { buf = buf })
  end
  return buf
end

---@param bufnr integer
---@param lines string[]
---@param highlights? Highlight[]
---@param namespace? integer
function M.update_buffer_content(bufnr, lines, highlights, namespace)
  local was_readonly = vim.api.nvim_get_option_value('readonly', { buf = bufnr })

  vim.api.nvim_set_option_value('readonly', false, { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  vim.api.nvim_set_option_value('readonly', was_readonly, { buf = bufnr })

  if highlights and namespace then
    local highlight = require('cp.ui.highlight')
    highlight.apply_highlights(bufnr, highlights, namespace)
  end
end

function M.check_required_runtime()
  if is_windows() then
    return false, 'Windows is not supported'
  end

  if vim.fn.has('nvim-0.10.0') ~= 1 then
    return false, 'Neovim 0.10.0+ required'
  end

  local time = M.time_capability()
  if not time.ok then
    return false, 'GNU time not found: ' .. (time.reason or '')
  end

  local timeout = M.timeout_capability()
  if not timeout.ok then
    return false, 'GNU timeout not found: ' .. (timeout.reason or '')
  end

  if vim.fn.executable('uv') ~= 1 then
    return false, 'uv not found (https://docs.astral.sh/uv/)'
  end

  if not M.setup_python_env() then
    return false, 'failed to set up Python virtual environment'
  end

  return true
end

local function check_timeout_is_gnu_timeout(bin)
  if vim.fn.executable(bin) ~= 1 then
    return false
  end
  local r = vim.system({ bin, '--version' }, { text = true }):wait()
  if r and r.code == 0 and r.stdout then
    local s = r.stdout:lower()
    if s:find('gnu coreutils', 1, true) or s:find('timeout %(gnu coreutils%)', 1, true) then
      return true
    end
  end
  return false
end

local function find_gnu_timeout()
  if _timeout_cached then
    return _timeout_path, _timeout_reason
  end

  if is_windows() then
    _timeout_cached = true
    _timeout_path = nil
    _timeout_reason = 'unsupported on Windows'
    return _timeout_path, _timeout_reason
  end

  local candidates
  if uname and uname.sysname == 'Darwin' then
    candidates = { 'gtimeout', '/opt/homebrew/bin/gtimeout', '/usr/local/bin/gtimeout' }
  else
    candidates = { '/usr/bin/timeout', 'timeout' }
  end

  for _, bin in ipairs(candidates) do
    if check_timeout_is_gnu_timeout(bin) then
      _timeout_cached = true
      _timeout_path = bin
      _timeout_reason = nil
      return _timeout_path, _timeout_reason
    end
  end

  _timeout_cached = true
  _timeout_path = nil
  _timeout_reason = 'GNU timeout not found'
  return _timeout_path, _timeout_reason
end

function M.timeout_path()
  local path = find_gnu_timeout()
  return path
end

function M.timeout_capability()
  local path, reason = find_gnu_timeout()
  return { ok = path ~= nil, path = path, reason = reason }
end

function M.cwd_executables()
  local uv = vim.uv or vim.loop
  local req = uv.fs_scandir('.')
  if not req then
    return {}
  end
  local out = {}
  while true do
    local name, t = uv.fs_scandir_next(req)
    if not name then
      break
    end
    if t == 'file' or t == 'link' then
      local path = './' .. name
      if vim.fn.executable(path) == 1 then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out)
  return out
end

function M.ensure_dirs()
  vim.system({ 'mkdir', '-p', 'build', 'io' }):wait()
end

return M
