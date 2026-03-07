local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local conf = require('telescope.config').values
local action_state = require('telescope.actions.state')
local actions = require('telescope.actions')

local logger = require('cp.log')
local picker_utils = require('cp.pickers')

local M = {}

local function contest_picker(opts, platform, refresh, language)
  local constants = require('cp.constants')
  local platform_display_name = constants.PLATFORM_DISPLAY_NAMES[platform]
  local contests = picker_utils.get_platform_contests(platform, refresh)

  if vim.tbl_isempty(contests) then
    logger.log(
      ('No contests found for platform: %s'):format(platform_display_name),
      { level = vim.log.levels.WARN }
    )
    return
  end

  pickers
    .new(opts, {
      prompt_title = ('Select Contest (%s)'):format(platform_display_name),
      results_title = '<c-r> refresh',
      finder = finders.new_table({
        results = contests,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display_name,
            ordinal = entry.display_name,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)

          if selection then
            local cp = require('cp')
            local fargs = { platform, selection.value.id }
            if language then
              table.insert(fargs, '--lang')
              table.insert(fargs, language)
            end
            cp.handle_command({ fargs = fargs })
          end
        end)

        map('i', '<c-r>', function()
          actions.close(prompt_bufnr)
          contest_picker(opts, platform, true, language)
        end)

        return true
      end,
    })
    :find()
end

function M.pick(language)
  local opts = {}
  local platforms = picker_utils.get_platforms()

  pickers
    .new(opts, {
      prompt_title = 'Select Platform',
      finder = finders.new_table({
        results = platforms,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display_name,
            ordinal = entry.display_name,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)

          if selection then
            contest_picker(opts, selection.value.id, false, language)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
