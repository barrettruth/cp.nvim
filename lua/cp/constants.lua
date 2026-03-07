local M = {}

M.PLATFORMS = { 'atcoder', 'codechef', 'codeforces', 'cses', 'kattis', 'usaco' }
M.ACTIONS = {
  'run',
  'panel',
  'next',
  'prev',
  'pick',
  'cache',
  'interact',
  'edit',
  'stress',
  'submit',
  'open',
}

M.PLATFORM_DISPLAY_NAMES = {
  atcoder = 'AtCoder',
  codechef = 'CodeChef',
  codeforces = 'CodeForces',
  cses = 'CSES',
  kattis = 'Kattis',
  usaco = 'USACO',
}

M.SIGNUP_URLS = {
  atcoder = 'https://atcoder.jp/register',
  codechef = 'https://www.codechef.com/register',
  codeforces = 'https://codeforces.com/register',
  cses = 'https://cses.fi/register',
  kattis = 'https://open.kattis.com/register',
  usaco = 'https://usaco.org/index.php?page=createaccount',
}

M.CPP = 'cpp'
M.PYTHON = 'python'

---@type table<string, string>
M.filetype_to_language = {
  python = M.PYTHON,
  cpp = M.CPP,
}

---@type table<string, string>
M.canonical_filetypes = {
  [M.CPP] = 'cpp',
  [M.PYTHON] = 'python',
}

---@type table<string, string>
M.canonical_filetype_to_extension = {
  [M.CPP] = 'cc',
  [M.PYTHON] = 'py',
}

---@type table<number, string>
M.signal_codes = {
  [128] = 'SIGILL',
  [130] = 'SIGINT',
  [131] = 'SIGQUIT',
  [132] = 'SIGILL',
  [133] = 'SIGTRAP',
  [134] = 'SIGABRT',
  [135] = 'SIGBUS',
  [136] = 'SIGFPE',
  [137] = 'SIGKILL',
  [138] = 'SIGUSR1',
  [139] = 'SIGSEGV',
  [140] = 'SIGUSR2',
  [141] = 'SIGPIPE',
  [142] = 'SIGALRM',
  [143] = 'SIGTERM',
}

M.LANGUAGE_VERSIONS = {
  atcoder = {
    cpp = { ['c++20'] = '6054', ['c++23'] = '6017' },
    python = { python3 = '6082', pypy3 = '6083' },
    java = { java = '6056' },
    rust = { rust = '6088' },
  },
  codeforces = {
    cpp = { ['c++17'] = '54', ['c++20'] = '89', ['c++23'] = '91' },
    python = { python3 = '31', pypy3 = '70' },
  },
  cses = {
    cpp = { ['c++11'] = 'C++11', ['c++17'] = 'C++17', ['c++20'] = 'C++20' },
    python = { python3 = 'Python3', pypy3 = 'PyPy3' },
    java = { java = 'Java' },
    rust = { rust2018 = 'Rust2018', rust2021 = 'Rust2021' },
  },
  kattis = {
    cpp = { ['c++17'] = 'C++', ['c++20'] = 'C++', ['c++23'] = 'C++' },
    python = { python3 = 'Python 3' },
    java = { java = 'Java' },
    rust = { rust = 'Rust' },
  },
  usaco = {
    cpp = { ['c++11'] = 'cpp', ['c++17'] = 'cpp' },
    python = { python3 = 'python' },
    java = { java = 'java' },
  },
  codechef = {
    cpp = { ['c++20'] = 'C++' },
    python = { python3 = 'PYTH 3', pypy3 = 'PYPY3' },
    java = { java = 'JAVA' },
    rust = { rust = 'rust' },
  },
}

M.DEFAULT_VERSIONS = { cpp = 'c++20', python = 'python3' }

return M
