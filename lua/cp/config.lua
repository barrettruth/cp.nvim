-- lua/cp/config.lua
---@class CpLangCommands
---@field build? string[]
---@field run? string[]
---@field debug? string[]

---@class CpLanguage
---@field extension string
---@field commands CpLangCommands
---@field template? string

---@class CpPlatformOverrides
---@field extension? string
---@field commands? CpLangCommands

---@class CpPlatform
---@field enabled_languages string[]
---@field default_language string
---@field overrides? table<string, CpPlatformOverrides>

---@class PanelConfig
---@field diff_modes string[]
---@field max_output_lines integer
---@field epsilon number?

---@class DiffGitConfig
---@field args string[]

---@class DiffConfig
---@field git DiffGitConfig

---@class Hooks
---@field before_run? fun(state: cp.State)
---@field before_debug? fun(state: cp.State)
---@field setup_code? fun(state: cp.State)
---@field setup_io_input? fun(bufnr: integer, state: cp.State)
---@field setup_io_output? fun(bufnr: integer, state: cp.State)

---@class VerdictFormatData
---@field index integer
---@field status { text: string, highlight_group: string }
---@field time_ms number
---@field time_limit_ms number
---@field memory_mb number
---@field memory_limit_mb number
---@field exit_code integer
---@field signal string|nil
---@field time_actual_width? integer
---@field time_limit_width? integer
---@field mem_actual_width? integer
---@field mem_limit_width? integer

---@class VerdictHighlight
---@field col_start integer
---@field col_end integer
---@field group string

---@class VerdictFormatResult
---@field line string
---@field highlights? VerdictHighlight[]

---@alias VerdictFormatter fun(data: VerdictFormatData): VerdictFormatResult

---@class RunConfig
---@field width number
---@field next_test_key string|nil
---@field prev_test_key string|nil
---@field format_verdict VerdictFormatter

---@class EditConfig
---@field next_test_key string|nil
---@field prev_test_key string|nil
---@field delete_test_key string|nil
---@field add_test_key string|nil
---@field save_and_exit_key string|nil

---@class CpUI
---@field ansi boolean
---@field run RunConfig
---@field edit EditConfig
---@field panel PanelConfig
---@field diff DiffConfig
---@field picker string|nil

---@class cp.Config
---@field languages table<string, CpLanguage>
---@field platforms table<string, CpPlatform>
---@field hooks Hooks
---@field debug boolean
---@field open_url boolean
---@field scrapers string[]
---@field filename? fun(contest: string, contest_id: string, problem_id?: string, config: cp.Config, language?: string): string
---@field ui CpUI
---@field runtime { effective: table<string, table<string, CpLanguage>> }  -- computed

---@class cp.PartialConfig: cp.Config

local M = {}

local constants = require('cp.constants')
local helpers = require('cp.helpers')
local utils = require('cp.utils')

-- defaults per the new single schema
---@type cp.Config
M.defaults = {
  open_url = false,
  languages = {
    cpp = {
      extension = 'cc',
      commands = {
        build = { 'g++', '-std=c++17', '{source}', '-o', '{binary}' },
        run = { '{binary}' },
        debug = {
          'g++',
          '-std=c++17',
          '-fsanitize=address,undefined',
          '{source}',
          '-o',
          '{binary}',
        },
      },
    },
    python = {
      extension = 'py',
      commands = {
        run = { 'python', '{source}' },
        debug = { 'python', '{source}' },
      },
    },
  },
  platforms = {
    codeforces = {
      enabled_languages = { 'cpp', 'python' },
      default_language = 'cpp',
      overrides = {
        -- example override, safe to keep empty initially
      },
    },
    atcoder = {
      enabled_languages = { 'cpp', 'python' },
      default_language = 'cpp',
    },
    codechef = {
      enabled_languages = { 'cpp', 'python' },
      default_language = 'cpp',
    },
    cses = {
      enabled_languages = { 'cpp', 'python' },
      default_language = 'cpp',
    },
  },
  hooks = {
    before_run = nil,
    before_debug = nil,
    setup_code = nil,
    setup_io_input = helpers.clearcol,
    setup_io_output = helpers.clearcol,
  },
  debug = false,
  scrapers = constants.PLATFORMS,
  filename = nil,
  ui = {
    ansi = true,
    run = {
      width = 0.3,
      next_test_key = '<c-n>',
      prev_test_key = '<c-p>',
      format_verdict = helpers.default_verdict_formatter,
    },
    edit = {
      next_test_key = ']t',
      prev_test_key = '[t',
      delete_test_key = 'gd',
      add_test_key = 'ga',
      save_and_exit_key = 'q',
    },
    panel = { diff_modes = { 'side-by-side', 'git', 'vim' }, max_output_lines = 50, epsilon = nil },
    diff = {
      git = {
        args = { 'diff', '--no-index', '--word-diff=plain', '--word-diff-regex=.', '--no-prefix' },
      },
    },
    picker = nil,
  },
  runtime = { effective = {} },
}

