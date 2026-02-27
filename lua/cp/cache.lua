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

---@class ContestSummary
---@field display_name string
---@field name string
---@field id string

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
---@field epsilon? number
---@field combined_test? CombinedTest
---@field test_cases TestCase[]

---@class TestCase
---@field index? number
---@field expected? string
---@field input? string
---@field output? string

local M = {}

local CACHE_VERSION = 1

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
  if ok then
    if decoded._version ~= CACHE_VERSION then
      cache_data = {}
      M.save()
    else
      cache_data = decoded
    end
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
    table.insert(contest_ids, contest_id)
  end
  table.sort(contest_ids)
  return contest_ids
end

---@param platform string
---@param contest_id string
---@param problems Problem[]
---@param url string
function M.set_contest_data(platform, contest_id, problems, url)
  vim.validate({
    platform = { platform, 'string' },
    contest_id = { contest_id, 'string' },
    problems = { problems, 'table' },
    url = { url, 'string' },
  })

  cache_data[platform] = cache_data[platform] or {}
  local prev = cache_data[platform][contest_id] or {}

  local out = {
    name = prev.name,
    display_name = prev.display_name,
    problems = problems,
    index_map = {},
    url = url,
  }
  for i, p in ipairs(out.problems) do
    out.index_map[p.id] = i
  end

  cache_data[platform][contest_id] = out
  M.save()
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
function M.set_test_cases(
  platform,
  contest_id,
  problem_id,
  combined_test,
  test_cases,
  timeout_ms,
  memory_mb,
  interactive,
  multi_test
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
  })

  local index = cache_data[platform][contest_id].index_map[problem_id]

  cache_data[platform][contest_id].problems[index].combined_test = combined_test
  cache_data[platform][contest_id].problems[index].test_cases = test_cases
  cache_data[platform][contest_id].problems[index].timeout_ms = timeout_ms
  cache_data[platform][contest_id].problems[index].memory_mb = memory_mb
  cache_data[platform][contest_id].problems[index].interactive = interactive
  cache_data[platform][contest_id].problems[index].multi_test = multi_test

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
function M.get_epsilon(platform, contest_id, problem_id)
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
  return problem_data and problem_data.epsilon or nil
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
    table.insert(contest_list, {
      id = contest_id,
      name = contest_data.name,
      display_name = contest_data.display_name,
    })
  end
  return contest_list
end

---@param platform string
---@param contests ContestSummary[]
function M.set_contest_summaries(platform, contests)
  cache_data[platform] = cache_data[platform] or {}
  for _, contest in ipairs(contests) do
    cache_data[platform][contest.id] = cache_data[platform][contest.id] or {}
    cache_data[platform][contest.id].display_name = contest.display_name
    cache_data[platform][contest.id].name = contest.name
  end

  M.save()
end

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

function M.get_raw_cache()
  return cache_data
end

return M
