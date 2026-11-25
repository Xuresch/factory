#!/usr/bin/env bash
# Run this repository's test suites locally or in CI.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/home"

# Keep local agent settings, Git configuration, and credentials out of the tests.
env -i PATH="$PATH" HOME="$scratch/home" TMPDIR="$scratch" \
  LC_ALL=C PYTHONDONTWRITEBYTECODE=1 bash -e -c '
    factory/tests/run.sh
    python3 -m unittest discover -s factory/tests -p "test_*.py"
    node --test factory/tests/job_summary.node.js factory/tests/cost-aggregation.node.js
    node factory/tests/dashboard-verdicts.mjs
    node factory/tests/subscription-views.mjs
  '
