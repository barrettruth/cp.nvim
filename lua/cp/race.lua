local M = {}

local cache = require('cp.cache')
local constants = require('cp.constants')
local logger = require('cp.log')
local scraper = require('cp.scraper')

local REFETCH_INTERVAL_S = 600
local RETRY_DELAY_MS = 3000
local MAX_RETRY_ATTEMPTS = 15

local race_state = {
  timer = nil,
  token = nil,
  platform = nil,
  contest_id = nil,
  contest_name = nil,
  language = nil,
  start_time = nil,
  last_refetch = nil,
}

local function format_countdown(seconds)
  local d = math.floor(seconds / 86400)
  local h = math.floor((seconds % 86400) / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if d > 0 then
    return string.format('%dd%dh%dm%ds', d, h, m, s)
  elseif h > 0 then
    return string.format('%dh%dm%ds', h, m, s)
  elseif m > 0 then
    return string.format('%dm%ds', m, s)
  end
  return string.format('%ds', s)
end

local function should_notify(remaining)
  if remaining > 3600 then
    return remaining % 900 == 0
  end
  if remaining > 300 then
    return remaining % 60 == 0
  end
  if remaining > 60 then
    return remaining % 10 == 0
  end
  return true
end

local function refetch_start_time()
  local result = scraper.scrape_contest_list(race_state.platform)
  if not result or not result.contests or #result.contests == 0 then
    return
  end
  cache.set_contest_summaries(
    race_state.platform,
    result.contests,
    { supports_countdown = result.supports_countdown }
  )
  local new_time = cache.get_contest_start_time(race_state.platform, race_state.contest_id)
  if new_time and new_time ~= race_state.start_time then
    race_state.start_time = new_time
    race_state.contest_name = cache.get_contest_display_name(
      race_state.platform,
      race_state.contest_id
    ) or race_state.contest_id
  end
end

local function race_try_setup(platform, contest_id, language, attempt, token)
  if race_state.token ~= token then
    return
  end

  cache.load()
  local cd = cache.get_contest_data(platform, contest_id)
  if
    cd
    and type(cd.problems) == 'table'
    and #cd.problems > 0
    and type(cd.index_map) == 'table'
    and next(cd.index_map) ~= nil
  then
    require('cp.setup').setup_contest(platform, contest_id, nil, language)
    return
  end

  local display = constants.PLATFORM_DISPLAY_NAMES[platform] or platform
  if attempt > 1 then
    logger.log(
      ('Retrying %s "%s" setup (attempt %d/%d)...'):format(
        display,
        contest_id,
        attempt,
        MAX_RETRY_ATTEMPTS
      ),
      { level = vim.log.levels.WARN }
    )
  end

  scraper.scrape_contest_metadata(
    platform,
    contest_id,
    vim.schedule_wrap(function(data)
      if race_state.token ~= token then
        return
      end
      cache.set_contest_data(
        platform,
        contest_id,
        data.problems or {},
        data.url or '',
        data.contest_url or '',
        data.standings_url or ''
      )
      require('cp.setup').setup_contest(platform, contest_id, nil, language)
    end),
    vim.schedule_wrap(function()
      if race_state.token ~= token then
        return
      end
      if attempt >= MAX_RETRY_ATTEMPTS then
        logger.log(
          ('Failed to load %s contest "%s" after %d attempts'):format(display, contest_id, attempt),
          { level = vim.log.levels.ERROR }
        )
        return
      end
      vim.defer_fn(function()
        race_try_setup(platform, contest_id, language, attempt + 1, token)
      end, RETRY_DELAY_MS)
    end)
  )
end

function M.start(platform, contest_id, language)
  if not platform or not vim.tbl_contains(constants.PLATFORMS, platform) then
    logger.log('Invalid platform', { level = vim.log.levels.ERROR })
    return
  end
  if not contest_id or contest_id == '' then
    logger.log('Contest ID required', { level = vim.log.levels.ERROR })
    return
  end
  if race_state.timer then
    M.stop()
  end

  cache.load()

  local display = constants.PLATFORM_DISPLAY_NAMES[platform] or platform
  local cached_countdown = cache.get_supports_countdown(platform)
  if cached_countdown == false then
    logger.log(('%s does not support --race'):format(display), { level = vim.log.levels.ERROR })
    return
  end

  local start_time = cache.get_contest_start_time(platform, contest_id)

  if not start_time then
    logger.log(
      'Fetching contest list...',
      { level = vim.log.levels.INFO, override = true, sync = true }
    )
    local result = scraper.scrape_contest_list(platform)
    if result then
      local sc = result.supports_countdown
      if sc == false then
        cache.set_contest_summaries(platform, result.contests or {}, { supports_countdown = false })
        logger.log(('%s does not support --race'):format(display), { level = vim.log.levels.ERROR })
        return
      end
      if result.contests and #result.contests > 0 then
        cache.set_contest_summaries(platform, result.contests, { supports_countdown = sc })
        start_time = cache.get_contest_start_time(platform, contest_id)
      end
    end
  end

  if not start_time then
    logger.log(
      ('No start time found for %s contest "%s"'):format(display, contest_id),
      { level = vim.log.levels.ERROR }
    )
    return
  end

  local token = vim.uv.hrtime()
  local remaining = start_time - os.time()
  if remaining <= 0 then
    logger.log(
      'Contest has already started, setting up...',
      { level = vim.log.levels.INFO, override = true }
    )
    race_state.token = token
    race_try_setup(platform, contest_id, language, 1, token)
    return
  end

  race_state.platform = platform
  race_state.contest_id = contest_id
  race_state.contest_name = cache.get_contest_display_name(platform, contest_id) or contest_id
  race_state.language = language
  race_state.start_time = start_time
  race_state.last_refetch = os.time()
  race_state.token = token

  local timer = vim.uv.new_timer()
  race_state.timer = timer
  timer:start(
    0,
    1000,
    vim.schedule_wrap(function()
      if race_state.token ~= token then
        return
      end

      local now = os.time()
      if now - race_state.last_refetch >= REFETCH_INTERVAL_S then
        race_state.last_refetch = now
        refetch_start_time()
      end

      local r = race_state.start_time - now
      if r <= 0 then
        timer:stop()
        timer:close()
        race_state.timer = nil
        local p = race_state.platform
        local c = race_state.contest_id
        local l = race_state.language
        race_state.platform = nil
        race_state.contest_id = nil
        race_state.contest_name = nil
        race_state.language = nil
        race_state.start_time = nil
        race_state.last_refetch = nil
        logger.log('Contest started!', { level = vim.log.levels.INFO, override = true })
        race_try_setup(p, c, l, 1, token)
      elseif should_notify(r) then
        vim.notify(
          ('[cp.nvim]: %s race "%s" starts in %s'):format(
            constants.PLATFORM_DISPLAY_NAMES[race_state.platform] or race_state.platform,
            race_state.contest_name,
            format_countdown(r)
          ),
          vim.log.levels.INFO
        )
      end
    end)
  )
end

function M.stop()
  local timer = race_state.timer
  if not timer then
    logger.log('No active race', { level = vim.log.levels.WARN })
    return
  end
  local display = constants.PLATFORM_DISPLAY_NAMES[race_state.platform] or race_state.platform
  local name = race_state.contest_name or race_state.contest_id
  timer:stop()
  timer:close()
  race_state.timer = nil
  race_state.token = nil
  race_state.platform = nil
  race_state.contest_id = nil
  race_state.contest_name = nil
  race_state.language = nil
  race_state.start_time = nil
  race_state.last_refetch = nil
  logger.log(
    ('Cancelled %s race "%s"'):format(display, name),
    { level = vim.log.levels.INFO, override = true }
  )
end

function M.status()
  if not race_state.timer or not race_state.start_time then
    return { active = false }
  end
  return {
    active = true,
    platform = race_state.platform,
    contest_id = race_state.contest_id,
    remaining_seconds = math.max(0, race_state.start_time - os.time()),
  }
end

return M
