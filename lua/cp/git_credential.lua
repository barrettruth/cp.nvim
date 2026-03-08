---@class cp.Credentials
---@field username string
---@field password string
---@field token? string

local M = {}

local HOSTS = {
  atcoder = 'atcoder.jp',
  codechef = 'www.codechef.com',
  codeforces = 'codeforces.com',
  cses = 'cses.fi',
  kattis = 'open.kattis.com',
  usaco = 'usaco.org',
}

local _helper_checked = false
local _helper_ok = false

---@return boolean
function M.has_helper()
  if not _helper_checked then
    local r = vim
      .system({ 'git', 'config', 'credential.helper' }, { text = true, timeout = 5000 })
      :wait()
    _helper_ok = r.code == 0 and r.stdout ~= nil and vim.trim(r.stdout) ~= ''
    _helper_checked = true
  end
  return _helper_ok
end

---@param host string
---@param extra? table<string, string>
---@return string
local function _build_input(host, extra)
  local lines = { 'protocol=https', 'host=' .. host }
  if extra then
    for k, v in pairs(extra) do
      table.insert(lines, k .. '=' .. v)
    end
  end
  table.insert(lines, '')
  table.insert(lines, '')
  return table.concat(lines, '\n')
end

---@param stdout string
---@return table<string, string>
local function _parse_output(stdout)
  local result = {}
  for line in stdout:gmatch('[^\n]+') do
    local k, v = line:match('^(%S+)=(.+)$')
    if k and v then
      result[k] = v
    end
  end
  return result
end

local CSES_TOKEN_SEP = '\t'

---@param platform string
---@param password string
---@return string, string?
local function _decode_password(platform, password)
  if platform ~= 'cses' then
    return password, nil
  end
  local pw, token = password:match('^(.-)' .. CSES_TOKEN_SEP .. '(.+)$')
  if pw then
    return pw, token
  end
  return password, nil
end

---@param password string
---@param token? string
---@return string
local function _encode_password(password, token)
  if token then
    return password .. CSES_TOKEN_SEP .. token
  end
  return password
end

---@param platform string
---@return cp.Credentials?
function M.get(platform)
  local host = HOSTS[platform]
  if not host then
    return nil
  end

  local input = _build_input(host)
  local obj = vim
    .system({ 'git', 'credential', 'fill' }, { stdin = input, text = true, timeout = 5000 })
    :wait()
  if obj.code ~= 0 then
    return nil
  end

  local parsed = _parse_output(obj.stdout or '')
  if not parsed.username or not parsed.password then
    return nil
  end

  local password, token = _decode_password(platform, parsed.password)
  local creds = { username = parsed.username, password = password }
  if token then
    creds.token = token
  end

  return creds
end

---@param platform string
---@param creds cp.Credentials
function M.store(platform, creds)
  local host = HOSTS[platform]
  if not host then
    return
  end

  local stored_password = _encode_password(creds.password, creds.token)
  local input = _build_input(host, { username = creds.username, password = stored_password })
  vim.system({ 'git', 'credential', 'approve' }, { stdin = input, text = true }):wait()
end

---@param platform string
---@param creds cp.Credentials
function M.reject(platform, creds)
  local host = HOSTS[platform]
  if not host or not creds then
    return
  end

  local stored_password = _encode_password(creds.password, creds.token)
  local input = _build_input(host, { username = creds.username, password = stored_password })
  vim.system({ 'git', 'credential', 'reject' }, { stdin = input, text = true }):wait()
end

return M
