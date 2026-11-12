#!/usr/bin/env bash
# The repo's checks. Exit 0 only when the branch is fit to review.
#
# The gate runs this script from the main checkout with the job's worktree as
# the working directory. Keep it fast, deterministic and non-interactive: no
# watch modes, no prompts, nothing that rewrites files.
#
# The gate sets FACTORY_GATE (round | merge) and FACTORY_BASE_REF. A repo with
# slow checks may skip the ones a round's diff can't affect, using
# `git diff --name-only "$FACTORY_BASE_REF"...HEAD`; on merge, and when the
# variables are unset (a manual run), run everything.
#
# INSTALL.md replaces the line below with this project's real commands, e.g.:
#
#   npm ci --prefer-offline
#   npm run lint
#   npm run typecheck
#   npm test -- --run
#   npm run build
set -euo pipefail

echo "factory/checks.sh has no checks yet. Add this repo's test, lint, typecheck and build commands." >&2
exit 1
