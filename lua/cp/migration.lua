local M = {}

local marker_name = 'github-source-migration-v1'
local forgejo_url = 'https://git.barrettruth.com/barrettruth/cp.nvim'
local migration_help = ':help cp.nvim-migration'

---@return string|nil
local function plugin_root()
  local source = debug.getinfo(1, 'S').source
  if type(source) ~= 'string' or source:sub(1, 1) ~= '@' then
    return nil
  end
  return vim.fn.fnamemodify(source:sub(2), ':h:h:h')
end

---@param root string|nil
---@return string|nil
local function origin_url(root)
  if not root or vim.fn.executable('git') ~= 1 then
    return nil
  end

  local output = vim.fn.system({ 'git', '-C', root, 'config', '--get', 'remote.origin.url' })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  output = vim.trim(output or '')
  if output == '' then
    return nil
  end
  return output
end

---@param url string
---@return boolean
local function is_github_cp_source(url)
  local normalized = url:lower():gsub('%.git$', '')
  return normalized:find('github.com[:/]barrettruth/cp%.nvim$', 1, false) ~= nil
end

---@return string|nil
local function marker_path()
  local state = vim.fn.stdpath('state')
  if type(state) ~= 'string' or state == '' then
    return nil
  end
  return state .. '/cp.nvim/' .. marker_name
end

---@param path string|nil
---@return boolean
local function marker_exists(path)
  return path ~= nil and vim.uv.fs_stat(path) ~= nil
end

---@param path string|nil
---@return nil
local function touch_marker(path)
  if not path then
    return
  end

  local dir = vim.fn.fnamemodify(path, ':h')
  pcall(vim.fn.mkdir, dir, 'p')

  local file = io.open(path, 'w')
  if file then
    local timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
    if type(timestamp) ~= 'string' then
      timestamp = ''
    end
    file:write(timestamp)
    file:write('\n')
    file:close()
  end
end

---@return nil
function M.warn_if_github_source()
  local marker = marker_path()
  if marker_exists(marker) then
    return
  end

  local url = origin_url(plugin_root())
  if not url or not is_github_cp_source(url) then
    return
  end

  touch_marker(marker)

  vim.schedule(function()
    vim.deprecate(
      'GitHub install source for cp.nvim',
      ('the Forgejo repository (%s); see %s'):format(forgejo_url, migration_help),
      '0.2.0',
      'cp.nvim',
      false
    )
  end)
end

return M
