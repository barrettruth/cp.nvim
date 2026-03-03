local M = {}

local cache = require('cp.cache')
local constants = require('cp.constants')
local logger = require('cp.log')
local scraper = require('cp.scraper')

local race_state = {
  timer = nil,
  platform = nil,
  contest_id = nil,
  language = nil,
  start_time = nil,
}

local function format_countdown(seconds)
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  return string.format('%02d:%02d:%02d', h, m, s)
end

function M.start(platform, contest_id, language)
  if not platform or not vim.tbl_contains(constants.PLATFORMS, platform) then
    logger.log('Invalid platform', vim.log.levels.ERROR)
    return
  end
  if not contest_id or contest_id == '' then
    logger.log('Contest ID required', vim.log.levels.ERROR)
    return
  end
  if race_state.timer then
    logger.log('Race already active. Use :CP race stop first.', vim.log.levels.WARN)
    return
  end

  cache.load()
  local start_time = cache.get_contest_start_time(platform, contest_id)

  if not start_time then
    logger.log('Fetching contest list...', vim.log.levels.INFO, true)
    local contests = scraper.scrape_contest_list(platform)
    if contests and #contests > 0 then
      cache.set_contest_summaries(platform, contests)
      start_time = cache.get_contest_start_time(platform, contest_id)
    end
  end

  if not start_time then
    logger.log(
      ('No start time found for %s contest %s'):format(
        constants.PLATFORM_DISPLAY_NAMES[platform] or platform,
        contest_id
      ),
      vim.log.levels.ERROR
    )
    return
  end

  local remaining = start_time - os.time()
  if remaining <= 0 then
    logger.log('Contest has already started, setting up...', vim.log.levels.INFO, true)
    require('cp.setup').setup_contest(platform, contest_id, nil, language)
    return
  end

  race_state.platform = platform
  race_state.contest_id = contest_id
  race_state.language = language
  race_state.start_time = start_time

  logger.log(
    ('Race started for %s %s — %s remaining'):format(
      constants.PLATFORM_DISPLAY_NAMES[platform] or platform,
      contest_id,
      format_countdown(remaining)
    ),
    vim.log.levels.INFO,
    true
  )

  local timer = vim.uv.new_timer()
  race_state.timer = timer
  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      local r = race_state.start_time - os.time()
      if r <= 0 then
        timer:stop()
        timer:close()
        race_state.timer = nil
        local p = race_state.platform
        local c = race_state.contest_id
        local l = race_state.language
        race_state.platform = nil
        race_state.contest_id = nil
        race_state.language = nil
        race_state.start_time = nil
        logger.log('Contest started!', vim.log.levels.INFO, true)
        require('cp.setup').setup_contest(p, c, nil, l)
      else
        vim.notify(
          ('[cp.nvim] %s %s — %s'):format(
            constants.PLATFORM_DISPLAY_NAMES[race_state.platform] or race_state.platform,
            race_state.contest_id,
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
    logger.log('No active race', vim.log.levels.WARN)
    return
  end
  timer:stop()
  timer:close()
  race_state.timer = nil
  race_state.platform = nil
  race_state.contest_id = nil
  race_state.language = nil
  race_state.start_time = nil
  logger.log('Race cancelled', vim.log.levels.INFO, true)
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
