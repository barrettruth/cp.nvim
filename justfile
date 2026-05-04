default:
    @just --list

format:
    nix fmt -- --ci
    stylua --check .
    biome format .
    ruff format --check .
    vimdoc-language-server format --check doc/

lint:
    git ls-files '*.lua' | xargs selene --display-style quiet
    lua-language-server --check . --configpath "$(pwd)/.luarc.json" --checklevel=Warning
    ruff check .
    ty check .
    vimdoc-language-server check doc/

test:
    python -m pytest tests/ -v

ci: format lint test
    @:
