local M = {}

local constants = require('cp.constants')
local logger = require('cp.log')
local state = require('cp.state')

local platforms = constants.PLATFORMS
local actions = constants.ACTIONS

---@class ParsedCommand
---@field type string
---@field error string?
---@field action? string
---@field message? string
---@field contest? string
---@field platform? string
---@field problem_id? string
---@field interactor_cmd? string
---@field generator_cmd? string
---@field brute_cmd? string
---@field test_index? integer
---@field test_indices? integer[]
---@field mode? string
---@field debug? boolean
---@field language? string
---@field subcommand? string

--- Turn raw args into normalized structure to later dispatch
---@param args string[] The raw command-line mode args
---@return ParsedCommand
local function parse_command(args)
  if vim.tbl_isempty(args) then
    return {
      type = 'restore_from_file',
    }
  end

  local first = args[1]

  if vim.tbl_contains(actions, first) then
    if first == 'cache' then
      local subcommand = args[2]
      if not subcommand then
        return { type = 'error', message = 'cache command requires subcommand' }
      end
      if vim.tbl_contains({ 'clear', 'read' }, subcommand) then
        local platform = args[3]
        local contest = args[4]
        return {
          type = 'cache',
          subcommand = subcommand,
          platform = platform,
          contest = contest,
        }
      else
        return { type = 'error', message = 'unknown cache subcommand: ' .. subcommand }
      end
    elseif first == 'race' then
      if args[2] == 'stop' then
        return { type = 'action', action = 'race_stop' }
      end
      if not args[2] or not args[3] then
        return {
          type = 'error',
          message = 'Usage: :CP race <platform> <contest_id> [--lang <lang>]',
        }
      end
      local language = nil
      if args[4] == '--lang' and args[5] then
        language = args[5]
      end
      return {
        type = 'action',
        action = 'race',
        platform = args[2],
        contest = args[3],
        language = language,
      }
    elseif first == 'interact' then
      local inter = args[2]
      if inter and inter ~= '' then
        return { type = 'action', action = 'interact', interactor_cmd = inter }
      else
        return { type = 'action', action = 'interact' }
      end
    elseif first == 'login' or first == 'logout' then
      return { type = 'action', action = first, platform = args[2] }
    elseif first == 'stress' then
      return {
        type = 'action',
        action = 'stress',
        generator_cmd = args[2],
        brute_cmd = args[3],
      }
    elseif first == 'edit' then
      local test_index = nil
      if #args >= 2 then
        local idx = tonumber(args[2])
        if not idx then
          return {
            type = 'error',
            message = ("Invalid argument '%s': expected test number"):format(args[2]),
          }
        end
        if idx < 1 or idx ~= math.floor(idx) then
          return { type = 'error', message = ("'%s' is not a valid test index"):format(idx) }
        end
        test_index = idx
      end
      return { type = 'action', action = 'edit', test_index = test_index }
    elseif first == 'run' or first == 'panel' then
      local debug = false
      local test_indices = nil
      local mode = 'combined'

      if #args == 2 then
        if args[2] == '--debug' then
          debug = true
        elseif args[2] == 'all' then
          mode = 'individual'
        else
          if args[2]:find(',') then
            local indices = {}
            for num in args[2]:gmatch('[^,]+') do
              local idx = tonumber(num)
              if not idx or idx < 1 or idx ~= math.floor(idx) then
                return {
                  type = 'error',
                  message = ("Invalid test index '%s' in list"):format(num),
                }
              end
              table.insert(indices, idx)
            end
            if #indices == 0 then
              return { type = 'error', message = 'No valid test indices provided' }
            end
            test_indices = indices
            mode = 'individual'
          else
            local idx = tonumber(args[2])
            if not idx then
              return {
                type = 'error',
                message = ("Invalid argument '%s': expected test number(s), 'all', or --debug"):format(
                  args[2]
                ),
              }
            end
            if idx < 1 or idx ~= math.floor(idx) then
              return { type = 'error', message = ("'%s' is not a valid test index"):format(idx) }
            end
            test_indices = { idx }
            mode = 'individual'
          end
        end
      elseif #args == 3 then
        if args[2] == 'all' then
          mode = 'individual'
          if args[3] ~= '--debug' then
            return {
              type = 'error',
              message = ("Invalid argument '%s': expected --debug"):format(args[3]),
            }
          end
          debug = true
        elseif args[2]:find(',') then
          local indices = {}
          for num in args[2]:gmatch('[^,]+') do
            local idx = tonumber(num)
            if not idx or idx < 1 or idx ~= math.floor(idx) then
              return {
                type = 'error',
                message = ("Invalid test index '%s' in list"):format(num),
              }
            end
            table.insert(indices, idx)
          end
          if #indices == 0 then
            return { type = 'error', message = 'No valid test indices provided' }
          end
          if args[3] ~= '--debug' then
            return {
              type = 'error',
              message = ("Invalid argument '%s': expected --debug"):format(args[3]),
            }
          end
          test_indices = indices
          mode = 'individual'
          debug = true
        else
          local idx = tonumber(args[2])
          if not idx then
            return {
              type = 'error',
              message = ("Invalid argument '%s': expected test number"):format(args[2]),
            }
          end
          if idx < 1 or idx ~= math.floor(idx) then
            return { type = 'error', message = ("'%s' is not a valid test index"):format(idx) }
          end
          if args[3] ~= '--debug' then
            return {
              type = 'error',
              message = ("Invalid argument '%s': expected --debug"):format(args[3]),
            }
          end
          test_indices = { idx }
          mode = 'individual'
          debug = true
        end
      elseif #args > 3 then
        return {
          type = 'error',
          message = 'Too many arguments. Usage: :CP '
            .. first
            .. ' [all|test_num[,test_num...]] [--debug]',
        }
      end

      return {
        type = 'action',
        action = first,
        test_indices = test_indices,
        debug = debug,
        mode = mode,
      }
    else
      local language = nil
      if #args >= 3 and args[2] == '--lang' then
        language = args[3]
      elseif #args >= 2 and args[2] ~= nil and args[2]:sub(1, 2) ~= '--' then
        return {
          type = 'error',
          message = ("Unknown argument '%s' for action '%s'"):format(args[2], first),
        }
      end
      return { type = 'action', action = first, language = language }
    end
  end

  if vim.tbl_contains(platforms, first) then
    if #args == 1 then
      return {
        type = 'error',
        message = 'Too few arguments - specify a contest.',
      }
    elseif #args == 2 then
      return {
        type = 'contest_setup',
        platform = first,
        contest = args[2],
      }
    elseif #args == 4 and args[3] == '--lang' then
      return {
        type = 'contest_setup',
        platform = first,
        contest = args[2],
        language = args[4],
      }
    else
      return {
        type = 'error',
        message = 'Invalid arguments. Usage: :CP <platform> <contest> [--lang <language>]',
      }
    end
  end

  if #args == 1 then
    return {
      type = 'problem_jump',
      problem_id = first,
    }
  elseif #args == 3 and args[2] == '--lang' then
    return {
      type = 'problem_jump',
      problem_id = first,
      language = args[3],
    }
  end

  return { type = 'error', message = 'Unknown command or no contest context.' }
