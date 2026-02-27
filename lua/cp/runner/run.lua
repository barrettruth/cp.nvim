---@class RanTestCase
---@field index number
---@field input string
---@field expected string
---@field status "pending"|"pass"|"fail"|"running"|"tle"|"mle"
---@field actual string?
---@field actual_highlights? Highlight[]
---@field time_ms number?
---@field error string?
---@field stderr string?
---@field selected boolean
---@field code number?
---@field ok boolean?
---@field signal string?
---@field tled boolean?
---@field mled boolean?
---@field rss_mb number

---@class ProblemConstraints
---@field timeout_ms number
---@field memory_mb number
---@field epsilon number?

---@class PanelState
---@field test_cases RanTestCase[]
---@field current_index number
---@field buffer number?
---@field namespace number?
---@field is_active boolean
---@field saved_layout table?
---@field constraints ProblemConstraints?

local M = {}
local cache = require('cp.cache')
local config = require('cp.config').get_config()
local constants = require('cp.constants')
local execute = require('cp.runner.execute')
local logger = require('cp.log')
local state = require('cp.state')

---@type PanelState
local panel_state = {
  test_cases = {},
  current_index = 1,
  buffer = nil,
  namespace = nil,
  is_active = false,
  saved_layout = nil,
  constraints = nil,
}

---@param platform string
---@param contest_id string
---@param problem_id string|nil
---@return ProblemConstraints|nil
local function load_constraints_from_cache(platform, contest_id, problem_id)
  cache.load()
  local timeout_ms, memory_mb = cache.get_constraints(platform, contest_id, problem_id)
  if timeout_ms and memory_mb then
    local epsilon = cache.get_epsilon(platform, contest_id, problem_id)
    return { timeout_ms = timeout_ms, memory_mb = memory_mb, epsilon = epsilon }
  end
  return nil
end

--- Normalize raw problem output to a "canonical" version
--- Usually, most contests ignore leading/trailing whitespace and empty lines
---@param lines string
local function normalize_lines(lines)
  local normalized = {}
  for _, line in
    ipairs(vim.tbl_values(vim.split(((lines or ''):gsub('\r', '')), '\n', { plain = true })))
  do
    local trimmed_line = vim.trim(line)
    if trimmed_line ~= '' then
      table.insert(normalized, trimmed_line)
    end
  end
  return table.concat(normalized, '\n')
end

---@param test_cases TestCase[]
---@return RanTestCase[]
local function create_sentinal_panel_data(test_cases)
  local out = {}
  for i, tc in ipairs(test_cases) do
    out[i] = {
      index = tc.index or i,
      input = tc.input or '',
      expected = tc.expected or '',
      status = 'pending',
      selected = false,
    }
  end
  return out
end

---@param cmd string[]
---@return string[]
local function build_command(cmd, substitutions)
  return execute.build_command(cmd, substitutions)
end

local function compare_outputs(actual, expected, epsilon)
  local norm_actual = normalize_lines(actual)
  local norm_expected = normalize_lines(expected)

  if epsilon == nil or epsilon == 0 then
    return norm_actual == norm_expected
  end

  local actual_lines = vim.split(norm_actual, '\n', { plain = true })
  local expected_lines = vim.split(norm_expected, '\n', { plain = true })

  if #actual_lines ~= #expected_lines then
    return false
  end

  for i = 1, #actual_lines do
    local a_tokens = vim.split(actual_lines[i], '%s+', { plain = false, trimempty = true })
    local e_tokens = vim.split(expected_lines[i], '%s+', { plain = false, trimempty = true })

    if #a_tokens ~= #e_tokens then
      return false
    end

    for j = 1, #a_tokens do
      local a_tok, e_tok = a_tokens[j], e_tokens[j]
      local a_num = tonumber(a_tok)
      local e_num = tonumber(e_tok)

      if a_num ~= nil and e_num ~= nil then
        if math.abs(a_num - e_num) > epsilon then
          return false
        end
      else
        if a_tok ~= e_tok then
          return false
        end
      end
    end
  end

  return true
end

---@param test_case RanTestCase
---@param debug boolean?
---@param on_complete fun(result: { status: "pass"|"fail"|"tle"|"mle", actual: string, actual_highlights: Highlight[], error: string, stderr: string, time_ms: number, code: integer, ok: boolean, signal: string?, tled: boolean, mled: boolean, rss_mb: number })
local function run_single_test_case(test_case, debug, on_complete)
  local source_file = state.get_source_file()

  local binary_file = debug and state.get_debug_file() or state.get_binary_file()
  local substitutions = { source = source_file, binary = binary_file }

  local platform_config = config.platforms[state.get_platform() or '']
  local language = state.get_language() or platform_config.default_language
  local eff = config.runtime.effective[state.get_platform() or ''][language]
  local run_template = eff and eff.commands and eff.commands.run or {}
  local cmd = build_command(run_template, substitutions)
  local stdin_content = (test_case.input or '') .. '\n'
  local timeout_ms = (panel_state.constraints and panel_state.constraints.timeout_ms) or 0
  local memory_mb = panel_state.constraints and panel_state.constraints.memory_mb or 0

  execute.run(cmd, stdin_content, timeout_ms, memory_mb, function(r)
    local ansi = require('cp.ui.ansi')
    local out = r.stdout or ''
    local highlights = {}
    if out ~= '' then
      if config.ui.ansi then
        local parsed = ansi.parse_ansi_text(out)
        out = table.concat(parsed.lines, '\n')
        highlights = parsed.highlights
      else
        out = out:gsub('\027%[[%d;]*[a-zA-Z]', '')
      end
    end

    local max_lines = config.ui.panel.max_output_lines
    local lines = vim.split(out, '\n')
    if #lines > max_lines then
      local trimmed = {}
      for i = 1, max_lines do
        table.insert(trimmed, lines[i])
      end
      table.insert(trimmed, string.format('... (output trimmed after %d lines)', max_lines))
      out = table.concat(trimmed, '\n')
    end

    local expected = test_case.expected or ''
    local epsilon = (panel_state.constraints and panel_state.constraints.epsilon)
      or config.ui.panel.epsilon
    local ok = compare_outputs(out, expected, epsilon)

    local signal = r.signal
    if not signal and r.code and r.code >= 128 then
      signal = constants.signal_codes[r.code]
    end

    local status
    if r.tled then
      status = 'tle'
    elseif r.mled then
      status = 'mle'
    elseif ok then
      status = 'pass'
    else
      status = 'fail'
    end

    on_complete({
      status = status,
      actual = out,
      actual_highlights = highlights,
      error = (r.code ~= 0 and not ok) and out or '',
      stderr = '',
      time_ms = r.time_ms,
      code = r.code,
      ok = ok,
      signal = signal,
      tled = r.tled or false,
      mled = r.mled or false,
      rss_mb = r.peak_mb or 0,
    })
  end)
