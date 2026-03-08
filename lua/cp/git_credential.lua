local M = {}

local HOSTS = {
  atcoder = 'atcoder.jp',
  codechef = 'www.codechef.com',
  codeforces = 'codeforces.com',
  cses = 'cses.fi',
  kattis = 'open.kattis.com',
  usaco = 'usaco.org',
}

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

  local creds = { username = parsed.username, password = parsed.password }

  if platform == 'cses' then
    local token_input = _build_input(host, { path = 'api-token' })
    local token_obj = vim
      .system({ 'git', 'credential', 'fill' }, { stdin = token_input, text = true, timeout = 5000 })
      :wait()
    if token_obj.code == 0 then
      local token_parsed = _parse_output(token_obj.stdout or '')
      if token_parsed.password then
        creds.token = token_parsed.password
      end
    end
  end

  return creds
end

function M.store(platform, creds)
  local host = HOSTS[platform]
  if not host then
    return
  end

  local input = _build_input(host, { username = creds.username, password = creds.password })
  vim.system({ 'git', 'credential', 'approve' }, { stdin = input, text = true }):wait()

  if platform == 'cses' and creds.token then
    local token_input =
      _build_input(host, { path = 'api-token', username = creds.username, password = creds.token })
    vim.system({ 'git', 'credential', 'approve' }, { stdin = token_input, text = true }):wait()
  end
end

function M.reject(platform, creds)
  local host = HOSTS[platform]
  if not host or not creds then
    return
  end

  local input = _build_input(host, { username = creds.username, password = creds.password })
  vim.system({ 'git', 'credential', 'reject' }, { stdin = input, text = true }):wait()

  if platform == 'cses' and creds.token then
    local token_input =
      _build_input(host, { path = 'api-token', username = creds.username, password = creds.token })
    vim.system({ 'git', 'credential', 'reject' }, { stdin = token_input, text = true }):wait()
  end
end

return M
