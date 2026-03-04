local M = {}

local cache = require('cp.cache')
local config_module = require('cp.config')
local helpers = require('cp.helpers')
local logger = require('cp.log')
local state = require('cp.state')
local utils = require('cp.utils')

---@class TestBufferPair
---@field input_buf integer
---@field expected_buf integer
---@field input_win integer
---@field expected_win integer

---@class EditState
---@field test_buffers TestBufferPair[]
---@field test_cases TestCase[]
---@field constraints ProblemConstraints?

---@type EditState?
local edit_state = nil

local setup_keybindings

---@param bufnr integer
---@return integer? test_index
local function get_current_test_index(bufnr)
  if not edit_state then
    return nil
  end
  for i, pair in ipairs(edit_state.test_buffers) do
    if pair.input_buf == bufnr or pair.expected_buf == bufnr then
      return i
    end
  end
  return nil
end

---@param index integer
local function jump_to_test(index)
  if not edit_state then
    return
  end
  local pair = edit_state.test_buffers[index]
  if pair and vim.api.nvim_win_is_valid(pair.input_win) then
    vim.api.nvim_set_current_win(pair.input_win)
  end
end

---@param delta integer
local function navigate_test(delta)
  local current_buf = vim.api.nvim_get_current_buf()
  local current_index = get_current_test_index(current_buf)
  if not current_index or not edit_state then
    return
  end
  local new_index = current_index + delta
  if new_index < 1 or new_index > #edit_state.test_buffers then
    return
  end
  jump_to_test(new_index)
end

---@param test_index integer
local function load_test_into_buffer(test_index)
  if not edit_state then
    return
  end

  local tc = edit_state.test_cases[test_index]
  local pair = edit_state.test_buffers[test_index]

  if not tc or not pair then
    return
  end

  local input_lines = vim.split(tc.input or '', '\n', { plain = true, trimempty = false })
  vim.api.nvim_buf_set_lines(pair.input_buf, 0, -1, false, input_lines)

  local expected_lines = vim.split(tc.expected or '', '\n', { plain = true, trimempty = false })
  vim.api.nvim_buf_set_lines(pair.expected_buf, 0, -1, false, expected_lines)

  vim.api.nvim_buf_set_name(pair.input_buf, string.format('cp://test-%d-input', test_index))
  vim.api.nvim_buf_set_name(pair.expected_buf, string.format('cp://test-%d-expected', test_index))
end

