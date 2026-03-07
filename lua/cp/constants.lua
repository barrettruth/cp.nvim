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
    cpp = { ['c++20'] = '6054', ['c++23'] = '6017', ['c++23-clang'] = '6116' },
    python = { python3 = '6082', pypy3 = '6083', codon = '6115' },
    java = { java = '6056' },
    rust = { rust = '6088' },
    c = { c23clang = '6013', c23gcc = '6014' },
    go = { go = '6051', gccgo = '6050' },
    haskell = { haskell = '6052' },
    csharp = { csharp = '6015', ['csharp-aot'] = '6016' },
    kotlin = { kotlin = '6062' },
    ruby = { ruby = '6087', truffleruby = '6086' },
    javascript = { bun = '6057', deno = '6058', nodejs = '6059' },
    typescript = { deno = '6100', bun = '6101', nodejs = '6102' },
    scala = { scala = '6090', ['scala-native'] = '6091' },
    ocaml = { ocaml = '6073' },
    dart = { dart = '6033' },
    elixir = { elixir = '6038' },
    erlang = { erlang = '6041' },
    fsharp = { fsharp = '6042' },
    swift = { swift = '6095' },
    zig = { zig = '6111' },
    nim = { nim = '6072', ['nim-old'] = '6071' },
    lua = { lua = '6067', luajit = '6068' },
    perl = { perl = '6076' },
    php = { php = '6077' },
    pascal = { pascal = '6075' },
    crystal = { crystal = '6028' },
    d = { dmd = '6030', gdc = '6031', ldc = '6032' },
    julia = { julia = '6114' },
    r = { r = '6084' },
    commonlisp = { commonlisp = '6027' },
    scheme = { chezscheme = '6092', gauche = '6093' },
    clojure = { clojure = '6022', ['clojure-aot'] = '6023', babashka = '6021' },
    ada = { ada = '6002' },
    bash = { bash = '6008' },
    fortran = { fortran2023 = '6047', fortran2018 = '6046', fortran77 = '6048' },
    gleam = { gleam = '6049' },
    lean = { lean = '6065' },
    pony = { pony = '6079' },
    prolog = { prolog = '6081' },
    vala = { vala = '6106' },
    v = { v = '6105' },
    sql = { duckdb = '6118' },
  },
  codeforces = {
    cpp = { ['c++17'] = '54', ['c++20'] = '89', ['c++23'] = '91', c11 = '43' },
    python = { python3 = '31', pypy3 = '70', python2 = '7', pypy2 = '40', ['pypy3-old'] = '41' },
    java = { java8 = '36', java21 = '87' },
    kotlin = { ['1.7'] = '83', ['1.9'] = '88', ['2.2'] = '99' },
    rust = { ['2021'] = '75', ['2024'] = '98' },
    go = { go = '32' },
    csharp = { mono = '9', dotnet3 = '65', dotnet6 = '79', dotnet9 = '96' },
    haskell = { haskell = '12' },
    javascript = { v8 = '34', nodejs = '55' },
    ruby = { ruby = '67' },
    scala = { scala = '20' },
    ocaml = { ocaml = '19' },
    d = { d = '28' },
    perl = { perl = '13' },
    php = { php = '6' },
    pascal = { freepascal = '4', pascalabc = '51' },
    fsharp = { fsharp = '97' },
  },
  cses = {
    cpp = { ['c++17'] = 'C++17' },
    python = { python3 = 'Python3', pypy3 = 'PyPy3' },
    java = { java = 'Java' },
    rust = { rust2021 = 'Rust2021' },
  },
  kattis = {
    cpp = { ['c++17'] = 'C++', ['c++20'] = 'C++', ['c++23'] = 'C++' },
    python = { python3 = 'Python 3', python2 = 'Python 2' },
    java = { java = 'Java' },
    rust = { rust = 'Rust' },
    ada = { ada = 'Ada' },
    algol60 = { algol60 = 'Algol 60' },
    algol68 = { algol68 = 'Algol 68' },
    apl = { apl = 'APL' },
    bash = { bash = 'Bash' },
    bcpl = { bcpl = 'BCPL' },
    bqn = { bqn = 'BQN' },
    c = { c = 'C' },
    cobol = { cobol = 'COBOL' },
    commonlisp = { commonlisp = 'Common Lisp' },
    crystal = { crystal = 'Crystal' },
    csharp = { csharp = 'C#' },
    d = { d = 'D' },
    dart = { dart = 'Dart' },
    elixir = { elixir = 'Elixir' },
    erlang = { erlang = 'Erlang' },
    forth = { forth = 'Forth' },
    fortran = { fortran = 'Fortran' },
    fortran77 = { fortran77 = 'Fortran 77' },
    fsharp = { fsharp = 'F#' },
    gerbil = { gerbil = 'Gerbil' },
    go = { go = 'Go' },
    haskell = { haskell = 'Haskell' },
    icon = { icon = 'Icon' },
    javascript = { javascript = 'JavaScript (Node.js)', spidermonkey = 'JavaScript (SpiderMonkey)' },
    julia = { julia = 'Julia' },
    kotlin = { kotlin = 'Kotlin' },
    lua = { lua = 'Lua' },
    modula2 = { modula2 = 'Modula-2' },
    nim = { nim = 'Nim' },
    objectivec = { objectivec = 'Objective-C' },
    ocaml = { ocaml = 'OCaml' },
    octave = { octave = 'Octave' },
    odin = { odin = 'Odin' },
    pascal = { pascal = 'Pascal' },
    perl = { perl = 'Perl' },
    php = { php = 'PHP' },
    pli = { pli = 'PL/I' },
    prolog = { prolog = 'Prolog' },
    racket = { racket = 'Racket' },
    ruby = { ruby = 'Ruby' },
    scala = { scala = 'Scala' },
    simula = { simula = 'Simula 67' },
    smalltalk = { smalltalk = 'Smalltalk' },
    snobol = { snobol = 'SNOBOL' },
    swift = { swift = 'Swift' },
    typescript = { typescript = 'TypeScript' },
    visualbasic = { visualbasic = 'Visual Basic' },
    zig = { zig = 'Zig' },
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
