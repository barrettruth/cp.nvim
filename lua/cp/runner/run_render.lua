---@class StatusInfo
---@field text string
---@field highlight_group string

local M = {}

local function strwidth(s)
  return vim.api.nvim_strwidth(s)
end

local exit_code_names = {
  [128] = 'SIGHUP',
  [129] = 'SIGINT',
  [130] = 'SIGQUIT',
  [131] = 'SIGILL',
  [132] = 'SIGTRAP',
  [133] = 'SIGABRT',
  [134] = 'SIGBUS',
  [135] = 'SIGFPE',
  [136] = 'SIGKILL',
  [137] = 'SIGUSR1',
  [138] = 'SIGSEGV',
  [139] = 'SIGUSR2',
  [140] = 'SIGPIPE',
  [141] = 'SIGALRM',
  [142] = 'SIGTERM',
  [143] = 'SIGCHLD',
}

---@param ran_test_case RanTestCase
---@return StatusInfo
function M.get_status_info(ran_test_case)
  if ran_test_case.status == 'pending' then
    return { text = '...', highlight_group = 'CpTestNA' }
  elseif ran_test_case.status == 'running' then
    return { text = 'RUN', highlight_group = 'CpTestNA' }
  end

  if ran_test_case.ok then
    return { text = 'AC', highlight_group = 'CpTestAC' }
  end

  if ran_test_case.tled then
    return { text = 'TLE', highlight_group = 'CpTestTLE' }
  elseif ran_test_case.mled then
    return { text = 'MLE', highlight_group = 'CpTestMLE' }
  elseif ran_test_case.code and ran_test_case.code >= 128 then
    return { text = 'RTE', highlight_group = 'CpTestRTE' }
  elseif ran_test_case.code == 0 and not ran_test_case.ok then
    return { text = 'WA', highlight_group = 'CpTestWA' }
  end

  return { text = 'N/A', highlight_group = 'CpTestNA' }
end

local function format_exit_code(code)
  if not code then
    return '—'
  end
  local signal_name = exit_code_names[code]
  return signal_name and string.format('%d (%s)', code, signal_name) or tostring(code)
end

local function compute_cols(test_state)
  local w = { num = 5, status = 8, time = 6, timeout = 8, rss = 8, memory = 8, exit = 11 }

  local timeout_str = '—'
  local memory_str = '—'
  if test_state.constraints then
    timeout_str = tostring(test_state.constraints.timeout_ms)
    memory_str = string.format('%.0f', test_state.constraints.memory_mb)
  end

  for i, tc in ipairs(test_state.test_cases) do
    local prefix = (i == test_state.current_index) and '>' or ' '
    w.num = math.max(w.num, strwidth(' ' .. prefix .. i .. ' '))
    w.status = math.max(w.status, strwidth(' ' .. M.get_status_info(tc).text .. ' '))
    local time_str = tc.time_ms and string.format('%.2f', tc.time_ms) or '—'
    w.time = math.max(w.time, strwidth(' ' .. time_str .. ' '))
    w.timeout = math.max(w.timeout, strwidth(' ' .. timeout_str .. ' '))
    local rss_str = (tc.rss_mb and string.format('%.0f', tc.rss_mb)) or '—'
    w.rss = math.max(w.rss, strwidth(' ' .. rss_str .. ' '))
    w.memory = math.max(w.memory, strwidth(' ' .. memory_str .. ' '))
    w.exit = math.max(w.exit, strwidth(' ' .. format_exit_code(tc.code) .. ' '))
  end

  w.num = math.max(w.num, strwidth(' # '))
  w.status = math.max(w.status, strwidth(' Status '))
  w.time = math.max(w.time, strwidth(' Runtime (ms) '))
  w.timeout = math.max(w.timeout, strwidth(' Time (ms) '))
  w.rss = math.max(w.rss, strwidth(' RSS (MB) '))
  w.memory = math.max(w.memory, strwidth(' Mem (MB) '))
  w.exit = math.max(w.exit, strwidth(' Exit Code '))

  local sum = w.num + w.status + w.time + w.timeout + w.rss + w.memory + w.exit
  local inner = sum + 6
  local total = inner + 2
  return { w = w, sum = sum, inner = inner, total = total }
