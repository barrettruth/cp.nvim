#!/bin/sh
set -eu

nix develop --command stylua --check .
git ls-files '*.lua' | xargs nix develop --command selene --display-style quiet
nix develop --command prettier --check .
nix develop --command lua-language-server --check . --checklevel=Warning
nix develop --command uvx ruff format --check .
nix develop --command uvx ruff check .
nix develop --command uvx ty check .
nix develop --command uv run pytest tests/ -v
