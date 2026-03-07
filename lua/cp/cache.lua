---@class FileState
---@field platform string
---@field contest_id string
---@field problem_id? string
---@field language? string

---@class ContestData
---@field problems Problem[]
---@field index_map table<string, number>
---@field name string
---@field display_name string
---@field url string
---@field contest_url string
---@field standings_url string

---@class ContestSummary
---@field display_name string
---@field name string
---@field id string
---@field start_time? integer

---@class CombinedTest
---@field input string
---@field expected string

---@class Problem
---@field id string
---@field name? string
---@field interactive? boolean
---@field multi_test? boolean
---@field memory_mb? number
---@field timeout_ms? number
---@field precision? number
---@field combined_test? CombinedTest
---@field test_cases TestCase[]

---@class TestCase
---@field index? number
---@field expected? string
---@field input? string
---@field output? string

local M = {}

local CACHE_VERSION = 2

local cache_file = vim.fn.stdpath('data') .. '/cp-nvim.json'
local cache_data = {}
local loaded = false

--- Load the cache from disk if not done already
---@return nil
function M.load()
  if loaded then
    return
  end

  if vim.fn.filereadable(cache_file) == 0 then
    vim.fn.writefile({}, cache_file)
    vim.fn.setfperm(cache_file, 'rw-------')
    loaded = true
    return
  end

  local content = vim.fn.readfile(cache_file)
  if #content == 0 then
    cache_data = {}
    loaded = true
    return
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(content, '\n'))
  if not ok then
    cache_data = {}
    M.save()
    loaded = true
    return
  end

  if decoded._version == 1 then
    local old_creds = decoded._credentials
    decoded._credentials = nil
    if old_creds then
      for platform, creds in pairs(old_creds) do
        decoded[platform] = decoded[platform] or {}
        decoded[platform]._credentials = creds
      end
    end
    decoded._version = CACHE_VERSION
    cache_data = decoded
    M.save()
  elseif decoded._version == CACHE_VERSION then
    cache_data = decoded
  else
    cache_data = {}
    M.save()
  end
  loaded = true
end

--- Save the cache to disk, overwriting existing contents
---@return nil
function M.save()
  vim.schedule(function()
    vim.fn.mkdir(vim.fn.fnamemodify(cache_file, ':h'), 'p')

    cache_data._version = CACHE_VERSION
    local encoded = vim.json.encode(cache_data)
    local lines = vim.split(encoded, '\n')
    vim.fn.writefile(lines, cache_file)
    vim.fn.setfperm(cache_file, 'rw-------')
  end)
end

---@param platform string
---@param contest_id string
---@return ContestData
function M.get_contest_data(platform, contest_id)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
  })

  cache_data[platform] = cache_data[platform] or {}
  cache_data[platform][contest_id] = cache_data[platform][contest_id] or {}
  return cache_data[platform][contest_id]
end

---Get all cached contest IDs for a platform
---@param platform string
---@return string[]
function M.get_cached_contest_ids(platform)
  vim.validate({
    platform = { platform, 'string' },
  })

  if not cache_data[platform] then
    return {}
  end

  local contest_ids = {}
  for contest_id, _ in pairs(cache_data[platform]) do
    if contest_id:sub(1, 1) ~= '_' then
      table.insert(contest_ids, contest_id)
    end
  end
  table.sort(contest_ids)
  return contest_ids
end

---@param platform string
---@param contest_id string
---@param problems Problem[]
---@param url string
---@param contest_url string
---@param standings_url string
function M.set_contest_data(platform, contest_id, problems, url, contest_url, standings_url)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
    problems = { problems, 'table' },
    url = { url, 'string' },
    contest_url = { contest_url, 'string' },
    standings_url = { standings_url, 'string' },
  })

  cache_data[platform] = cache_data[platform] or {}
  local prev = cache_data[platform][contest_id] or {}

  local out = {
    name = prev.name,
    display_name = prev.display_name,
    problems = problems,
    index_map = {},
    url = url,
    contest_url = contest_url,
    standings_url = standings_url,
  }
  for i, p in ipairs(out.problems) do
    out.index_map[p.id] = i
  end

  cache_data[platform][contest_id] = out
  M.save()