end

local function center(text, width)
  local pad = width - strwidth(text)
  if pad <= 0 then
    return text
  end
  local left = math.ceil(pad / 2)
  return string.rep(' ', left) .. text .. string.rep(' ', pad - left)
end

local function format_num_column(prefix, idx, width)
  local num_str = tostring(idx)
  local content = (#num_str == 1) and (' ' .. prefix .. ' ' .. num_str .. ' ')
    or (' ' .. prefix .. num_str .. ' ')
  local total_pad = width - strwidth(content)
  if total_pad <= 0 then
    return content
  end
  local left_pad = math.ceil(total_pad / 2)
  local right_pad = total_pad - left_pad
  return string.rep(' ', left_pad) .. content .. string.rep(' ', right_pad)
end

local function top_border(c)
  local w = c.w
  return '┌'
    .. string.rep('─', w.num)
    .. '┬'
    .. string.rep('─', w.status)
    .. '┬'
    .. string.rep('─', w.time)
    .. '┬'
    .. string.rep('─', w.timeout)
    .. '┬'
    .. string.rep('─', w.rss)
    .. '┬'
    .. string.rep('─', w.memory)
    .. '┬'
    .. string.rep('─', w.exit)
    .. '┐'
end

local function row_sep(c)
  local w = c.w
  return '├'
    .. string.rep('─', w.num)
    .. '┼'
    .. string.rep('─', w.status)
    .. '┼'
    .. string.rep('─', w.time)
    .. '┼'
    .. string.rep('─', w.timeout)
    .. '┼'
    .. string.rep('─', w.rss)
    .. '┼'
    .. string.rep('─', w.memory)
    .. '┼'
    .. string.rep('─', w.exit)
    .. '┤'
end

local function bottom_border(c)
  local w = c.w
  return '└'
    .. string.rep('─', w.num)
    .. '┴'
    .. string.rep('─', w.status)
    .. '┴'
    .. string.rep('─', w.time)
    .. '┴'
    .. string.rep('─', w.timeout)
    .. '┴'
    .. string.rep('─', w.rss)
    .. '┴'
    .. string.rep('─', w.memory)
    .. '┴'
    .. string.rep('─', w.exit)
    .. '┘'
end

local function flat_fence_above(c)
  local w = c.w
  return '├'
    .. string.rep('─', w.num)
    .. '┴'
    .. string.rep('─', w.status)
    .. '┴'
    .. string.rep('─', w.time)
    .. '┴'
    .. string.rep('─', w.timeout)
    .. '┴'
    .. string.rep('─', w.rss)
    .. '┴'
    .. string.rep('─', w.memory)
    .. '┴'
    .. string.rep('─', w.exit)
    .. '┤'
end

local function flat_fence_below(c)
  local w = c.w
  return '├'
    .. string.rep('─', w.num)
    .. '┬'
    .. string.rep('─', w.status)
    .. '┬'
    .. string.rep('─', w.time)
    .. '┬'
    .. string.rep('─', w.timeout)
    .. '┬'
    .. string.rep('─', w.rss)
    .. '┬'
    .. string.rep('─', w.memory)
    .. '┬'
    .. string.rep('─', w.exit)
    .. '┤'
end

local function flat_bottom_border(c)
  return '└' .. string.rep('─', c.inner) .. '┘'
end

local function header_line(c)
  local w = c.w
  return '│'
    .. center('#', w.num)
    .. '│'
    .. center('Status', w.status)
    .. '│'
    .. center('Runtime (ms)', w.time)
    .. '│'
    .. center('Time (ms)', w.timeout)
    .. '│'
    .. center('RSS (MB)', w.rss)
    .. '│'
    .. center('Mem (MB)', w.memory)
    .. '│'
    .. center('Exit Code', w.exit)
    .. '│'
end

local function data_row(c, idx, tc, is_current, test_state)
  local w = c.w
  local prefix = is_current and '>' or ' '
  local status = M.get_status_info(tc)
  local time = tc.time_ms and string.format('%.2f', tc.time_ms) or '—'
  local exit = format_exit_code(tc.code)

  local timeout = '—'
  local memory = '—'
  if test_state.constraints then
    timeout = tostring(test_state.constraints.timeout_ms)
    memory = string.format('%.0f', test_state.constraints.memory_mb)
  end

  local rss = (tc.rss_mb and string.format('%.0f', tc.rss_mb)) or '—'

  local line = '│'
    .. format_num_column(prefix, idx, w.num)
    .. '│'
    .. center(status.text, w.status)
    .. '│'
    .. center(time, w.time)
    .. '│'
    .. center(timeout, w.timeout)
    .. '│'
    .. center(rss, w.rss)
    .. '│'
    .. center(memory, w.memory)
    .. '│'
    .. center(exit, w.exit)
    .. '│'

  local hi
  if status.text ~= '' then
    local status_pos = line:find(status.text, 1, true)
    if status_pos then
      hi = {
        col_start = status_pos - 1,
        col_end = status_pos - 1 + #status.text,
        highlight_group = status.highlight_group,
      }
    end
  end

  return line, hi
end

---@param test_state PanelState
---@return string[] lines
---@return Highlight[] highlights
---@return integer current_test_line
function M.render_test_list(test_state)
  local lines, highlights = {}, {}
  local c = compute_cols(test_state)
  local current_test_line = nil

  table.insert(lines, top_border(c))
  table.insert(lines, header_line(c))
  table.insert(lines, row_sep(c))

  for i, tc in ipairs(test_state.test_cases) do
    local is_current = (i == test_state.current_index)
    local row, hi = data_row(c, i, tc, is_current, test_state)
    table.insert(lines, row)

    if is_current then
      current_test_line = #lines
    end

    if hi then
      hi.line = #lines - 1
      table.insert(highlights, hi)
    end

    local has_next = (i < #test_state.test_cases)
    local has_input = is_current and tc.input and tc.input ~= ''

    if has_input then
      table.insert(lines, flat_fence_above(c))

      local input_header = 'Input:'
      local header_pad = c.inner - #input_header
      table.insert(lines, '│' .. input_header .. string.rep(' ', header_pad) .. '│')

      for _, input_line in ipairs(vim.split(tc.input, '\n', { plain = true, trimempty = false })) do
        local s = input_line or ''
        if strwidth(s) > c.inner then
          s = string.sub(s, 1, c.inner)
        end
        local pad = c.inner - strwidth(s)
        table.insert(lines, '│' .. s .. string.rep(' ', pad) .. '│')
      end

      if has_next then
        table.insert(lines, flat_fence_below(c))
      else
        table.insert(lines, flat_bottom_border(c))
      end
    else
      if has_next then
        table.insert(lines, row_sep(c))
      else
        table.insert(lines, bottom_border(c))
      end
    end
  end

  return lines, highlights, current_test_line or 1
end

---@param ran_test_case RanTestCase?
---@return string
function M.render_status_bar(ran_test_case)
  if not ran_test_case then
    return ''
  end
  local parts = {}
  if ran_test_case.time_ms then
    table.insert(parts, string.format('%.2fms', ran_test_case.time_ms))
  end
  if ran_test_case.code then
    table.insert(parts, string.format('Exit: %d', ran_test_case.code))
  end
  return table.concat(parts, ' │ ')
end

---@return table<string, table>
function M.get_highlight_groups()
  return {
    CpTestAC = { link = 'DiagnosticOk' },
    CpTestWA = { link = 'DiagnosticError' },
    CpTestTLE = { link = 'DiagnosticWarn' },
    CpTestMLE = { link = 'DiagnosticWarn' },
    CpTestRTE = { link = 'DiagnosticHint' },
    CpTestNA = { link = 'Comment' },
  }
end

---@return nil
function M.setup_highlights()
  local groups = M.get_highlight_groups()
  for name, opts in pairs(groups) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

return M
