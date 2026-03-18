# cp.nvim

**The definitive competitive programming environment for Neovim**

Scrape problems, run tests, and debug solutions across multiple platforms with
zero configuration.

https://github.com/user-attachments/assets/2b9e6c63-8750-451f-87ea-8909cef83762

## Features

- **Multi-platform support**: AtCoder, CodeChef, Codeforces, USACO, CSES, Kattis
- **Online Judge Integration**: Submit problems and view contest standings
- **Live Contest Support**: Participate in real-time contests
- **Automatic setup**: Scrape test cases and metadata in seconds
- **Streamlined Editing**: Configure coding view, edit test cases, stress-test
  solutions, run interactive problems, and more
- **Rich output**: 256 color ANSI support for compiler errors and program output
- **Language agnosticism**: Configure with any language
- **Security**: Passwords go untampered

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

1. Find a contest:

```
:CP pick
```

2. View the problem:

```
:CP open
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

6. Submit:

```
:CP submit
```

7. View contest standings:

```
:CP open standings
```

## Documentation

```vim
:help cp.nvim
```

See
[my config](https://github.com/barrettruth/nix/blob/5d0ede3668eb7f5ad2b4475267fc0458f9fa4527/config/nvim/lua/plugins/dev.lua#L165)
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