end

---@param platform string?
---@param contest_id string?
---@param problem_id string?
---@return { problem: string|nil, contest: string|nil, standings: string|nil }|nil
function M.get_open_urls(platform, contest_id, problem_id)
  if not platform or not contest_id then
    return nil
  end
  if not cache_data[platform] or not cache_data[platform][contest_id] then
    return nil
  end
  local cd = cache_data[platform][contest_id]
  return {
    problem = cd.url ~= '' and problem_id and string.format(cd.url, problem_id) or nil,
    contest = cd.contest_url ~= '' and cd.contest_url or nil,
    standings = cd.standings_url ~= '' and cd.standings_url or nil,
  }
end

---@param platform string
---@param contest_id string
function M.clear_contest_data(platform, contest_id)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
  })

  if cache_data[platform] and cache_data[platform][contest_id] then
    cache_data[platform][contest_id] = nil
    M.save()
  end
end

---@param platform string
---@param contest_id string
---@param problem_id? string
---@return TestCase[]
function M.get_test_cases(platform, contest_id, problem_id)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
    problem_id = { problem_id, { 'string', 'nil' }, true },
  })

  if
    not cache_data[platform]
    or not cache_data[platform][contest_id]
    or not cache_data[platform][contest_id].problems
    or not cache_data[platform][contest_id].index_map
  then
    return {}
  end

  local index = cache_data[platform][contest_id].index_map[problem_id]
  return cache_data[platform][contest_id].problems[index].test_cases or {}
end

---@param platform string
---@param contest_id string
---@param problem_id? string
---@return CombinedTest?
function M.get_combined_test(platform, contest_id, problem_id)
  if
    not cache_data[platform]
    or not cache_data[platform][contest_id]
    or not cache_data[platform][contest_id].problems
    or not cache_data[platform][contest_id].index_map
  then
    return nil
  end

  local index = cache_data[platform][contest_id].index_map[problem_id]
  return cache_data[platform][contest_id].problems[index].combined_test
end

---@param platform string
---@param contest_id string
---@param problem_id string
---@param combined_test? CombinedTest
---@param test_cases TestCase[]
---@param timeout_ms number
---@param memory_mb number
---@param interactive boolean
---@param multi_test boolean
---@param precision number?
function M.set_test_cases(
  platform,
  contest_id,
  problem_id,
  combined_test,
  test_cases,
  timeout_ms,
  memory_mb,
  interactive,
  multi_test,
  precision
)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
    problem_id = { problem_id, { 'string', 'nil' }, true },
    combined_test = { combined_test, { 'table', 'nil' }, true },
    test_cases = { test_cases, 'table' },
    timeout_ms = { timeout_ms, { 'number', 'nil' }, true },
    memory_mb = { memory_mb, { 'number', 'nil' }, true },
    interactive = { interactive, { 'boolean', 'nil' }, true },
    multi_test = { multi_test, { 'boolean', 'nil' }, true },
    precision = { precision, { 'number', 'nil' }, true },
  })

  local index = cache_data[platform][contest_id].index_map[problem_id]

  cache_data[platform][contest_id].problems[index].combined_test = combined_test
  cache_data[platform][contest_id].problems[index].test_cases = test_cases
  cache_data[platform][contest_id].problems[index].timeout_ms = timeout_ms
  cache_data[platform][contest_id].problems[index].memory_mb = memory_mb
  cache_data[platform][contest_id].problems[index].interactive = interactive
  cache_data[platform][contest_id].problems[index].multi_test = multi_test
  cache_data[platform][contest_id].problems[index].precision = precision

  M.save()
end

---@param platform string
---@param contest_id string
---@param problem_id? string
---@return number?, number?
function M.get_constraints(platform, contest_id, problem_id)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
    problem_id = { problem_id, { 'string', 'nil' }, true },
  })

  local index = cache_data[platform][contest_id].index_map[problem_id]

  local problem_data = cache_data[platform][contest_id].problems[index]
  return problem_data.timeout_ms, problem_data.memory_mb
