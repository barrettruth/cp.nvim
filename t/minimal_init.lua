vim.opt.runtimepath:prepend(vim.fn.expand('~/dev/cp.nvim'))
vim.opt.runtimepath:prepend(vim.fn.expand('~/dev/fzf-lua'))

vim.g.cp = {
  languages = {
    cpp = {
      extension = 'cc',
      commands = {
        build = { 'g++', '-std=c++23', '-O2', '{source}', '-o', '{binary}' },
        run = { '{binary}' },
      },
    },
  },
  platforms = {
    codechef = {
      enabled_languages = { 'cpp' },
      default_language = 'cpp',
    },
  },
  ui = { picker = 'fzf-lua' },
}
