local M = {}

local cache = require('cp.cache')
local constants = require('cp.constants')
local logger = require('cp.log')
local scraper = require('cp.scraper')

---@class cp.PlatformItem
---@field id string Platform identifier (e.g. "codeforces", "atcoder", "cses")
---@field display_name string Human-readable platform name (e.g. "Codeforces", "AtCoder", "CSES")

---@class cp.ContestItem
---@field id string Contest identifier (e.g. "1951", "abc324", "sorting")
---@field name string Full contest name (e.g. "Educational Codeforces Round 168")
---@field display_name string Formatted display name for picker

---@class cp.ProblemItem
---@field id string Problem identifier (e.g. "a", "b", "c")
---@field name string Problem name (e.g. "Two Permutations", "Painting Walls")
---@field display_name string Formatted display name for picker

---@return cp.PlatformItem[]
function M.get_platforms()
  local config = require('cp.config').get_config()
  local result = {}
  for _, platform in ipairs(constants.PLATFORMS) do
    if config.platforms[platform] then
      table.insert(result, {
        id = platform,
        display_name = constants.PLATFORM_DISPLAY_NAMES[platform] or platform,
      })
    end
  end
  return result
end

---@param platform string
---@param refresh? boolean
---@return cp.ContestItem[]
function M.get_platform_contests(platform, refresh)
  cache.load()
  local picker_contests = cache.get_contest_summaries(platform)

  if refresh or vim.tbl_isempty(picker_contests) then
    local display_name = constants.PLATFORM_DISPLAY_NAMES[platform]
    logger.log(('Fetching %s contests...'):format(display_name), { level = vim.log.levels.INFO, override = true, sync = true })

    local contests = scraper.scrape_contest_list(platform)
    cache.set_contest_summaries(platform, contests)
    picker_contests = cache.get_contest_summaries(platform)

    logger.log(('Fetched %d %s contests.'):format(#picker_contests, display_name), { level = vim.log.levels.INFO, override = true })
  end

  return picker_contests
end

return M