end

---@param platform string
---@param contest_id string
---@param problem_id? string
---@return number?
function M.get_precision(platform, contest_id, problem_id)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
    problem_id = { problem_id, { 'string', 'nil' }, true },
  })

  if
    not cache_data[platform]
    or not cache_data[platform][contest_id]
    or not cache_data[platform][contest_id].index_map
  then
    return nil
  end

  local index = cache_data[platform][contest_id].index_map[problem_id]
  if not index then
    return nil
  end

  local problem_data = cache_data[platform][contest_id].problems[index]
  return problem_data and problem_data.precision or nil
end

---@param file_path string
---@return FileState|nil
function M.get_file_state(file_path)
  M.load()
  cache_data.file_states = cache_data.file_states or {}
  return cache_data.file_states[file_path]
end

---@param path string
---@param platform string
---@param contest_id string
---@param problem_id string
---@param language string|nil
function M.set_file_state(path, platform, contest_id, problem_id, language)
  M.load()
  cache_data.file_states = cache_data.file_states or {}
  cache_data.file_states[path] = {
    platform = platform,
    contest_id = contest_id,
    problem_id = problem_id,
    language = language,
  }
  M.save()
end

---@param platform string
---@return ContestSummary[]
function M.get_contest_summaries(platform)
  local contest_list = {}
  for contest_id, contest_data in pairs(cache_data[platform] or {}) do
    if type(contest_data) == 'table' and contest_id:sub(1, 1) ~= '_' then
      table.insert(contest_list, {
        id = contest_id,
        name = contest_data.name,
        display_name = contest_data.display_name,
      })
    end
  end
  return contest_list
end

---@param platform string
---@param contests ContestSummary[]
---@param opts? { supports_countdown?: boolean }
function M.set_contest_summaries(platform, contests, opts)
  cache_data[platform] = cache_data[platform] or {}
  for _, contest in ipairs(contests) do
    cache_data[platform][contest.id] = cache_data[platform][contest.id] or {}
    cache_data[platform][contest.id].display_name = (
      contest.display_name ~= vim.NIL and contest.display_name
    ) or contest.name
    cache_data[platform][contest.id].name = contest.name
    if contest.start_time and contest.start_time ~= vim.NIL then
      cache_data[platform][contest.id].start_time = contest.start_time
    end
  end

  if opts and opts.supports_countdown ~= nil then
    cache_data[platform].supports_countdown = opts.supports_countdown
  end

  M.save()
end

---@param platform string
---@return boolean?
function M.get_supports_countdown(platform)
  if not cache_data[platform] then
    return nil
  end
  return cache_data[platform].supports_countdown
end

---@param platform string
---@param contest_id string
---@return integer?
function M.get_contest_start_time(platform, contest_id)
  if not cache_data[platform] or not cache_data[platform][contest_id] then
    return nil
  end
  return cache_data[platform][contest_id].start_time
end

---@param platform string
---@param contest_id string
---@return string?
function M.get_contest_display_name(platform, contest_id)
  if not cache_data[platform] or not cache_data[platform][contest_id] then
    return nil
  end
  return cache_data[platform][contest_id].display_name
end

---@param platform string
---@return table?
function M.get_credentials(platform)
  if not cache_data[platform] then
    return nil
  end
  return cache_data[platform]._credentials
end

---@param platform string
---@param creds table
function M.set_credentials(platform, creds)
  cache_data[platform] = cache_data[platform] or {}
  cache_data[platform]._credentials = creds
  M.save()
end

---@param platform string
function M.clear_credentials(platform)
  if cache_data[platform] then
    cache_data[platform]._credentials = nil
  end
  M.save()
end

---@return nil
function M.clear_all()
  cache_data = {}
  M.save()
end

---@param platform string
function M.clear_platform(platform)
  if cache_data[platform] then
    cache_data[platform] = nil
  end

  M.save()
end

---@return string
function M.get_data_pretty()
  M.load()

  return vim.inspect(cache_data)
end

---@return table
function M.get_raw_cache()
  return cache_data
end

return M
