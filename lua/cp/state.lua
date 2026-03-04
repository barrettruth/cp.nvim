---@class cp.ProvisionalState
---@field bufnr integer
---@field platform string
---@field contest_id string
---@field language string
---@field requested_problem_id string?
---@field token integer

---@class cp.IoViewState
---@field output_buf integer
---@field input_buf integer
---@field source_buf integer?

---@class cp.State
---@field get_platform fun(): string?
---@field set_platform fun(platform: string)
---@field get_contest_id fun(): string?
---@field set_contest_id fun(contest_id: string)
---@field get_problem_id fun(): string?
---@field set_problem_id fun(problem_id: string)
---@field get_language fun(): string?
---@field set_language fun(language: string)
---@field get_active_panel fun(): string?
---@field set_active_panel fun(panel: string?)
---@field get_base_name fun(): string?
---@field get_source_file fun(language?: string): string?
---@field get_binary_file fun(): string?
---@field get_input_file fun(): string?
---@field get_output_file fun(): string?
---@field get_expected_file fun(): string?
---@field get_provisional fun(): cp.ProvisionalState?
---@field set_provisional fun(p: cp.ProvisionalState?)
---@field get_saved_session fun(): string?
---@field set_saved_session fun(path: string?)
---@field get_io_view_state fun(): cp.IoViewState?
---@field set_io_view_state fun(s: cp.IoViewState?)

local M = {}

---@type table<string, any>
local state = {
  platform = nil,
  contest_id = nil,
  problem_id = nil,
  language = nil,
  test_cases = nil,
  saved_session = nil,
  active_panel = nil,
  provisional = nil,
  solution_win = nil,
  io_view_state = nil,
}

---@return string?
function M.get_platform()
  return state.platform
end

---@param platform string
function M.set_platform(platform)
  state.platform = platform
end

---@return string?
function M.get_contest_id()
  return state.contest_id
end

---@param contest_id string
function M.set_contest_id(contest_id)
  state.contest_id = contest_id
end

---@return string?
function M.get_problem_id()
  return state.problem_id
end

---@param problem_id string
function M.set_problem_id(problem_id)
  state.problem_id = problem_id
end

---@return string?
function M.get_language()
  return state.language
end

---@param language string
function M.set_language(language)
  state.language = language
end

---@return string?
function M.get_base_name()
  local platform, contest_id, problem_id = M.get_platform(), M.get_contest_id(), M.get_problem_id()
  if not platform or not contest_id or not problem_id then
    return nil
  end

  local config_module = require('cp.config')
  local config = config_module.get_config()

  if config.filename then
    return config.filename(platform, contest_id, problem_id, config)
  else
    return config_module.default_filename(contest_id, problem_id)
  end
end

---@param language? string
---@return string?
function M.get_source_file(language)
  local base_name = M.get_base_name()
  if not base_name or not M.get_platform() then
    return nil
  end

  local config = require('cp.config').get_config()
  local plat = M.get_platform()
  local platform_cfg = config.platforms[plat]
  if not platform_cfg then
    return nil
  end

  local target_language = language or state.language or platform_cfg.default_language
  local eff = config.runtime.effective[plat] and config.runtime.effective[plat][target_language]
    or nil
  if not eff or not eff.extension then
    return nil
  end

  return base_name .. '.' .. eff.extension
end

---@return string?
function M.get_binary_file()
  local base_name = M.get_base_name()
  return base_name and ('build/%s.run'):format(base_name) or nil
end

---@return string?
function M.get_debug_file()
  local base_name = M.get_base_name()
  return base_name and ('build/%s.dbg'):format(base_name) or nil
end

---@return string?
function M.get_input_file()
  local base_name = M.get_base_name()
  return base_name and ('io/%s.cpin'):format(base_name) or nil
end

---@return string?
function M.get_output_file()
  local base_name = M.get_base_name()
  return base_name and ('io/%s.cpout'):format(base_name) or nil
end

---@return string?
function M.get_expected_file()
  local base_name = M.get_base_name()
  return base_name and ('io/%s.expected'):format(base_name) or nil
end

---@return string?
function M.get_active_panel()
  return state.active_panel
end

---@param panel string?
function M.set_active_panel(panel)
  state.active_panel = panel
end

---@return cp.ProvisionalState?
function M.get_provisional()
  return state.provisional
end

---@param p cp.ProvisionalState?
function M.set_provisional(p)
  state.provisional = p
end

---@return integer?
function M.get_solution_win()
  if state.solution_win and vim.api.nvim_win_is_valid(state.solution_win) then
    return state.solution_win
  end
  return vim.api.nvim_get_current_win()
end

---@param win integer?
function M.set_solution_win(win)
  state.solution_win = win
end

---@return cp.IoViewState?
function M.get_io_view_state()
  return state.io_view_state
end

---@param s cp.IoViewState?
function M.set_io_view_state(s)
  state.io_view_state = s
end

---@return string?
function M.get_saved_session()
  return state.saved_session
end

---@param path string?
function M.set_saved_session(path)
  state.saved_session = path
end

M._state = state

return M
