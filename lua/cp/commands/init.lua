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
---@field requires_context? boolean
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
---@field race? boolean
---@field subcommand? string

---@param str string
---@return string
local function canonicalize_cf_contest(str)
  local id = str:match('/contest/(%d+)') or str:match('/problemset/problem/(%d+)')
  if id then
    return id
  end
  local num = str:match('^(%d+)[A-Za-z]')
  if num then
    return num
  end
  return str
end

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
    elseif first == 'interact' then
      local inter = args[2]
      if inter and inter ~= '' then
        return {
          type = 'action',
          action = 'interact',
          requires_context = true,
          interactor_cmd = inter,
        }
      else
        return { type = 'action', action = 'interact', requires_context = true }
      end
    elseif first == 'stress' then
      return {
        type = 'action',
        action = 'stress',
        requires_context = true,
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
      return { type = 'action', action = 'edit', requires_context = true, test_index = test_index }
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
        requires_context = true,
        test_indices = test_indices,
        debug = debug,
        mode = mode,
      }
    elseif first == 'open' then
      local target = args[2] or 'problem'
      if not vim.tbl_contains({ 'problem', 'contest', 'standings' }, target) then
        return { type = 'error', message = 'Usage: :CP open [problem|contest|standings]' }
      end
      return { type = 'action', action = 'open', requires_context = true, subcommand = target }
    elseif first == 'pick' then
      local language = nil
      if #args >= 3 and args[2] == '--lang' then
        language = args[3]
      elseif #args >= 2 and args[2] ~= nil and args[2]:sub(1, 2) ~= '--' then
        return {
          type = 'error',
          message = ("Unknown argument '%s' for action '%s'"):format(args[2], first),
        }
      end
      return { type = 'action', action = 'pick', requires_context = false, language = language }
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
      return { type = 'action', action = first, requires_context = true, language = language }
    end
  end

  if vim.tbl_contains(platforms, first) then
    if #args == 1 then
      return { type = 'action', action = 'pick', requires_context = false, platform = first }
    elseif #args == 2 then
      if args[2] == 'login' or args[2] == 'logout' or args[2] == 'signup' then
        return { type = 'action', action = args[2], requires_context = false, platform = first }
      end
      local contest = args[2]
      if first == 'codeforces' then
        contest = canonicalize_cf_contest(contest)
      end
      return {
        type = 'contest_setup',
        platform = first,
        contest = contest,
      }
    elseif #args == 3 and args[3] == '--race' then
      local contest = args[2]
      if first == 'codeforces' then
        contest = canonicalize_cf_contest(contest)
      end
      return {
        type = 'contest_setup',
        platform = first,
        contest = contest,
        race = true,
      }
    elseif #args == 4 and args[3] == '--lang' then
      local contest = args[2]
      if first == 'codeforces' then
        contest = canonicalize_cf_contest(contest)
      end
      return {
        type = 'contest_setup',
        platform = first,
        contest = contest,
        language = args[4],
      }
    elseif #args == 5 then
      local contest = args[2]
      if first == 'codeforces' then
        contest = canonicalize_cf_contest(contest)
      end
      local language, race = nil, false
      if args[3] == '--race' and args[4] == '--lang' then
        language = args[5]
        race = true
      elseif args[3] == '--lang' and args[5] == '--race' then
        language = args[4]
        race = true
      else
        return {
          type = 'error',
          message = 'Invalid arguments. Usage: :CP <platform> <contest> [--race] [--lang <language>]',
        }
      end
      return {
        type = 'contest_setup',
        platform = first,
        contest = contest,
        language = language,
        race = race,
      }
    else
      return {
        type = 'error',
        message = 'Invalid arguments. Usage: :CP <platform> <contest> [--race] [--lang <language>]',
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

---@param platform string
---@return boolean
local function check_platform_enabled(platform)
  local cfg = require('cp.config').get_config()
  if not cfg.platforms[platform] then
    logger.log(
      ("Platform '%s' is not enabled. Add it to vim.g.cp.platforms to enable it."):format(
        constants.PLATFORM_DISPLAY_NAMES[platform] or platform
      ),
      { level = vim.log.levels.ERROR }
    )
    return false
  end
  return true
end

--- Core logic for handling `:CP ...` commands
---@param opts { fargs: string[] }
---@return nil
function M.handle_command(opts)
  local cmd = parse_command(opts.fargs)

  if cmd.type == 'error' then
    logger.log(cmd.message, { level = vim.log.levels.ERROR })
    return
  end

  if cmd.type == 'restore_from_file' then
    local restore = require('cp.restore')
    restore.restore_from_current_file()
  elseif cmd.type == 'action' then
    if cmd.requires_context and not state.get_platform() then
      local restore = require('cp.restore')
      if not restore.restore_from_current_file() then
        return
      end
    end

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
      picker.handle_pick_action(cmd.language, cmd.platform)
    elseif cmd.action == 'edit' then
      local edit = require('cp.ui.edit')
      edit.toggle_edit(cmd.test_index)
    elseif cmd.action == 'stress' then
      require('cp.stress').toggle(cmd.generator_cmd, cmd.brute_cmd)
    elseif cmd.action == 'submit' then
      require('cp.submit').submit({ language = cmd.language })
    elseif cmd.action == 'open' then
      local cache = require('cp.cache')
      cache.load()
      local urls =
        cache.get_open_urls(state.get_platform(), state.get_contest_id(), state.get_problem_id())
      local url = urls and urls[cmd.subcommand]
      if not url or url == '' then
        logger.log(
          ("No URL available for '%s'"):format(cmd.subcommand),
          { level = vim.log.levels.WARN }
        )
        return
      end
      vim.ui.open(url)
    elseif cmd.action == 'login' then
      if not check_platform_enabled(cmd.platform) then
        return
      end
      require('cp.credentials').login(cmd.platform)
    elseif cmd.action == 'logout' then
      if not check_platform_enabled(cmd.platform) then
        return
      end
      require('cp.credentials').logout(cmd.platform)
    elseif cmd.action == 'signup' then
      local url = constants.SIGNUP_URLS[cmd.platform]
      if not url then
        logger.log(
          ("No signup URL available for '%s'"):format(cmd.platform),
          { level = vim.log.levels.WARN }
        )
        return
      end
      vim.ui.open(url)
    end
  elseif cmd.type == 'problem_jump' then
    local platform = state.get_platform()
    local contest_id = state.get_contest_id()
    local problem_id = cmd.problem_id

    if not (platform and contest_id) then
      logger.log('No contest is currently active.', { level = vim.log.levels.ERROR })
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
        { level = vim.log.levels.ERROR }
      )
      return
    end

    local setup = require('cp.setup')
    setup.setup_contest(platform, contest_id, problem_id, cmd.language)
  elseif cmd.type == 'cache' then
    local cache_commands = require('cp.commands.cache')
    cache_commands.handle_cache_command(cmd)
  elseif cmd.type == 'contest_setup' then
    if not check_platform_enabled(cmd.platform) then
      return
    end
    if cmd.race then
      require('cp.race').start(cmd.platform, cmd.contest, cmd.language)
    else
      local setup = require('cp.setup')
      setup.setup_contest(cmd.platform, cmd.contest, nil, cmd.language)
    end
    return
  end
end

return M