end

---@return boolean
function M.load_test_cases()
  local tcs = cache.get_test_cases(
    state.get_platform() or '',
    state.get_contest_id() or '',
    state.get_problem_id()
  )

  panel_state.test_cases = create_sentinal_panel_data(tcs)
  panel_state.current_index = 1
  panel_state.constraints = load_constraints_from_cache(
    state.get_platform() or '',
    state.get_contest_id() or '',
    state.get_problem_id()
  )

  logger.log(('Loaded %d test case(s)'):format(#tcs), vim.log.levels.INFO)
  return #tcs > 0
end

---@param debug boolean?
---@param on_complete fun(result: RanTestCase?)
function M.run_combined_test(debug, on_complete)
  local combined = cache.get_combined_test(
    state.get_platform() or '',
    state.get_contest_id() or '',
    state.get_problem_id()
  )

  if not combined then
    logger.log('No combined test found', vim.log.levels.ERROR)
    on_complete(nil)
    return
  end

  local ran_test = {
    index = 1,
    input = combined.input,
    expected = combined.expected,
    status = 'running',
    actual = nil,
    time_ms = nil,
    code = nil,
    ok = nil,
    signal = nil,
    tled = false,
    mled = false,
    rss_mb = 0,
    selected = true,
  }

  run_single_test_case(ran_test, debug, function(result)
    on_complete(result)
  end)
end

---@param index number
---@param debug boolean?
---@param on_complete fun(success: boolean)
function M.run_test_case(index, debug, on_complete)
  local tc = panel_state.test_cases[index]
  if not tc then
    on_complete(false)
    return
  end

  tc.status = 'running'
  run_single_test_case(tc, debug, function(r)
    tc.status = r.status
    tc.actual = r.actual
    tc.actual_highlights = r.actual_highlights
    tc.error = r.error
    tc.stderr = r.stderr
    tc.time_ms = r.time_ms
    tc.code = r.code
    tc.ok = r.ok
    tc.signal = r.signal
    tc.tled = r.tled
    tc.mled = r.mled
    tc.rss_mb = r.rss_mb

    on_complete(true)
  end)
end

---@param indices? integer[]
---@param debug boolean?
---@param on_each? fun(index: integer, total: integer)
---@param on_done fun(results: RanTestCase[])
function M.run_all_test_cases(indices, debug, on_each, on_done)
  local to_run = indices
  if not to_run then
    to_run = {}
    for i = 1, #panel_state.test_cases do
      to_run[i] = i
    end
  end

  if #to_run == 0 then
    logger.log(
      ('Finished %s %d test cases.'):format(debug and 'debugging' or 'running', 0),
      vim.log.levels.INFO,
      true
    )
    on_done(panel_state.test_cases)
    return
  end

  local total = #to_run
  local remaining = total

  for _, idx in ipairs(to_run) do
    M.run_test_case(idx, debug, function()
      if on_each then
        on_each(idx, total)
      end
      remaining = remaining - 1
      if remaining == 0 then
        logger.log(
          ('Finished %s %d test cases.'):format(debug and 'debugging' or 'running', total),
          vim.log.levels.INFO,
          true
        )
        on_done(panel_state.test_cases)
      end
    end)
  end
end

---@return PanelState
function M.get_panel_state()
  return panel_state
end

---@param output string|nil
---@return nil
function M.handle_compilation_failure(output)
  local ansi = require('cp.ui.ansi')

  local txt
  local hl = {}

  if config.ui.ansi then
    local p = ansi.parse_ansi_text(output or '')
    txt = table.concat(p.lines, '\n')
    hl = p.highlights
  else
    txt = (output or ''):gsub('\027%[[%d;]*[a-zA-Z]', '')
  end

  for _, tc in ipairs(panel_state.test_cases) do
    tc.status = 'fail'
    tc.actual = txt
    tc.actual_highlights = hl
    tc.error = 'Compilation failed'
    tc.stderr = ''
    tc.time_ms = 0
    tc.code = 1
    tc.ok = false
    tc.signal = ''
    tc.tled = false
    tc.mled = false
    tc.rss_mb = 0
  end
end

return M