local function delete_current_test()
  if not edit_state then
    return
  end
  if #edit_state.test_buffers == 1 then
    logger.log('Problems must have at least one test case.', vim.log.levels.ERROR)
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local current_index = get_current_test_index(current_buf)
  if not current_index then
    return
  end

  local pair = edit_state.test_buffers[current_index]
  if vim.api.nvim_win_is_valid(pair.input_win) then
    vim.api.nvim_win_close(pair.input_win, true)
  end
  if vim.api.nvim_win_is_valid(pair.expected_win) then
    vim.api.nvim_win_close(pair.expected_win, true)
  end
  if vim.api.nvim_buf_is_valid(pair.input_buf) then
    vim.api.nvim_buf_delete(pair.input_buf, { force = true })
  end
  if vim.api.nvim_buf_is_valid(pair.expected_buf) then
    vim.api.nvim_buf_delete(pair.expected_buf, { force = true })
  end

  table.remove(edit_state.test_buffers, current_index)
  table.remove(edit_state.test_cases, current_index)

  for i = current_index, #edit_state.test_buffers do
    load_test_into_buffer(i)
  end

  local next_index = math.min(current_index, #edit_state.test_buffers)
  jump_to_test(next_index)

  logger.log(('Deleted test %d'):format(current_index))
end

local function add_new_test()
  if not edit_state then
    return
  end

  local last_pair = edit_state.test_buffers[#edit_state.test_buffers]
  if not last_pair or not vim.api.nvim_win_is_valid(last_pair.input_win) then
    return
  end

  vim.api.nvim_set_current_win(last_pair.input_win)
  vim.cmd.vsplit()
  local input_win = vim.api.nvim_get_current_win()
  local input_buf = utils.create_buffer_with_options()
  vim.api.nvim_win_set_buf(input_win, input_buf)
  vim.bo[input_buf].modifiable = true
  vim.bo[input_buf].readonly = false
  vim.bo[input_buf].buftype = 'acwrite'
  vim.bo[input_buf].buflisted = false
  helpers.clearcol(input_buf)

  vim.api.nvim_set_current_win(last_pair.expected_win)
  vim.cmd.vsplit()
  local expected_win = vim.api.nvim_get_current_win()
  local expected_buf = utils.create_buffer_with_options()
  vim.api.nvim_win_set_buf(expected_win, expected_buf)
  vim.bo[expected_buf].modifiable = true
  vim.bo[expected_buf].readonly = false
  vim.bo[expected_buf].buftype = 'acwrite'
  vim.bo[expected_buf].buflisted = false
  helpers.clearcol(expected_buf)

  local new_index = #edit_state.test_buffers + 1
  local new_pair = {
    input_buf = input_buf,
    expected_buf = expected_buf,
    input_win = input_win,
    expected_win = expected_win,
  }
  table.insert(edit_state.test_buffers, new_pair)
  table.insert(edit_state.test_cases, { index = new_index, input = '', expected = '' })

  setup_keybindings(input_buf)
  setup_keybindings(expected_buf)
  load_test_into_buffer(new_index)

  vim.api.nvim_set_current_win(input_win)
  logger.log(('Added test %d'):format(new_index))
end

local function save_all_tests()
  if not edit_state then
    return
  end

  local platform = state.get_platform()
  local contest_id = state.get_contest_id()
  local problem_id = state.get_problem_id()

  if not platform or not contest_id or not problem_id then
    return
  end

  for i, pair in ipairs(edit_state.test_buffers) do
    if
      vim.api.nvim_buf_is_valid(pair.input_buf) and vim.api.nvim_buf_is_valid(pair.expected_buf)
    then
      local input_lines = vim.api.nvim_buf_get_lines(pair.input_buf, 0, -1, false)
      local expected_lines = vim.api.nvim_buf_get_lines(pair.expected_buf, 0, -1, false)

      edit_state.test_cases[i].input = table.concat(input_lines, '\n')
      edit_state.test_cases[i].expected = table.concat(expected_lines, '\n')
    end
  end

  local contest_data = cache.get_contest_data(platform, contest_id)
  local is_multi_test = contest_data.problems[contest_data.index_map[problem_id]].multi_test
    or false

  local combined_input = table.concat(
    vim.tbl_map(function(tc)
      return tc.input
    end, edit_state.test_cases),
    '\n'
  )
  local combined_expected = table.concat(
    vim.tbl_map(function(tc)
      return tc.expected
    end, edit_state.test_cases),
    '\n'
  )

  cache.set_test_cases(
    platform,
    contest_id,
    problem_id,
    { input = combined_input, expected = combined_expected },
    edit_state.test_cases,
    edit_state.constraints and edit_state.constraints.timeout_ms or 0,
    edit_state.constraints and edit_state.constraints.memory_mb or 0,
    false,
    is_multi_test
  )

  local config = config_module.get_config()
  local base_name = config.filename and config.filename(platform, contest_id, problem_id, config)
    or config_module.default_filename(contest_id, problem_id)

  vim.fn.mkdir('io', 'p')

  for i, tc in ipairs(edit_state.test_cases) do
    local input_file = string.format('io/%s.%d.cpin', base_name, i)
    local expected_file = string.format('io/%s.%d.cpout', base_name, i)

    local input_content = (tc.input or ''):gsub('\r', '')
    local expected_content = (tc.expected or ''):gsub('\r', '')

    vim.fn.writefile(vim.split(input_content, '\n', { trimempty = true }), input_file)
    vim.fn.writefile(vim.split(expected_content, '\n', { trimempty = true }), expected_file)
  end

  logger.log('Saved all test cases')
end

---@param buf integer
setup_keybindings = function(buf)
  local config = config_module.get_config()
  local keys = config.ui.edit

  if keys.save_and_exit_key then
    vim.keymap.set('n', keys.save_and_exit_key, function()
      M.toggle_edit()
    end, { buffer = buf, silent = true, desc = 'Save and exit test editor' })
  end

  if keys.next_test_key then
    vim.keymap.set('n', keys.next_test_key, function()
      navigate_test(1)
    end, { buffer = buf, silent = true, desc = 'Next test' })
  end

  if keys.prev_test_key then
    vim.keymap.set('n', keys.prev_test_key, function()
      navigate_test(-1)
    end, { buffer = buf, silent = true, desc = 'Previous test' })
  end

  if keys.delete_test_key then
    vim.keymap.set(
      'n',
      keys.delete_test_key,
      delete_current_test,
      { buffer = buf, silent = true, desc = 'Delete test' }
    )
  end

  if keys.add_test_key then
    vim.keymap.set(
      'n',
      keys.add_test_key,
      add_new_test,
      { buffer = buf, silent = true, desc = 'Add test' }
    )
  end

  local augroup = vim.api.nvim_create_augroup('cp_edit_guard', { clear = false })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not edit_state then
          return
        end

        local is_tracked = false
        for _, pair in ipairs(edit_state.test_buffers) do
          if pair.input_buf == buf or pair.expected_buf == buf then
            is_tracked = true
            break
          end
        end

        if is_tracked then
          logger.log('Test buffer closed unexpectedly. Exiting editor.', vim.log.levels.WARN)
          M.toggle_edit()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = augroup,
    buffer = buf,
    callback = function()
      save_all_tests()
      vim.bo[buf].modified = false
    end,
  })
