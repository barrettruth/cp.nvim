rockspec_format = '3.0'
package = 'cp.nvim'
version = 'scm-1'

source = {
  url = 'git+https://git.barrettruth.com/barrettruth/cp.nvim.git',
}
build = { type = 'builtin' }

description = {
  summary = 'Competitive programming plugin for Neovim',
  homepage = 'https://git.barrettruth.com/barrettruth/cp.nvim',
  license = 'GPL-3.0',
}

test_dependencies = {
  'lua >= 5.1',
  'nlua',
  'busted >= 2.1.1',
}
