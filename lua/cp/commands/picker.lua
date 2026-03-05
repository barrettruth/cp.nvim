local M = {}

local config_module = require('cp.config')
local logger = require('cp.log')

--- Dispatch `:CP pick` to appropriate picker
---@param language? string
---@return nil
function M.handle_pick_action(language)
  local config = config_module.get_config()

  if not (config.ui and config.ui.picker) then
    logger.log(
      'No picker configured. Set ui.picker = "{telescope,fzf-lua}" in your config.',
      { level = vim.log.levels.ERROR }
    )
    return
  end

  local picker

  local picker_name = config.ui.picker
  if picker_name == 'telescope' then
    local ok = pcall(require, 'telescope')
    if not ok then
      logger.log(
        'telescope.nvim is not available. Install telescope.nvim xor change your picker config.',
        { level = vim.log.levels.ERROR }
      )
      return
    end
    local ok_cp, telescope_picker = pcall(require, 'cp.pickers.telescope')
    if not ok_cp then
      logger.log('Failed to load telescope integration.', { level = vim.log.levels.ERROR })
      return
    end

    picker = telescope_picker
  elseif picker_name == 'fzf-lua' then
    local ok, _ = pcall(require, 'fzf-lua')
    if not ok then
      logger.log(
        'fzf-lua is not available. Install fzf-lua or change your picker config',
        { level = vim.log.levels.ERROR }
      )
      return
    end
    local ok_cp, fzf_picker = pcall(require, 'cp.pickers.fzf_lua')
    if not ok_cp then
      logger.log('Failed to load fzf-lua integration.', { level = vim.log.levels.ERROR })
      return
    end

    picker = fzf_picker
  end

  picker.pick(language)
end

return M
