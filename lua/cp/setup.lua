local M = {}

local cache = require('cp.cache')
local config_module = require('cp.config')
local constants = require('cp.constants')
local helpers = require('cp.helpers')
local logger = require('cp.log')
local scraper = require('cp.scraper')
local state = require('cp.state')

local function apply_template(bufnr, lang_id, platform)
  local config = config_module.get_config()
  local eff = config.runtime.effective[platform]
    and config.runtime.effective[platform][lang_id]
  if not eff or not eff.template then
    return
  end
  local path = vim.fn.expand(eff.template)
  if vim.fn.filereadable(path) ~= 1 then
    logger.log(
      ('[cp.nvim] template not readable: %s'):format(path),
      vim.log.levels.WARN
    )
    return
  end
  local lines = vim.fn.readfile(path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

---Get the language of the current file from cache
---@return string?
local function get_current_file_language()
  local current_file = vim.fn.expand('%:p')
  if current_file == '' then
    return nil
  end
  cache.load()
  local file_state = cache.get_file_state(current_file)
  return file_state and file_state.language or nil
end

---Check if a problem file exists for any enabled language
---@param platform string
---@param contest_id string
---@param problem_id string
---@return string?
local function get_existing_problem_language(platform, contest_id, problem_id)
  local config = config_module.get_config()
  local platform_config = config.platforms[platform]
  if not platform_config then
    return nil
  end

  for _, lang_id in ipairs(platform_config.enabled_languages) do
    local effective = config.runtime.effective[platform][lang_id]
    if effective and effective.extension then
      local basename = config.filename
          and config.filename(platform, contest_id, problem_id, config, lang_id)
        or config_module.default_filename(contest_id, problem_id)
      local filepath = basename .. '.' .. effective.extension
      if vim.fn.filereadable(filepath) == 1 then
        return lang_id
      end
    end
  end

  return nil
end

---@class TestCaseLite
---@field input string
---@field expected string

---@class ScrapeEvent
---@field problem_id string
---@field tests TestCaseLite[]|nil
---@field timeout_ms integer|nil
---@field memory_mb integer|nil
---@field interactive boolean|nil
---@field error string|nil
---@field done boolean|nil
---@field succeeded integer|nil
---@field failed integer|nil

---@param cd table|nil
---@return boolean
local function is_metadata_ready(cd)
  return cd
      and type(cd.problems) == 'table'
      and #cd.problems > 0
      and type(cd.index_map) == 'table'
      and next(cd.index_map) ~= nil
    or false
end

---@param platform string
---@param contest_id string
---@param problems table
local function start_tests(platform, contest_id, problems)
  local cached_len = #vim.tbl_filter(function(p)
    return not vim.tbl_isempty(cache.get_test_cases(platform, contest_id, p.id))
  end, problems)
  if cached_len ~= #problems then
    logger.log(('Fetching %s/%s problem tests...'):format(cached_len, #problems))
    scraper.scrape_all_tests(platform, contest_id, function(ev)
      local cached_tests = {}
      if not ev.interactive and vim.tbl_isempty(ev.tests) then
        logger.log(("No tests found for problem '%s'."):format(ev.problem_id), vim.log.levels.WARN)
      end
      for i, t in ipairs(ev.tests) do
        cached_tests[i] = { index = i, input = t.input, expected = t.expected }
      end
      cache.set_test_cases(
        platform,
        contest_id,
        ev.problem_id,
        ev.combined,
        cached_tests,
        ev.timeout_ms or 0,
        ev.memory_mb or 0,
        ev.interactive,
        ev.multi_test
      )

      local io_state = state.get_io_view_state()
      if io_state then
        local combined_test = cache.get_combined_test(platform, contest_id, state.get_problem_id())
        if combined_test then
          local input_lines = vim.split(combined_test.input, '\n')
          require('cp.utils').update_buffer_content(io_state.input_buf, input_lines, nil, nil)
        end
      end
    end)
  end
end

---@param platform string
---@param contest_id string
---@param problem_id? string
---@param language? string
function M.setup_contest(platform, contest_id, problem_id, language)
  local old_platform, old_contest_id = state.get_platform(), state.get_contest_id()
  local old_problem_id = state.get_problem_id()

  state.set_platform(platform)
  state.set_contest_id(contest_id)

  if language then
    local lang_result = config_module.get_language_for_platform(platform, language)
    if not lang_result.valid then
      logger.log(lang_result.error, vim.log.levels.ERROR)
      return
    end
  end

  local is_new_contest = old_platform ~= platform or old_contest_id ~= contest_id

  cache.load()

  local function proceed(contest_data)
    local problems = contest_data.problems
    local pid = problem_id and problem_id or problems[1].id
    M.setup_problem(pid, language)
    start_tests(platform, contest_id, problems)

    local is_new_problem = old_problem_id ~= pid
    local should_open_url = config_module.get_config().open_url
      and (is_new_contest or is_new_problem)
    if should_open_url and contest_data.url then
      vim.ui.open(contest_data.url:format(pid))
    end
  end

  local contest_data = cache.get_contest_data(platform, contest_id)
  if not is_metadata_ready(contest_data) then
    local cfg = config_module.get_config()
    local lang = language or (cfg.platforms[platform] and cfg.platforms[platform].default_language)

    vim.cmd.only({ mods = { silent = true } })
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.bo[bufnr].filetype = lang or ''
    vim.bo[bufnr].buftype = ''
    vim.bo[bufnr].swapfile = false

    state.set_language(lang)

    if cfg.hooks and cfg.hooks.setup_code and not vim.b[bufnr].cp_setup_done then
      local ok = pcall(cfg.hooks.setup_code, state)
      if ok then
        vim.b[bufnr].cp_setup_done = true
      end
    end

    state.set_provisional({
      bufnr = bufnr,
      platform = platform,
      contest_id = contest_id,
      language = lang,
      requested_problem_id = problem_id,
      token = vim.loop.hrtime(),
    })

    logger.log('Fetching contests problems...', vim.log.levels.INFO, true)
    scraper.scrape_contest_metadata(
      platform,
      contest_id,
      vim.schedule_wrap(function(result)
        local problems = result.problems or {}
        cache.set_contest_data(platform, contest_id, problems, result.url)
        local prov = state.get_provisional()
        if not prov or prov.platform ~= platform or prov.contest_id ~= contest_id then
          return
        end
        local cd = cache.get_contest_data(platform, contest_id)
        if not is_metadata_ready(cd) then
          return
        end
        local pid = prov.requested_problem_id
        if not pid or not cd.index_map or not cd.index_map[pid] then
          pid = cd.problems[1] and cd.problems[1].id or nil
        end
        if not pid then
          return
        end
        proceed(cd)
      end)
    )
    return
  end

  proceed(contest_data)
end

---@param problem_id string
---@param language? string
function M.setup_problem(problem_id, language)
  local platform = state.get_platform()
  if not platform then
    logger.log('No platform/contest/problem configured.', vim.log.levels.ERROR)
    return
  end

  local old_problem_id = state.get_problem_id()
  state.set_problem_id(problem_id)

  if old_problem_id ~= problem_id then
    local io_state = state.get_io_view_state()
    if io_state and io_state.output_buf and vim.api.nvim_buf_is_valid(io_state.output_buf) then
      local utils = require('cp.utils')
      utils.update_buffer_content(io_state.output_buf, {}, nil, nil)
    end
  end
  local config = config_module.get_config()
  local lang = language
    or (config.platforms[platform] and config.platforms[platform].default_language)

  if language then
    local lang_result = config_module.get_language_for_platform(platform, language)
    if not lang_result.valid then
      logger.log(lang_result.error, vim.log.levels.ERROR)
      return
    end
  end

  state.set_language(lang)

  local source_file = state.get_source_file(lang)
  if not source_file then
    return
  end

  vim.fn.mkdir(vim.fn.fnamemodify(source_file, ':h'), 'p')

  local prov = state.get_provisional()
  if prov and prov.platform == platform and prov.contest_id == (state.get_contest_id() or '') then
    if vim.api.nvim_buf_is_valid(prov.bufnr) then
      local existing_bufnr = vim.fn.bufnr(source_file)
      if existing_bufnr ~= -1 then
        vim.api.nvim_buf_delete(prov.bufnr, { force = true })
        state.set_provisional(nil)
      else
        vim.api.nvim_buf_set_name(prov.bufnr, source_file)
        vim.bo[prov.bufnr].swapfile = true
        -- selene: allow(mixed_table)
        vim.cmd.write({
          vim.fn.fnameescape(source_file),
          bang = true,
          mods = { silent = true, noautocmd = true, keepalt = true },
        })
        state.set_solution_win(vim.api.nvim_get_current_win())
        if not vim.b[prov.bufnr].cp_setup_done then
          apply_template(prov.bufnr, lang, platform)
          if config.hooks and config.hooks.setup_code then
            local ok = pcall(config.hooks.setup_code, state)
            if ok then
              vim.b[prov.bufnr].cp_setup_done = true
            end
          else
            helpers.clearcol(prov.bufnr)
            vim.b[prov.bufnr].cp_setup_done = true
          end
        end
        cache.set_file_state(
          vim.fn.fnamemodify(source_file, ':p'),
          platform,
          state.get_contest_id() or '',
          state.get_problem_id() or '',
          lang
        )
        require('cp.ui.views').ensure_io_view()
        state.set_provisional(nil)
        return
      end
    else
      state.set_provisional(nil)
    end
  end

  vim.cmd.only({ mods = { silent = true } })
  vim.cmd.e(source_file)
  local bufnr = vim.api.nvim_get_current_buf()
  state.set_solution_win(vim.api.nvim_get_current_win())
  require('cp.ui.views').ensure_io_view()
  if not vim.b[bufnr].cp_setup_done then
    local is_new = vim.api.nvim_buf_line_count(bufnr) == 1
      and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ''
    if is_new then
      apply_template(bufnr, lang, platform)
    end
    if config.hooks and config.hooks.setup_code then
      local ok = pcall(config.hooks.setup_code, state)
      if ok then
        vim.b[bufnr].cp_setup_done = true
      end
    else
      helpers.clearcol(bufnr)
      vim.b[bufnr].cp_setup_done = true
    end
  end
  cache.set_file_state(
    vim.fn.expand('%:p'),
    platform,
    state.get_contest_id() or '',
    state.get_problem_id() or '',
    lang
  )
end

---@param direction integer
---@param language? string
function M.navigate_problem(direction, language)
  if direction == 0 then
    return
  end
  direction = direction > 0 and 1 or -1

  local platform = state.get_platform()
  local contest_id = state.get_contest_id()
  local current_problem_id = state.get_problem_id()
  if not platform or not contest_id or not current_problem_id then
    logger.log('No platform configured.', vim.log.levels.ERROR)
    return
  end

  cache.load()
  local contest_data = cache.get_contest_data(platform, contest_id)
  if not is_metadata_ready(contest_data) then
    logger.log(
      ('No data available for %s contest %s.'):format(
        constants.PLATFORM_DISPLAY_NAMES[platform],
        contest_id
      ),
      vim.log.levels.ERROR
    )
    return
  end

  local problems = contest_data.problems
  local index = contest_data.index_map[current_problem_id]
  local new_index = index + direction
  if new_index < 1 or new_index > #problems then
    return
  end

  logger.log(('navigate_problem: %s -> %s'):format(current_problem_id, problems[new_index].id))

  local active_panel = state.get_active_panel()
  if active_panel == 'run' then
    require('cp.ui.views').disable()
  end

  local lang = nil

  if language then
    local lang_result = config_module.get_language_for_platform(platform, language)
    if not lang_result.valid then
      logger.log(lang_result.error, vim.log.levels.ERROR)
      return
    end
    lang = language
  else
    local existing_lang =
      get_existing_problem_language(platform, contest_id, problems[new_index].id)
    if existing_lang then
      lang = existing_lang
    else
      lang = get_current_file_language()
      if lang then
        local lang_result = config_module.get_language_for_platform(platform, lang)
        if not lang_result.valid then
          lang = nil
        end
      end
    end
  end

  local io_state = state.get_io_view_state()
  if io_state and io_state.output_buf and vim.api.nvim_buf_is_valid(io_state.output_buf) then
    local utils = require('cp.utils')
    utils.update_buffer_content(io_state.output_buf, {}, nil, nil)
  end

  M.setup_contest(platform, contest_id, problems[new_index].id, lang)
end

return M
