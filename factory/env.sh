# Environment for every factory build and check. factory/checks.sh sources it,
# and the builder brief tells builders to source it before build or test
# commands, so the gate and the builders run the project's tools the same way
# and share their caches instead of rebuilding each other's work.
#
# It belongs to the project: the installer fills it in, factory/bin/update never
# touches it. Keep it to exports; it runs in bash and zsh.
#
# The main checkout, from the main checkout or any job worktree:
_factory_main="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"

# Examples, by stack (see INSTALL.md "Stack notes"):
#   Rust:   one target dir per worktree (shared ones clash on path crates), and
#           "worktree_cache_dirs": ["target/factory-jobs/{name}"] in config.json:
#           export CARGO_TARGET_DIR="$_factory_main/target/factory-jobs/$(basename "$(git rev-parse --show-toplevel)")"
#           export CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0
#   npm:    export npm_config_cache="$_factory_main/.cache/npm"   (pnpm, bun and Go share a global cache already)
#   Python: export UV_CACHE_DIR="$_factory_main/.cache/uv"
#   Godot:  export FACTORY_GODOT="${FACTORY_GODOT:-godot}"

unset _factory_main