local function is_string_list(t)
  if type(t) ~= 'table' then
    return false
  end
  for _, v in ipairs(t) do
    if type(v) ~= 'string' then
      return false
    end
  end
  return true
end

local function has_tokens(cmd, required)
  if type(cmd) ~= 'table' then
    return false
  end
  local s = table.concat(cmd, ' ')
  for _, tok in ipairs(required) do
    if not s:find(vim.pesc(tok), 1, true) then
      return false
    end
  end
  return true
end

local function validate_language(id, lang)
  vim.validate({
    extension = { lang.extension, 'string' },
    commands = { lang.commands, { 'table' } },
  })

  if lang.template ~= nil then
    vim.validate({ template = { lang.template, 'string' } })
  end

  if not lang.commands.run then
    error(('[cp.nvim] languages.%s.commands.run is required'):format(id))
  end

  if lang.commands.build ~= nil then
    vim.validate({ build = { lang.commands.build, { 'table' } } })
    if not has_tokens(lang.commands.build, { '{source}', '{binary}' }) then
      error(('[cp.nvim] languages.%s.commands.build must include {source} and {binary}'):format(id))
    end
    for _, k in ipairs({ 'run', 'debug' }) do
      if lang.commands[k] then
        if not has_tokens(lang.commands[k], { '{binary}' }) then
          error(('[cp.nvim] languages.%s.commands.%s must include {binary}'):format(id, k))
        end
      end
    end
  else
    for _, k in ipairs({ 'run', 'debug' }) do
      if lang.commands[k] then
        if not has_tokens(lang.commands[k], { '{source}' }) then
          error(('[cp.nvim] languages.%s.commands.%s must include {source}'):format(id, k))
        end
      end
    end
  end
end

local function merge_lang(base, ov)
  if not ov then
    return base
  end
  local out = vim.deepcopy(base)
  if ov.extension then
    out.extension = ov.extension
  end
  if ov.commands then
    out.commands = vim.tbl_deep_extend('force', out.commands or {}, ov.commands or {})
  end
  return out
end

---@param cfg cp.Config
local function build_runtime(cfg)
  cfg.runtime = cfg.runtime or { effective = {} }
  for plat, p in pairs(cfg.platforms) do
    vim.validate({
      enabled_languages = { p.enabled_languages, is_string_list, 'string[]' },
      default_language = { p.default_language, 'string' },
    })
    for _, lid in ipairs(p.enabled_languages) do
      if not cfg.languages[lid] then
        error(("[cp.nvim] platform %s references unknown language '%s'"):format(plat, lid))
      end
    end
    if not vim.tbl_contains(p.enabled_languages, p.default_language) then
      error(
        ("[cp.nvim] platform %s default_language '%s' not in enabled_languages"):format(
          plat,
          p.default_language
        )
      )
    end
    cfg.runtime.effective[plat] = {}
    for _, lid in ipairs(p.enabled_languages) do
      local base = cfg.languages[lid]
      validate_language(lid, base)
      local eff = merge_lang(base, p.overrides and p.overrides[lid] or nil)
      validate_language(lid, eff)
      cfg.runtime.effective[plat][lid] = eff
    end
  end
end

