local M = {}

local utils = require('cp.utils')

local function check()
  vim.health.start('cp.nvim [required] ~')

  local nvim_ver = vim.version()
  local nvim_str = ('%d.%d.%d'):format(nvim_ver.major, nvim_ver.minor, nvim_ver.patch)
  if vim.fn.has('nvim-0.10.0') == 1 then
    vim.health.ok('Neovim >= 0.10.0: ' .. nvim_str)
  else
    vim.health.error('Neovim >= 0.10.0 required, found ' .. nvim_str)
  end

  local uname = vim.uv.os_uname()
  if uname.sysname == 'Windows_NT' then
    vim.health.error('Windows is not supported')
  end

  local time_cap = utils.time_capability()
  if time_cap.ok then
    vim.health.ok('GNU time found: ' .. time_cap.path)
  else
    vim.health.error('GNU time not found: ' .. (time_cap.reason or ''))
  end

  local timeout_cap = utils.timeout_capability()
  if timeout_cap.ok then
    vim.health.ok('GNU timeout found: ' .. timeout_cap.path)
  else
    vim.health.error('GNU timeout not found: ' .. (timeout_cap.reason or ''))
  end

  vim.health.start('cp.nvim [optional] ~')

  utils.setup_python_env()

  if utils.is_nix_build() then
    local source = utils.is_nix_discovered() and 'runtime discovery' or 'flake install'
    vim.health.ok('Nix Python environment detected (' .. source .. ')')
    local py = utils.get_nix_python()
    vim.health.info('Python: ' .. py)
    local r = vim.system({ py, '--version' }, { text = true }):wait()
    if r.code == 0 then
      vim.health.info('Python version: ' .. r.stdout:gsub('\n', ''))
    end
  else
    if vim.fn.executable('uv') == 1 then
      vim.health.ok('uv executable found')
      local r = vim.system({ 'uv', '--version' }, { text = true }):wait()
      if r.code == 0 then
        vim.health.info('uv version: ' .. r.stdout:gsub('\n', ''))
      end
    else
      vim.health.warn('uv not found (install https://docs.astral.sh/uv/ for scraping)')
    end

    if vim.fn.executable('nix') == 1 then
      vim.health.info('nix available but Python environment not resolved via nix')
    end

    local plugin_path = utils.get_plugin_path()
    local venv_dir = plugin_path .. '/.venv'
    if vim.fn.isdirectory(venv_dir) == 1 then
      vim.health.ok('Python virtual environment found at ' .. venv_dir)
    else
      vim.health.info('Python virtual environment not set up (created on first scrape)')
    end
  end

  if vim.fn.executable('git') == 1 then
    local r = vim.system({ 'git', '--version' }, { text = true }):wait()
    if r.code == 0 then
      local major, minor, patch = r.stdout:match('(%d+)%.(%d+)%.(%d+)')
      major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch or 0)
      local ver_str = ('%d.%d.%d'):format(major or 0, minor or 0, patch or 0)
      if
        major
        and (major > 1 or (major == 1 and minor > 7) or (major == 1 and minor == 7 and patch >= 9))
      then
        vim.health.ok('git >= 1.7.9: ' .. ver_str)
      else
        vim.health.warn('git >= 1.7.9 required for credential storage, found ' .. ver_str)
      end
    end
  else
    vim.health.warn('git not found (required for credential storage)')
  end
end

---@return nil
function M.check()
  local version = require('cp.version')
  vim.health.start('cp.nvim health check ~')
  vim.health.info('Version: ' .. version.version)

  check()
end

return M
