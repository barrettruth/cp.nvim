---@class ExecuteResult
---@field stdout string
---@field code integer
---@field time_ms number
---@field tled boolean
---@field mled boolean
---@field peak_mb number
---@field signal string|nil

---@class SubstitutableCommand
---@field source string substituted via '{source}'
---@field binary string substitued via '{binary}'

local M = {}
local constants = require('cp.constants')
local logger = require('cp.log')
local utils = require('cp.utils')

---@param cmd_template string[]
---@param substitutions SubstitutableCommand
---@return string[] string normalized with substitutions
local function substitute_template(cmd_template, substitutions)
  local out = {}
  for _, arg in ipairs(cmd_template) do
    if arg == '{source}' and substitutions.source then
      table.insert(out, substitutions.source)
    elseif arg == '{binary}' and substitutions.binary then
      table.insert(out, substitutions.binary)
    else
      table.insert(out, arg)
    end
  end
  return out
end

function M.build_command(cmd_template, substitutions)
  return substitute_template(cmd_template, substitutions)
end

---@param compile_cmd string[]
---@param substitutions SubstitutableCommand
---@param on_complete fun(r: {code: integer, stdout: string})
function M.compile(compile_cmd, substitutions, on_complete)
  local cmd = substitute_template(compile_cmd, substitutions)
  local sh = table.concat(cmd, ' ') .. ' 2>&1'

  local t0 = vim.uv.hrtime()
  vim.system({ 'sh', '-c', sh }, { text = false }, function(r)
    local dt = (vim.uv.hrtime() - t0) / 1e6
    local ansi = require('cp.ui.ansi')
    r.stdout = ansi.bytes_to_string(r.stdout or '')

    if r.code == 0 then
      logger.log(('Compilation successful in %.1fms.'):format(dt), vim.log.levels.INFO)
    else
      logger.log(('Compilation failed in %.1fms.'):format(dt))
    end

    vim.schedule(function()
      on_complete(r)
    end)
  end)
end

local function parse_and_strip_time_v(output)
  local s = output or ''
  local last_i, from = nil, 1
  while true do
    local i = string.find(s, 'Command being timed:', from, true)
    if not i then
      break
    end
    last_i, from = i, i + 1
  end
  if not last_i then
    return s, 0
  end

  local tab_before_marker = s:find('\t[^\t]*Command being timed:', 1)
  local k
  if tab_before_marker then
    k = tab_before_marker - 1
  else
    k = last_i - 1
    while k >= 1 do
      local ch = s:sub(k, k)
      if ch == '\n' then
        break
      end
      k = k - 1
    end
  end

  local head = s:sub(1, k)
  local tail = s:sub(last_i)

  local peak_kb = 0.0
  for line in tail:gmatch('[^\n]+') do
    local kb = line:match('Maximum resident set size %(kbytes%):%s*(%d+)')
    if kb then
      peak_kb = tonumber(kb) or 0
    end
  end

  local peak_mb = peak_kb / 1024.0
  return head, peak_mb
end

---@param on_complete fun(result: ExecuteResult)
function M.run(cmd, stdin, timeout_ms, memory_mb, on_complete)
  local time_bin = utils.time_path()
  local timeout_bin = utils.timeout_path()

  local prog = table.concat(cmd, ' ')
  local pre = {
    ('ulimit -v %d'):format(memory_mb * 1024),
  }
  local prefix = table.concat(pre, '; ') .. '; '
  local sec = math.ceil(timeout_ms / 1000)
  local timeout_prefix = ('%s -k 1s %ds '):format(timeout_bin, sec)
  local sh = prefix .. timeout_prefix .. ('%s -v sh -c %q 2>&1'):format(time_bin, prog)

  local t0 = vim.uv.hrtime()
  vim.system({ 'sh', '-c', sh }, { stdin = stdin, text = true }, function(r)
    local dt = (vim.uv.hrtime() - t0) / 1e6

    local code = r.code or 0
    local raw = r.stdout or ''
    local cleaned, peak_mb = parse_and_strip_time_v(raw)
    local tled = code == 124

    local signal = nil
    if code >= 128 then
      signal = constants.signal_codes[code]
    end

    local lower = (cleaned or ''):lower()
    local oom_hint = lower:find('std::bad_alloc', 1, true)
      or lower:find('cannot allocate memory', 1, true)
      or lower:find('out of memory', 1, true)
      or lower:find('oom', 1, true)
      or lower:find('enomem', 1, true)
    local near_cap = peak_mb >= (0.90 * memory_mb)

    local mled = (peak_mb >= memory_mb) or near_cap or (oom_hint ~= nil and not tled)

    if tled then
      logger.log(('Execution timed out in %.1fms.'):format(dt))
    elseif mled then
      logger.log(('Execution memory limit exceeded in %.1fms.'):format(dt))
    elseif code ~= 0 then
      logger.log(('Execution failed in %.1fms (exit code %d).'):format(dt, code))
    else
      logger.log(('Execution successful in %.1fms.'):format(dt))
    end

    vim.schedule(function()
      on_complete({
        stdout = cleaned,
        code = code,
        time_ms = dt,
        tled = tled,
        mled = mled,
        peak_mb = peak_mb,
        signal = signal,
      })
    end)
  end)
end

---@param debug boolean?
---@param on_complete fun(result: {success: boolean, output: string?})
function M.compile_problem(debug, on_complete)
  local state = require('cp.state')
  local config = require('cp.config').get_config()
  local platform = state.get_platform()
  local language = state.get_language() or config.platforms[platform].default_language
  local eff = config.runtime.effective[platform][language]

  local source_file = state.get_source_file()
  if source_file then
    local buf = vim.fn.bufnr(source_file)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd.write({ mods = { silent = true, noautocmd = true } })
      end)
    end
  end

  local compile_config = (debug and eff.commands.debug) or eff.commands.build

  if not compile_config then
    on_complete({ success = true, output = nil })
    return
  end

  require('cp.utils').ensure_dirs()

  local binary = debug and state.get_debug_file() or state.get_binary_file()
  local substitutions = { source = state.get_source_file(), binary = binary }

  M.compile(compile_config, substitutions, function(r)
    if r.code ~= 0 then
      on_complete({ success = false, output = r.stdout or 'unknown error' })
    else
      on_complete({ success = true, output = nil })
    end
  end)
end

return M
