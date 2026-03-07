---@class DiffLayout
---@field buffers integer[]
---@field windows integer[]
---@field mode string
---@field cleanup fun()

local M = {}

local helpers = require('cp.helpers')
local utils = require('cp.utils')

M.DIFF_MODES = {
  ['side-by-side'] = 'side-by-side',
  vim = 'vim',
  git = 'git',
}

local function create_side_by_side_layout(parent_win, expected_content, actual_content)
  local expected_buf = utils.create_buffer_with_options()
  local actual_buf = utils.create_buffer_with_options()
  helpers.clearcol(expected_buf)
  helpers.clearcol(actual_buf)

  vim.api.nvim_set_current_win(parent_win)
  vim.cmd.split()
  vim.cmd.resize(math.floor(vim.o.lines * 0.35))
  local actual_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(actual_win, actual_buf)

  vim.cmd.vsplit()
  local expected_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(expected_win, expected_buf)

  vim.api.nvim_set_option_value('filetype', 'cp', { buf = expected_buf })
  vim.api.nvim_set_option_value('filetype', 'cp', { buf = actual_buf })
  local label = M.DIFF_MODES['side-by-side']
  vim.api.nvim_set_option_value(
    'winbar',
    ('expected (diff: %s)'):format(label),
    { win = expected_win }
  )
  vim.api.nvim_set_option_value('winbar', ('actual (diff: %s)'):format(label), { win = actual_win })

  local expected_lines = vim.split(expected_content, '\n', { plain = true, trimempty = true })
  local actual_lines = vim.split(actual_content, '\n', { plain = true })

  utils.update_buffer_content(expected_buf, expected_lines, {})
  utils.update_buffer_content(actual_buf, actual_lines, {})

  return {
    buffers = { expected_buf, actual_buf },
    windows = { expected_win, actual_win },
    mode = 'side-by-side',
    cleanup = function()
      pcall(vim.api.nvim_win_close, expected_win, true)
      pcall(vim.api.nvim_win_close, actual_win, true)
      pcall(vim.api.nvim_buf_delete, expected_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, actual_buf, { force = true })
    end,
  }
end

local function create_vim_diff_layout(parent_win, expected_content, actual_content)
  local expected_buf = utils.create_buffer_with_options()
  local actual_buf = utils.create_buffer_with_options()
  helpers.clearcol(expected_buf)
  helpers.clearcol(actual_buf)

  vim.api.nvim_set_current_win(parent_win)
  vim.cmd.split()
  vim.cmd.resize(math.floor(vim.o.lines * 0.35))
  local actual_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(actual_win, actual_buf)

  vim.cmd.vsplit()
  local expected_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(expected_win, expected_buf)

  vim.api.nvim_set_option_value('filetype', 'cp', { buf = expected_buf })
  vim.api.nvim_set_option_value('filetype', 'cp', { buf = actual_buf })
  local label = M.DIFF_MODES.vim
  vim.api.nvim_set_option_value(
    'winbar',
    ('expected (diff: %s)'):format(label),
    { win = expected_win }
  )
  vim.api.nvim_set_option_value('winbar', ('actual (diff: %s)'):format(label), { win = actual_win })

  local expected_lines = vim.split(expected_content, '\n', { plain = true, trimempty = true })
  local actual_lines = vim.split(actual_content, '\n', { plain = true })

  utils.update_buffer_content(expected_buf, expected_lines, {})
  utils.update_buffer_content(actual_buf, actual_lines, {})

  vim.api.nvim_set_option_value('diff', true, { win = expected_win })
  vim.api.nvim_set_option_value('diff', true, { win = actual_win })
  vim.api.nvim_win_call(expected_win, function()
    vim.cmd.diffthis()
  end)
  vim.api.nvim_win_call(actual_win, function()
    vim.cmd.diffthis()
  end)
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = expected_win })
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = actual_win })

  return {
    buffers = { expected_buf, actual_buf },
    windows = { expected_win, actual_win },
    mode = 'vim',
    cleanup = function()
      pcall(vim.api.nvim_win_close, expected_win, true)
      pcall(vim.api.nvim_win_close, actual_win, true)
      pcall(vim.api.nvim_buf_delete, expected_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, actual_buf, { force = true })
    end,
  }