---@param user_config cp.PartialConfig|nil
---@return cp.Config
function M.setup(user_config)
  vim.validate({ user_config = { user_config, { 'table', 'nil' }, true } })
  local defaults = vim.deepcopy(M.defaults)
  if user_config and user_config.platforms then
    for plat in pairs(defaults.platforms) do
      if not user_config.platforms[plat] then
        defaults.platforms[plat] = nil
      end
    end
  end
  local cfg = vim.tbl_deep_extend('force', defaults, user_config or {})

  if not next(cfg.languages) then
    error('[cp.nvim] At least one language must be configured')
  end

  if not next(cfg.platforms) then
    error('[cp.nvim] At least one platform must be configured')
  end

  vim.validate({
    hooks = { cfg.hooks, { 'table' } },
    ui = { cfg.ui, { 'table' } },
    debug = { cfg.debug, { 'boolean', 'nil' }, true },
    open_url = { cfg.open_url, { 'boolean', 'nil' }, true },
    filename = { cfg.filename, { 'function', 'nil' }, true },
    scrapers = {
      cfg.scrapers,
      function(v)
        if type(v) ~= 'table' then
          return false
        end
        for _, s in ipairs(v) do
          if not vim.tbl_contains(constants.PLATFORMS, s) then
            return false
          end
        end
        return true
      end,
      ('one of {%s}'):format(table.concat(constants.PLATFORMS, ',')),
    },
    before_run = { cfg.hooks.before_run, { 'function', 'nil' }, true },
    before_debug = { cfg.hooks.before_debug, { 'function', 'nil' }, true },
    setup_code = { cfg.hooks.setup_code, { 'function', 'nil' }, true },
    setup_io_input = { cfg.hooks.setup_io_input, { 'function', 'nil' }, true },
    setup_io_output = { cfg.hooks.setup_io_output, { 'function', 'nil' }, true },
  })

  local layouts = require('cp.ui.layouts')
  vim.validate({
    ansi = { cfg.ui.ansi, 'boolean' },
    diff_modes = {
      cfg.ui.panel.diff_modes,
      function(v)
        if type(v) ~= 'table' then
          return false
        end
        for _, mode in ipairs(v) do
          if not layouts.DIFF_MODES[mode] then
            return false
          end
        end
        return true
      end,
      ('one of {%s}'):format(table.concat(vim.tbl_keys(layouts.DIFF_MODES), ',')),
    },
    max_output_lines = {
      cfg.ui.panel.max_output_lines,
      function(v)
        return type(v) == 'number' and v > 0 and v == math.floor(v)
      end,
      'positive integer',
    },
    epsilon = {
      cfg.ui.panel.epsilon,
      function(v)
        return v == nil or (type(v) == 'number' and v >= 0)
      end,
      'nil or non-negative number',
    },
    git = { cfg.ui.diff.git, { 'table' } },
    git_args = { cfg.ui.diff.git.args, is_string_list, 'string[]' },
    width = {
      cfg.ui.run.width,
      function(v)
        return type(v) == 'number' and v > 0 and v <= 1
      end,
      'decimal between 0 and 1',
    },
    next_test_key = {
      cfg.ui.run.next_test_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    prev_test_key = {
      cfg.ui.run.prev_test_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    format_verdict = {
      cfg.ui.run.format_verdict,
      'function',
    },
    edit_next_test_key = {
      cfg.ui.edit.next_test_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    edit_prev_test_key = {
      cfg.ui.edit.prev_test_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    delete_test_key = {
      cfg.ui.edit.delete_test_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    add_test_key = {
      cfg.ui.edit.add_test_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    save_and_exit_key = {
      cfg.ui.edit.save_and_exit_key,
      function(v)
        return v == nil or (type(v) == 'string' and #v > 0)
      end,
      'nil or non-empty string',
    },
    picker = {
      cfg.ui.picker,
      function(v)
        return v == nil or v == 'telescope' or v == 'fzf-lua'
      end,
      "nil, 'telescope', or 'fzf-lua'",
    },
  })

  for id, lang in pairs(cfg.languages) do
    validate_language(id, lang)
  end

  build_runtime(cfg)

  local ok, err = utils.check_required_runtime()
  if not ok then
    error('[cp.nvim] ' .. err)
  end

  return cfg
end

local current_config = nil

function M.set_current_config(config)
  current_config = config
end

function M.get_config()
  return current_config or M.defaults
end

---Validate and get effective language config for a platform
---@param platform_id string
---@param language_id string
---@return { valid: boolean, effective?: CpLanguage, extension?: string, error?: string }
function M.get_language_for_platform(platform_id, language_id)
  local cfg = M.get_config()

  if not cfg.platforms[platform_id] then
    return { valid = false, error = string.format("Unknown platform '%s'", platform_id) }
  end

  local platform = cfg.platforms[platform_id]

  if not cfg.languages[language_id] then
    local available = table.concat(platform.enabled_languages, ', ')
    return {
      valid = false,
      error = string.format("Unknown language '%s'. Available: [%s]", language_id, available),
    }
  end

  if not vim.tbl_contains(platform.enabled_languages, language_id) then
    local available = table.concat(platform.enabled_languages, ', ')
    return {
      valid = false,
      error = string.format(
        "Language '%s' not enabled for %s. Available: [%s]",
        language_id,
        platform_id,
        available
      ),
    }
  end

  local platform_effective = cfg.runtime.effective[platform_id]
  if not platform_effective then
    return {
      valid = false,
      error = string.format(
        'No runtime config for platform %s (plugin not initialized)',
        platform_id
      ),
    }
  end

  local effective = platform_effective[language_id]
  if not effective then
    return {
      valid = false,
      error = string.format('No effective config for %s/%s', platform_id, language_id),
    }
  end

  return {
    valid = true,
    effective = effective,
    extension = effective.extension,
  }
end

---@param contest_id string
---@param problem_id? string
---@return string
local function default_filename(contest_id, problem_id)
  if problem_id then
    return (contest_id .. problem_id):lower()
  end
  return contest_id:lower()
end
M.default_filename = default_filename

return M