end

--- Core logic for handling `:CP ...` commands
---@return nil
function M.handle_command(opts)
  local cmd = parse_command(opts.fargs)

  if cmd.type == 'error' then
    logger.log(cmd.message, vim.log.levels.ERROR)
    return
  end

  if cmd.type == 'restore_from_file' then
    local restore = require('cp.restore')
    restore.restore_from_current_file()
  elseif cmd.type == 'action' then
    local setup = require('cp.setup')
    local ui = require('cp.ui.views')

    if cmd.action == 'interact' then
      ui.toggle_interactive(cmd.interactor_cmd)
    elseif cmd.action == 'run' then
      ui.run_io_view(cmd.test_indices, cmd.debug, cmd.mode)
    elseif cmd.action == 'panel' then
      ui.toggle_panel({
        debug = cmd.debug,
        test_index = cmd.test_indices and cmd.test_indices[1] or nil,
      })
    elseif cmd.action == 'next' then
      setup.navigate_problem(1, cmd.language)
    elseif cmd.action == 'prev' then
      setup.navigate_problem(-1, cmd.language)
    elseif cmd.action == 'pick' then
      local picker = require('cp.commands.picker')
      picker.handle_pick_action(cmd.language)
    elseif cmd.action == 'edit' then
      local edit = require('cp.ui.edit')
      edit.toggle_edit(cmd.test_index)
    elseif cmd.action == 'stress' then
      require('cp.stress').toggle(cmd.generator_cmd, cmd.brute_cmd)
    elseif cmd.action == 'submit' then
      require('cp.submit').submit({ language = cmd.language })
    elseif cmd.action == 'race' then
      require('cp.race').start(cmd.platform, cmd.contest, cmd.language)
    elseif cmd.action == 'race_stop' then
      require('cp.race').stop()
    elseif cmd.action == 'login' then
      require('cp.credentials').login(cmd.platform)
    elseif cmd.action == 'logout' then
      require('cp.credentials').logout(cmd.platform)
    end
  elseif cmd.type == 'problem_jump' then
    local platform = state.get_platform()
    local contest_id = state.get_contest_id()
    local problem_id = cmd.problem_id

    if not (platform and contest_id) then
      logger.log('No contest is currently active.', vim.log.levels.ERROR)
      return
    end

    local cache = require('cp.cache')
    cache.load()
    local contest_data = cache.get_contest_data(platform, contest_id)

    if not (contest_data and contest_data.index_map and contest_data.index_map[problem_id]) then
      logger.log(
        ("%s contest '%s' has no problem '%s'."):format(
          constants.PLATFORM_DISPLAY_NAMES[platform],
          contest_id,
          problem_id
        ),
        vim.log.levels.ERROR
      )
      return
    end

    local setup = require('cp.setup')
    setup.setup_contest(platform, contest_id, problem_id, cmd.language)
  elseif cmd.type == 'cache' then
    local cache_commands = require('cp.commands.cache')
    cache_commands.handle_cache_command(cmd)
  elseif cmd.type == 'contest_setup' then
    local setup = require('cp.setup')
    setup.setup_contest(cmd.platform, cmd.contest, nil, cmd.language)
    return
  end
end

return M