end

local function create_git_diff_layout(parent_win, expected_content, actual_content)
  local diff_buf = utils.create_buffer_with_options()
  helpers.clearcol(diff_buf)

  vim.api.nvim_set_current_win(parent_win)
  vim.cmd.split()
  vim.cmd.resize(math.floor(vim.o.lines * 0.35))
  local diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(diff_win, diff_buf)

  vim.api.nvim_set_option_value('filetype', 'cp', { buf = diff_buf })
  local label = M.DIFF_MODES.git
  vim.api.nvim_set_option_value('winbar', ('diff: %s'):format(label), { win = diff_win })

  local diff_backend = require('cp.ui.diff')
  local backend = diff_backend.get_best_backend('git')
  local diff_result = backend.render(expected_content, actual_content)
  local highlight = require('cp.ui.highlight')
  local diff_namespace = highlight.create_namespace()

  if diff_result.raw_diff and diff_result.raw_diff ~= '' then
    highlight.parse_and_apply_diff(diff_buf, diff_result.raw_diff, diff_namespace)
  else
    local lines = vim.split(actual_content, '\n', { plain = true })
    utils.update_buffer_content(diff_buf, lines, {})
  end

  return {
    buffers = { diff_buf },
    windows = { diff_win },
    mode = 'git',
    cleanup = function()
      pcall(vim.api.nvim_win_close, diff_win, true)
      pcall(vim.api.nvim_buf_delete, diff_buf, { force = true })
    end,
  }
end

local function create_single_layout(parent_win, content)
  local buf = utils.create_buffer_with_options()
  local lines = vim.split(content, '\n', { plain = true })
  utils.update_buffer_content(buf, lines, {})

  vim.api.nvim_set_current_win(parent_win)
  vim.cmd.split()
  vim.cmd.resize(math.floor(vim.o.lines * 0.35))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_option_value('filetype', 'cp', { buf = buf })

  return {
    buffers = { buf },
    windows = { win },
    mode = 'single',
    cleanup = function()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end,
  }
end

---@param mode string
---@param parent_win integer
---@param expected_content string
---@param actual_content string
---@return DiffLayout
function M.create_diff_layout(mode, parent_win, expected_content, actual_content)
  if mode == 'single' then
    return create_single_layout(parent_win, actual_content)
  elseif mode == 'side-by-side' then
    return create_side_by_side_layout(parent_win, expected_content, actual_content)
  elseif mode == 'git' then
    return create_git_diff_layout(parent_win, expected_content, actual_content)
  elseif mode == 'vim' then
    return create_vim_diff_layout(parent_win, expected_content, actual_content)
  else
    return create_side_by_side_layout(parent_win, expected_content, actual_content)
  end
end

