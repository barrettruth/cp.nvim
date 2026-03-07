local M = {}

local logger = require('cp.log')
local state = require('cp.state')
local utils = require('cp.utils')

local GENERATOR_PATTERNS = {
  'gen.py',
  'gen.cc',
  'gen.cpp',
  'generator.py',
  'generator.cc',
  'generator.cpp',
}

local BRUTE_PATTERNS = {
  'brute.py',
  'brute.cc',
  'brute.cpp',
  'slow.py',
  'slow.cc',
  'slow.cpp',
}

local function find_file(patterns)
  for _, pattern in ipairs(patterns) do
    if vim.fn.filereadable(pattern) == 1 then
      return pattern
    end
  end
  return nil
end

local function compile_cpp(source, output)
  local result = vim.system({ 'sh', '-c', 'g++ -O2 -o ' .. output .. ' ' .. source }):wait()
  if result.code ~= 0 then
    logger.log(
      ('Failed to compile %s: %s'):format(source, result.stderr or ''),
      { level = vim.log.levels.ERROR }
    )
    return false
  end
  return true
end

local function build_run_cmd(file)
  local ext = file:match('%.([^%.]+)$')
  if ext == 'cc' or ext == 'cpp' then
    local base = file:gsub('%.[^%.]+$', '')
    local bin = base .. '_bin'
    if not compile_cpp(file, bin) then
      return nil
    end
    return './' .. bin
  elseif ext == 'py' then
    return 'python3 ' .. file
  end
  return './' .. file
end

function M.toggle(generator_cmd, brute_cmd)
  if state.get_active_panel() == 'stress' then
    if state.stress_buf and vim.api.nvim_buf_is_valid(state.stress_buf) then
      local job = vim.b[state.stress_buf].terminal_job_id
      if job then
        vim.fn.jobstop(job)
      end
    end
    if state.saved_stress_session then
      vim.cmd.source(state.saved_stress_session)
      vim.fn.delete(state.saved_stress_session)
      state.saved_stress_session = nil
    end
    state.set_active_panel(nil)
    require('cp.ui.views').ensure_io_view()
    return
  end

  if state.get_active_panel() then
    logger.log('Another panel is already active.', { level = vim.log.levels.WARN })
    return
  end

  local gen_file = generator_cmd
  local brute_file = brute_cmd

  if not gen_file then
    gen_file = find_file(GENERATOR_PATTERNS)
  end
  if not brute_file then
    brute_file = find_file(BRUTE_PATTERNS)
  end

  if not gen_file then
    logger.log(
      'No generator found. Pass generator as first arg or add gen.{py,cc,cpp}.',
      { level = vim.log.levels.ERROR }
    )
    return
  end
  if not brute_file then
    logger.log(
      'No brute solution found. Pass brute as second arg or add brute.{py,cc,cpp}.',
      { level = vim.log.levels.ERROR }
    )
    return
  end

  local gen_cmd = build_run_cmd(gen_file)
  if not gen_cmd then
    return
  end

  local brute_run_cmd = build_run_cmd(brute_file)
  if not brute_run_cmd then
    return
  end

  state.saved_stress_session = vim.fn.tempname()
  -- selene: allow(mixed_table)
  vim.cmd.mksession({ state.saved_stress_session, bang = true })
  vim.cmd.only({ mods = { silent = true } })

  local execute = require('cp.runner.execute')

  local function restore_session()
    if state.saved_stress_session then
      vim.cmd.source(state.saved_stress_session)
      vim.fn.delete(state.saved_stress_session)
      state.saved_stress_session = nil
    end
    require('cp.ui.views').ensure_io_view()
  end

  execute.compile_problem(false, function(compile_result)
    if not compile_result.success then
      local run = require('cp.runner.run')
      run.handle_compilation_failure(compile_result.output)
      restore_session()
      return
    end

    local binary = state.get_binary_file()
    if not binary or binary == '' then
      logger.log('No binary produced.', { level = vim.log.levels.ERROR })
      restore_session()
      return
    end

    local script = vim.fn.fnamemodify(utils.get_plugin_path() .. '/scripts/stress.py', ':p')

    local cmdline
    if utils.is_nix_build() then
      cmdline = table.concat({
        vim.fn.shellescape(utils.get_nix_python()),
        vim.fn.shellescape(script),
        vim.fn.shellescape(gen_cmd),
        vim.fn.shellescape(brute_run_cmd),
        vim.fn.shellescape(binary),
      }, ' ')
    else
      cmdline = table.concat({
        'uv',
        'run',
        vim.fn.shellescape(script),
        vim.fn.shellescape(gen_cmd),
        vim.fn.shellescape(brute_run_cmd),
        vim.fn.shellescape(binary),
      }, ' ')
    end

    vim.cmd.terminal(cmdline)
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local cleaned = false
    local function cleanup()
      if cleaned then
        return
      end
      cleaned = true
      if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
        local job = vim.b[term_buf] and vim.b[term_buf].terminal_job_id or nil
        if job then
          pcall(vim.fn.jobstop, job)
        end
      end
      restore_session()
      state.stress_buf = nil
      state.stress_win = nil
      state.set_active_panel(nil)
    end

    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
      buffer = term_buf,
      callback = cleanup,
    })

    vim.api.nvim_create_autocmd('WinClosed', {
      callback = function()
        if cleaned then
          return
        end
        local any = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == term_buf then
            any = true
            break
          end
        end
        if not any then
          cleanup()
        end
      end,
    })

    vim.api.nvim_create_autocmd('TermClose', {
      buffer = term_buf,
      callback = function()
        vim.b[term_buf].cp_stress_exited = true
      end,
    })

    vim.keymap.set('t', '<c-q>', function()
      cleanup()
    end, { buffer = term_buf, silent = true })
    vim.keymap.set('n', '<c-q>', function()
      cleanup()
    end, { buffer = term_buf, silent = true })

    state.stress_buf = term_buf
    state.stress_win = term_win
    state.set_active_panel('stress')
  end)
end

function M.cancel()
  if state.stress_buf and vim.api.nvim_buf_is_valid(state.stress_buf) then
    local job = vim.b[state.stress_buf].terminal_job_id
    if job then
      vim.fn.jobstop(job)
    end
  end
  if state.saved_stress_session then
    vim.fn.delete(state.saved_stress_session)
    state.saved_stress_session = nil
  end
  state.set_active_panel(nil)
end

return M
