local M = {}

local cache = require('cp.cache')
local logger = require('cp.log')
local state = require('cp.state')

---@return boolean
function M.restore_from_current_file()
  cache.load()

  local current_file = (vim.uv.fs_realpath(vim.fn.expand('%:p')) or vim.fn.expand('%:p'))
  local file_state = cache.get_file_state(current_file)
  if not file_state then
    logger.log('No cached state found for current file.', { level = vim.log.levels.ERROR })
    return false
  end

  local setup = require('cp.setup')
  state.set_problem_id(file_state.problem_id)
  setup.setup_contest(
    file_state.platform,
    file_state.contest_id,
    file_state.problem_id,
    file_state.language
  )

  return true
end

return M