---@param current_diff_layout DiffLayout?
---@param current_mode string?
---@param main_win integer
---@param run table
---@param config cp.Config
---@param setup_keybindings_for_buffer fun(buf: integer)
---@return DiffLayout?, string?
function M.update_diff_panes(
  current_diff_layout,
  current_mode,
  main_win,
  run,
  config,
  setup_keybindings_for_buffer
)
  local test_state = run.get_panel_state()
  local current_test = test_state.test_cases[test_state.current_index]

  if not current_test then
    return current_diff_layout, current_mode
  end

  local expected_content = current_test.expected or ''
  local actual_content = current_test.actual or '(not run yet)'
  local actual_highlights = current_test.actual_highlights or {}
  local is_compilation_failure = current_test.error
    and current_test.error:match('Compilation failed')
  local should_show_diff = current_test.status == 'fail'
    and current_test.actual
    and not is_compilation_failure

  if not should_show_diff then
    expected_content = expected_content
    actual_content = actual_content
  end

  local default_mode = config.ui.panel.diff_modes[1]
  local desired_mode = is_compilation_failure and 'single' or (current_mode or default_mode)
  local highlight = require('cp.ui.highlight')
  local diff_namespace = highlight.create_namespace()
  local ansi_namespace = vim.api.nvim_create_namespace('cp_ansi_highlights')

  if current_diff_layout and current_diff_layout.mode ~= desired_mode then
    local saved_pos = vim.api.nvim_win_get_cursor(0)
    current_diff_layout.cleanup()
    current_diff_layout = nil
    current_mode = nil

    current_diff_layout =
      M.create_diff_layout(desired_mode, main_win, expected_content, actual_content)
    current_mode = desired_mode

    for _, buf in ipairs(current_diff_layout.buffers) do
      setup_keybindings_for_buffer(buf)
    end

    pcall(vim.api.nvim_win_set_cursor, 0, saved_pos)
    return current_diff_layout, current_mode
  end

  if not current_diff_layout then
    current_diff_layout =
      M.create_diff_layout(desired_mode, main_win, expected_content, actual_content)
    current_mode = desired_mode

    for _, buf in ipairs(current_diff_layout.buffers) do
      setup_keybindings_for_buffer(buf)
    end
  else
    if desired_mode == 'single' then
      local lines = vim.split(actual_content, '\n', { plain = true })
      utils.update_buffer_content(
        current_diff_layout.buffers[1],
        lines,
        actual_highlights,
        ansi_namespace
      )
    elseif desired_mode == 'git' then
      local diff_backend = require('cp.ui.diff')
      local backend = diff_backend.get_best_backend('git')
      local diff_result = backend.render(expected_content, actual_content)

      if diff_result.raw_diff and diff_result.raw_diff ~= '' then
        highlight.parse_and_apply_diff(
          current_diff_layout.buffers[1],
          diff_result.raw_diff,
          diff_namespace
        )
      else
        local lines = vim.split(actual_content, '\n', { plain = true })
        utils.update_buffer_content(
          current_diff_layout.buffers[1],
          lines,
          actual_highlights,
          ansi_namespace
        )
      end
    elseif desired_mode == 'side-by-side' then
      local expected_lines = vim.split(expected_content, '\n', { plain = true, trimempty = true })
      local actual_lines = vim.split(actual_content, '\n', { plain = true })
      utils.update_buffer_content(current_diff_layout.buffers[1], expected_lines, {})
      utils.update_buffer_content(
        current_diff_layout.buffers[2],
        actual_lines,
        actual_highlights,
        ansi_namespace
      )
    else
      local expected_lines = vim.split(expected_content, '\n', { plain = true, trimempty = true })
      local actual_lines = vim.split(actual_content, '\n', { plain = true })
      utils.update_buffer_content(current_diff_layout.buffers[1], expected_lines, {})
      utils.update_buffer_content(
        current_diff_layout.buffers[2],
        actual_lines,
        actual_highlights,
        ansi_namespace
      )

      if should_show_diff then
        vim.api.nvim_set_option_value('diff', true, { win = current_diff_layout.windows[1] })
        vim.api.nvim_set_option_value('diff', true, { win = current_diff_layout.windows[2] })
        vim.api.nvim_win_call(current_diff_layout.windows[1], function()
          vim.cmd.diffthis()
        end)
        vim.api.nvim_win_call(current_diff_layout.windows[2], function()
          vim.cmd.diffthis()
        end)
        vim.api.nvim_set_option_value('foldcolumn', '0', { win = current_diff_layout.windows[1] })
        vim.api.nvim_set_option_value('foldcolumn', '0', { win = current_diff_layout.windows[2] })
      else
        vim.api.nvim_set_option_value('diff', false, { win = current_diff_layout.windows[1] })
        vim.api.nvim_set_option_value('diff', false, { win = current_diff_layout.windows[2] })
      end
    end
  end

  return current_diff_layout, current_mode
end

return M