end

function M.toggle_edit(test_index)
  if edit_state then
    save_all_tests()

    for _, pair in ipairs(edit_state.test_buffers) do
      if vim.api.nvim_buf_is_valid(pair.input_buf) then
        vim.api.nvim_buf_delete(pair.input_buf, { force = true })
      end
      if vim.api.nvim_buf_is_valid(pair.expected_buf) then
        vim.api.nvim_buf_delete(pair.expected_buf, { force = true })
      end
    end

    edit_state = nil

    pcall(vim.api.nvim_clear_autocmds, { group = 'cp_edit_guard' })

    local saved = state.get_saved_session()
    if saved then
      vim.fn.delete(saved)
      state.set_saved_session(nil)
    end

    vim.cmd.only({ mods = { silent = true } })
    local source_file = state.get_source_file()
    if source_file and vim.fn.filereadable(source_file) == 1 then
      vim.cmd.edit(source_file)
    end

    local views = require('cp.ui.views')
    views.ensure_io_view()

    logger.log('Closed test editor')
    return
  end

  local platform, contest_id, problem_id =
    state.get_platform(), state.get_contest_id(), state.get_problem_id()

  if not platform or not contest_id or not problem_id then
    logger.log('No problem context. Run :CP <platform> <contest> first.', vim.log.levels.ERROR)
    return
  end

  cache.load()
  local test_cases = cache.get_test_cases(platform, contest_id, problem_id)

  if not test_cases or #test_cases == 0 then
    logger.log('No test cases available for editing.', vim.log.levels.ERROR)
    return
  end

  local timeout_ms, memory_mb = cache.get_constraints(platform, contest_id, problem_id)
  local constraints = (timeout_ms and memory_mb)
      and { timeout_ms = timeout_ms, memory_mb = memory_mb }
    or nil

  local target_index = test_index or 1
  if target_index < 1 or target_index > #test_cases then
    logger.log(
      ('Test %d does not exist (only %d tests available)'):format(target_index, #test_cases),
      vim.log.levels.ERROR
    )
    return
  end

  local io_view_state = state.get_io_view_state()
  if io_view_state then
    if io_view_state.output_buf and vim.api.nvim_buf_is_valid(io_view_state.output_buf) then
      vim.api.nvim_buf_delete(io_view_state.output_buf, { force = true })
    end
    if io_view_state.input_buf and vim.api.nvim_buf_is_valid(io_view_state.input_buf) then
      vim.api.nvim_buf_delete(io_view_state.input_buf, { force = true })
    end
    state.set_io_view_state(nil)
  end

  local session_file = vim.fn.tempname()
  state.set_saved_session(session_file)
  -- selene: allow(mixed_table)
  vim.cmd.mksession({ session_file, bang = true })
  vim.cmd.only({ mods = { silent = true } })

  local test_buffers = {}
  local num_tests = #test_cases

  for _ = 1, num_tests - 1 do
    vim.cmd.vsplit()
  end

  vim.cmd('1 wincmd w')

  for col = 1, num_tests do
    vim.cmd.split()

    vim.cmd.wincmd('k')
    local input_win = vim.api.nvim_get_current_win()
    local input_buf = utils.create_buffer_with_options()
    vim.api.nvim_win_set_buf(input_win, input_buf)
    vim.bo[input_buf].modifiable = true
    vim.bo[input_buf].readonly = false
    vim.bo[input_buf].buftype = 'acwrite'
    vim.bo[input_buf].buflisted = false
    helpers.clearcol(input_buf)

    vim.cmd.wincmd('j')
    local expected_win = vim.api.nvim_get_current_win()
    local expected_buf = utils.create_buffer_with_options()
    vim.api.nvim_win_set_buf(expected_win, expected_buf)
    vim.bo[expected_buf].modifiable = true
    vim.bo[expected_buf].readonly = false
    vim.bo[expected_buf].buftype = 'acwrite'
    vim.bo[expected_buf].buflisted = false
    helpers.clearcol(expected_buf)

    test_buffers[col] = {
      input_buf = input_buf,
      expected_buf = expected_buf,
      input_win = input_win,
      expected_win = expected_win,
    }

    vim.cmd.wincmd('k')
    vim.cmd.wincmd('l')
  end

  edit_state = {
    test_buffers = test_buffers,
    test_cases = test_cases,
    constraints = constraints,
  }

  for i = 1, num_tests do
    load_test_into_buffer(i)
  end

  for _, pair in ipairs(test_buffers) do
    setup_keybindings(pair.input_buf)
    setup_keybindings(pair.expected_buf)
  end

  if
    test_buffers[target_index]
    and vim.api.nvim_win_is_valid(test_buffers[target_index].input_win)
  then
    vim.api.nvim_set_current_win(test_buffers[target_index].input_win)
  end

  logger.log(('Editing %d test cases'):format(num_tests))
end

return M
