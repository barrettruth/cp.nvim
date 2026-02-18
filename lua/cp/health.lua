local M = {}

local utils = require('cp.utils')

local function check()
  vim.health.start('cp.nvim [required] ~')

  utils.setup_python_env()

  if vim.fn.has('nvim-0.10.0') == 1 then
    vim.health.ok('Neovim 0.10.0+ detected')
  else
    vim.health.error('cp.nvim requires Neovim 0.10.0+')
  end

  local uname = vim.loop.os_uname()
  if uname.sysname == 'Windows_NT' then
    vim.health.error('Windows is not supported')
  end

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
end

function M.check()
  local version = require('cp.version')
  vim.health.start('cp.nvim health check ~')
  vim.health.info('Version: ' .. version.version)

  check()
end

return M
