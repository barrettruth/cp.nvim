if vim.g.loaded_cp then
  return
end
vim.g.loaded_cp = 1

vim.api.nvim_create_user_command('CP', function(opts)
  local cp = require('cp')
  cp.handle_command(opts)
end, {
  nargs = '*',
  desc = 'Competitive programming helper',
  complete = function(ArgLead, CmdLine, _)
    local constants = require('cp.constants')
    local platforms = constants.PLATFORMS
    local actions = constants.ACTIONS

    local args = vim.split(vim.trim(CmdLine), '%s+')
    local num_args = #args
    if CmdLine:sub(-1) == ' ' then
      num_args = num_args + 1
    end

    local function filter_candidates(candidates)
      return vim.tbl_filter(function(cmd)
        return cmd:find(ArgLead, 1, true) == 1
      end, candidates)
    end

    local function get_enabled_languages(platform)
      local config = require('cp.config').get_config()
      if platform and config.platforms[platform] then
        return config.platforms[platform].enabled_languages
      end
      return vim.tbl_keys(config.languages)
    end

    if num_args == 2 then
      local candidates = {}
      local state = require('cp.state')
      local platform = state.get_platform()
      local contest_id = state.get_contest_id()

      vim.list_extend(candidates, platforms)
      table.insert(candidates, 'cache')
      table.insert(candidates, 'pick')

      if platform and contest_id then
        vim.list_extend(candidates, actions)
        local cache = require('cp.cache')
        cache.load()
        local contest_data = cache.get_contest_data(platform, contest_id)

        if contest_data and contest_data.index_map then
          local ids = vim.tbl_keys(contest_data.index_map)
          table.sort(ids)
          vim.list_extend(candidates, ids)
        end
      end

      return filter_candidates(candidates)
    elseif num_args == 3 then
      if vim.tbl_contains(platforms, args[2]) then
        local cache = require('cp.cache')
        cache.load()
        local contests = cache.get_cached_contest_ids(args[2])
        return filter_candidates(contests)
      elseif args[2] == 'cache' then
        return filter_candidates({ 'clear', 'read' })
      elseif args[2] == 'interact' then
        local utils = require('cp.utils')
        return filter_candidates(utils.cwd_executables())
      elseif args[2] == 'edit' then
        local state = require('cp.state')
        local platform = state.get_platform()
        local contest_id = state.get_contest_id()
        local problem_id = state.get_problem_id()
        local candidates = {}
        if platform and contest_id and problem_id then
          local cache = require('cp.cache')
          cache.load()
          local test_cases = cache.get_test_cases(platform, contest_id, problem_id)
          if test_cases then
            for i = 1, #test_cases do
              table.insert(candidates, tostring(i))
            end
          end
        end
        return filter_candidates(candidates)
      elseif args[2] == 'run' or args[2] == 'panel' then
        local state = require('cp.state')
        local platform = state.get_platform()
        local contest_id = state.get_contest_id()
        local problem_id = state.get_problem_id()
        local candidates = { '--debug' }
        if platform and contest_id and problem_id then
          local cache = require('cp.cache')
          cache.load()
          local test_cases = cache.get_test_cases(platform, contest_id, problem_id)
          if test_cases then
            for i = 1, #test_cases do
              table.insert(candidates, tostring(i))
            end
          end
        end
        return filter_candidates(candidates)
      elseif args[2] == 'next' or args[2] == 'prev' or args[2] == 'pick' then
        return filter_candidates({ '--lang' })
      else
        local state = require('cp.state')
        if state.get_platform() and state.get_contest_id() then
          return filter_candidates({ '--lang' })
        end
      end
    elseif num_args == 4 then
      if args[2] == 'cache' and args[3] == 'clear' then
        local candidates = vim.list_extend({}, platforms)
        table.insert(candidates, '')
        return filter_candidates(candidates)
      elseif args[3] == '--lang' then
        local platform = require('cp.state').get_platform()
        return filter_candidates(get_enabled_languages(platform))
      elseif (args[2] == 'run' or args[2] == 'panel') and tonumber(args[3]) then
        return filter_candidates({ '--debug' })
      elseif vim.tbl_contains(platforms, args[2]) then
        local cache = require('cp.cache')
        cache.load()
        local contest_data = cache.get_contest_data(args[2], args[3])
        local candidates = { '--lang' }
        if contest_data and contest_data.problems then
          for _, problem in ipairs(contest_data.problems) do
            table.insert(candidates, problem.id)
          end
        end
        return filter_candidates(candidates)
      end
    elseif num_args == 5 then
      if args[2] == 'cache' and args[3] == 'clear' and vim.tbl_contains(platforms, args[4]) then
        local cache = require('cp.cache')
        cache.load()
        local contests = cache.get_cached_contest_ids(args[4])
        return filter_candidates(contests)
      elseif vim.tbl_contains(platforms, args[2]) then
        if args[4] == '--lang' then
          return filter_candidates(get_enabled_languages(args[2]))
        else
          return filter_candidates({ '--lang' })
        end
      end
    elseif num_args == 6 then
      if vim.tbl_contains(platforms, args[2]) and args[5] == '--lang' then
        return filter_candidates(get_enabled_languages(args[2]))
      end
    end
    return {}
  end,
})

local function cp_action(action)
  return function()
    require('cp').handle_command({ fargs = { action } })
  end
end

vim.keymap.set('n', '<Plug>(cp-run)', cp_action('run'), { desc = 'CP run tests' })
vim.keymap.set('n', '<Plug>(cp-panel)', cp_action('panel'), { desc = 'CP open panel' })
vim.keymap.set('n', '<Plug>(cp-edit)', cp_action('edit'), { desc = 'CP edit test cases' })
vim.keymap.set('n', '<Plug>(cp-next)', cp_action('next'), { desc = 'CP next problem' })
vim.keymap.set('n', '<Plug>(cp-prev)', cp_action('prev'), { desc = 'CP previous problem' })
vim.keymap.set('n', '<Plug>(cp-pick)', cp_action('pick'), { desc = 'CP pick contest' })
vim.keymap.set('n', '<Plug>(cp-interact)', cp_action('interact'), { desc = 'CP interactive mode' })
