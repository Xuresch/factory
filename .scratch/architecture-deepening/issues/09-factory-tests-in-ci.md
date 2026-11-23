# 09: Run the factory's own tests in CI and checks.sh

**Status:** ready-for-agent

**Category:** enhancement

**Blocked by:** None (can start immediately)

**What to build:** A change to the factory scripts, the dashboard modules or their tests is checked automatically, the same way a hub change already is. Today GitHub CI runs only for hub paths, and `factory/checks.sh` is still the installer's placeholder that exits 1, so a factory-only PR (such as #15 or #21) merges with no automatic check at all.

- [ ] A pull request or push to main that touches `factory/**` runs `factory/tests/run.sh`, the Python unit tests (`factory/tests/test_*.py`), the node tests (`factory/tests/*.test.js`) and `factory/tests/dashboard-verdicts.mjs`, and fails on any failure.
- [ ] The hub workflow's path filters still cover every factory file the hub image packages.
- [ ] Running the checks for this repo passes on main.

## Decisions

- **2026-11-23** `factory/checks.sh` stays the installer's template, unchanged. This repo's own checks live in a separate script that CI runs and a human can run locally; the factory does not run on this repo, so no gate needs it.

## Comments

**2026-11-23** Found while merging the architecture tickets: #21 merged without any CI run because the only workflow (`hub-image.yml`) filters on hub paths; the suites were run by hand on main afterwards (168 shell, 25 node, Python and Verdict checks passed).
