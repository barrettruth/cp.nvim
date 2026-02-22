# cp.nvim

**The definitive competitive programming environment for Neovim**

Scrape problems, run tests, and debug solutions across multiple platforms with
zero configuration.

https://github.com/user-attachments/assets/e81d8dfb-578f-4a79-9989-210164fc0148

## Features

- **Multi-platform support**: AtCoder, CodeChef, Codeforces, and CSES
- **Automatic problem setup**: Scrape test cases and metadata in seconds
- **Dual view modes**: Lightweight I/O view for quick feedback, full panel for
  detailed analysis
- **Test case management**: Quickly view, edit, add, & remove test cases
- **Rich test output**: 256 color ANSI support for compiler errors and program
  output
- **Language agnostic**: Works with any language
- **Diff viewer**: Compare expected vs actual output with 3 diff modes

## Installation

Install using your package manager of choice or via
[luarocks](https://luarocks.org/modules/barrettruth/cp.nvim):

```
luarocks install cp.nvim
```

## Dependencies

- GNU [time](https://www.gnu.org/software/time/) and
  [timeout](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html)
- [uv](https://docs.astral.sh/uv/) or [nix](https://nixos.org/) for problem
  scraping

## Quick Start

cp.nvim follows a simple principle: **solve locally, submit remotely**.

### Basic Usage

1. Find a contest or problem
2. Set up contests locally

   ```
   :CP codeforces 1848
   ```

3. Code and test

   ```
   :CP run
   ```

4. Navigate between problems

   ```
   :CP next
   :CP prev
   :CP e1
   ```

5. Debug and edit test cases

```
:CP edit
:CP panel --debug
```

5. Submit on the original website

## Documentation

```vim
:help cp.nvim
```

See
[my config](https://github.com/barrettruth/dots/blob/main/.config/nvim/lua/plugins/cp.lua)
for the setup in the video shown above.

## Motivation

I could not find a neovim-centric, efficient, dependency-free, flexible, and
easily customizable competitive programming workflow that "just works"--so I
made it myself. I conferenced with top competitive programmers at Carnegie
Mellon Univerity and the University of Virginia and covered their (and my) pain
points:

- Scraping: contests are automatically loaded asynchronously
- Test Case Management: test case editor (`:CP edit`)
- UI: both `run` and `panel` layouts cover common formats
- Extensibility: snippet plugins, compilation, etc. are left to the programmer

## Similar Projects

- [competitest.nvim](https://github.com/xeluxee/competitest.nvim)
- [assistant.nvim](https://github.com/A7Lavinraj/assistant.nvim)
