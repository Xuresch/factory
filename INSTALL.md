# Install the software factory

You are a coding agent installing this factory into the user's project. Copy
what's generic, adapt what's repo-specific, verify it, and report. Work in the
project's root. Don't clone this repository.

The source is the folder the user pointed you at. On GitHub, read files from
`https://raw.githubusercontent.com/Xuresch/factory/main/<path>`.

## 0. Check the project

Stop and tell the user if any of these fail:

- It's a git repo, and `/setup-matt-pocock-skills` has run: `docs/agents/issue-tracker.md`
  and `docs/agents/triage-labels.md` exist. If not, ask the user to run it
  first. The factory follows the tracker that file names:
  - **GitHub**: the repo has an `origin` on GitHub, `gh auth status` shows a
    user who can push to it and manage its labels, and the default branch
    (`gh repo view --json defaultBranchRef`) exists on `origin`.
  - **Local Markdown**: tickets live in `.scratch/`; no remote is needed. The
    base branch must exist locally.
  - Anything else (GitLab): stop and tell the user it isn't supported.
- `claude --version` is 2.1.257 or later (the intake agent runs on Fable).
- `codex --version` works and Codex is signed in: Codex is the default builder.
- Orca is installed and running, and the project is added to it
  (`<orca> repo list --json` lists its path; otherwise `<orca> repo add`).
  `<orca>` is `$ORCA_CLI_COMMAND` if set, else `orca-ide` on Linux, else `orca`.
  Never run bare `orca` on Linux outside an Orca terminal: that is the screen
  reader. The orchestrator starts every agent as an Orca worker.
- The `orchestration` and `orca-cli` skills are installed (`<orca> skills
  installed`), and the mattpocock/skills the briefs use exist under
  `~/.agents/skills/`: `tdd`, `diagnosing-bugs`, `code-review`, `pr`,
  `domain-modeling`, `codebase-design`, `triage`. A missing one doesn't stop
  the factory, but tell the user which.
- `python3 --version` is 3.10 or later. The scripts use only the standard
  library.
- None of the files in step 1 already exist. If one does, show the user the
  clash and ask before overwriting.

## 1. Copy

Copy these files to the same paths in the project, unchanged:

```
.claude/skills/factory/SKILL.md
factory/agents/intake.md
factory/agents/spec-writer.md
factory/agents/builder.md
factory/agents/reviewer-code.md
factory/agents/reviewer-security.md
factory/agents/reviewer-ux.md
factory/agents/reviewer-ui.md
factory/agents/approver.md
factory/config.json
factory/checks.sh
factory/env.sh
factory/bin/job
factory/bin/gate
factory/bin/route
factory/bin/dashboard
factory/bin/update
factory/agents/reviewer-feature.md
factory/agents/retro.md
factory/tests/run.sh
factory/dashboard.html
```

```bash
SRC=https://raw.githubusercontent.com/Xuresch/factory/main
for f in <the paths above>; do
  mkdir -p "$(dirname "$f")" && curl -fsSL "$SRC/$f" -o "$f"
done
chmod +x factory/checks.sh factory/bin/* factory/tests/run.sh
```

Don't copy `README.md`, `DESIGN.md`, `INSTALL.md`, `LICENSE`, `examples/` or
`docs/`. They describe the reference, not the user's project.

## 2. Adapt

**`factory/checks.sh`.** Replace the placeholder with the project's real
checks: install dependencies if a fresh worktree needs them, then lint,
typecheck, tests and build, whichever the project has. Find them in
`AGENTS.md`, `CLAUDE.md`, `package.json` scripts, `Makefile`, `pyproject.toml`
and CI config. The script runs with a job's worktree as its working directory.
It must be non-interactive, must not rewrite files (no `--fix`, no
`--update-snapshots`), and must exit non-zero on any failure. Keep
`set -euo pipefail`.

**`factory/env.sh`.** The build settings and caches that `checks.sh` and the
builders share: every job is a full checkout in its own worktree, so anything a
stack caches per checkout is rebuilt per job unless it is shared here. See
**Stack notes** below.

**`factory/config.json`.**

- `tracker`: leave `auto`; `factory/bin/job tracker` shows what it detected.
- `base_branch`: the default branch.
- `merge_method`: `merge`, `squash` or `rebase`, one the repo allows
  (`gh api repos/{owner}/{repo} --jq '{allow_merge_commit, allow_squash_merge, allow_rebase_merge}'`).
- `protected_paths`: keep the factory entries and don't add the project's
  tests. Features legitimately change existing tests (a new required field
  changes every fixture), and a protected test blocks the job with no way
  through. The code reviewer catches weakened or special-cased tests instead.
  Add a path only when no job should ever change it. They are fnmatch
  patterns, so `*` also matches `/`.
- `ports`: move `base` if the project already uses ports 5100–5199.
- `worktree_root`: leave it `null` (worktrees in `.worktrees/`), or set a path
  such as `~/.factory-worktrees` when a tool in the project scans the whole
  directory without reading `.gitignore` (see Stack notes).
- `labels`: leave them. They are only the fallback; the factory reads the real
  strings from `docs/agents/triage-labels.md`.
- Leave `concurrency`, `max_rounds`, `stages`, `builder`, `routing`,
  `surface_reviewers`, `cross_review` and `prices_usd_per_mtok` as they are
  unless the user asks.

**Agents.** The checklists are general on purpose. Each brief has an empty
`<!-- project: ... -->` slot where the project goes; write the project's part
between the slot's two lines and nowhere else, so `factory/bin/update` can
bring in new versions of the brief later without losing it. Don't change the
structure, file names, first-line formats or one-line replies:

- `reviewer-security.md`: this project's hot spots (its auth, its data access
  rules, its payment and webhook code, where user input meets queries or HTML).
- `reviewer-ui.md`: where the design tokens, theme and shared components live.
- `reviewer-ux.md`: the kinds of users the app has.
- `approver.md`: what a human must always see in this project, added to the
  ESCALATE list.
- `intake.md`: one line under **Decide** saying what the project is for, so
  intake can tell what belongs.

**`AGENTS.md`** (or `CLAUDE.md`, whichever the project uses; create `AGENTS.md`
if neither exists). Every agent reads it. Make sure it says:

- how to set up a fresh checkout (install dependencies, env files to copy);
- how to start the dev server on a given port, if the project has one;
- the validation commands, matching `factory/checks.sh`.

Then add a short section:

```markdown
## Software factory

`/factory run` builds every open GitHub issue labeled `ready-for-agent`
through intake → spec → build → gate → review → approve, one PR per issue.
Every agent is an Orca worker: Codex builds, Claude Code reviews, and a job
moves to a Claude builder when the UX or UI review asks for changes. Briefs
are in `factory/agents/`. State is in
`factory/jobs/` (gitignored); `factory/bin/job` is its only writer. Checks:
`factory/checks.sh`. Dashboard: `factory/bin/dashboard`, then open
http://127.0.0.1:8000/dashboard.html.

Each job works in its own git worktree, a full checkout of the repo at
`.worktrees/<job-id>` (gitignored). A tool run from the repo root that doesn't
read `.gitignore` sees those copies too; exclude `.worktrees/` in its config.
```

**`.gitignore`.** Append these two lines:

```gitignore
/factory/jobs/
/.worktrees/
```

`factory/jobs/` is runtime state (job metadata, specs, reviews, check logs)
local to the machine running the factory. Each job's worktree is a full
checkout in `.worktrees/<job-id>`. Neither belongs in the repo. Everything you
copied in step 1 does: the skill in `.claude/skills/factory/`, the briefs in
`factory/agents/` and the rest of `factory/` are part of the project and get
committed, so ignore only these two paths, never `.claude/` or `factory/`.

**Labels.** On a local tracker, skip this: the Status strings come from
`docs/agents/triage-labels.md`. On GitHub, create the triage roles from
mattpocock/skills, using the strings in that file; `--force` keeps labels
that already exist:

```bash
gh label create ready-for-agent --force --color 5319E7 --description "Fully specified; the software factory builds it"
gh label create needs-info --force --color FBCA04 --description "Waiting on the reporter for more information"
gh label create ready-for-human --force --color D93F0B --description "Needs a human: decision, review or implementation"
gh label create needs-triage --force --color EDEDED --description "A maintainer needs to evaluate this"
gh label create wontfix --force --color FFFFFF --description "Will not be actioned"
gh label create bug --force --color D73A4A --description "Something is broken"
gh label create enhancement --force --color A2EEEF --description "New feature or improvement"
```

## Stack notes

Every job works in a fresh worktree. What a stack keeps per checkout decides
how slow and how big each job is. Put the fixes in `factory/env.sh` and
`factory/checks.sh`, and the project's test and UI tools in the builder's and
reviewers' project blocks.

| Stack | Per worktree | In `env.sh` / `checks.sh` |
|---|---|---|
| Rust | `target/`, many GB | `CARGO_TARGET_DIR` shared in the main checkout, `CARGO_BUILD_JOBS`, `CARGO_INCREMENTAL=0`, `CARGO_PROFILE_DEV_DEBUG=line-tables-only`; one target dir per pinned toolchain |
| Go | nothing big | `GOCACHE` and `GOMODCACHE` are global already; `go vet ./... && go test -count=1 ./...` (`-count=1` so the gate never reports a cached result) |
| pnpm | `node_modules`, hard links | `pnpm install --frozen-lockfile --prefer-offline` in `checks.sh`; the store is shared already |
| bun | `node_modules` | `bun install --frozen-lockfile`; the cache is global already |
| npm / yarn | `node_modules`, copied | `npm ci --prefer-offline`; set `npm_config_cache` (or yarn's cache folder) to one shared path |
| Next.js, Vite, Turbo | `.next/`, `.vite/`, `.turbo/` | fine to rebuild; a remote or shared Turbo cache helps big monorepos |
| Python | `.venv/` | `uv sync --frozen` with `UV_CACHE_DIR` shared; or one venv outside the worktrees |
| Godot | `.godot/` import cache, re-imports every asset | `godot --headless --import` in `checks.sh`; tests headless with GUT or gdUnit4; put a `.gdignore` file in `.worktrees/` or set `worktree_root` so the editor doesn't import the job checkouts |

Tools that scan the project directory without reading `.gitignore` see every
job's checkout in `.worktrees/`: some `jest`, `vitest`, `eslint` and `tsc`
configs, file watchers, and Godot. Exclude `.worktrees/` in their config, or
set `worktree_root` to keep the worktrees outside the repo.

UI review: the UX and UI reviewers drive a dev server with `agent-browser` by
default. For anything that isn't a web page (a native app, a CLI, a game),
write in their project blocks how to see the change instead: headless UI
tests, screenshots from a headless run, the CLI's output. For a game, where
feel matters, add `**Factory:** hold after spec` to UI tickets or keep
`hold.after_spec_risk` and play it yourself before approving.

## 3. Verify

1. In the project root, on the current branch, `bash factory/checks.sh` exits 0.
   If it fails there, the factory can never pass a job: fix the
   script (not the project) or tell the user what's broken.
2. `factory/bin/job tracker` names the tracker the docs describe, and
   `factory/bin/job queue` runs without an error.
3. `<orca> worktree current --json` succeeds from the project root inside an
   Orca terminal, and the agents `config.json` names (`claude`, `codex`) are
   enabled in Orca on this machine.
4. `python3 -m json.tool factory/config.json` succeeds, and
   `factory/tests/run.sh` passes (it needs only git and python3).
5. `git check-ignore factory/jobs/x .worktrees/x` prints both paths, and
   `git status --porcelain --untracked-files=all` lists every file from step 1
   (the skill, the agents and `factory/`) as committable.

## 4. Hand over

Stay on the branch the user is on: don't create or check out another branch.
Commit the install there with a one-line message and show the user the diff.
Ask before pushing: the factory branches every job from `origin/<base_branch>`,
so the install must be on that branch there before the first run.

Then tell the user, in a few lines:

- Triage one or two small issues with `/triage` (or label them
  `ready-for-agent`), then run `/factory run` in Claude Code **from an Orca
  terminal** in the project root, so Orca can wake the orchestrator.
- Every job ends as a PR. The approver merges what it approves; the rest wait
  labeled `ready-for-human`. Approve one by merging it on GitHub, or tell
  the factory what to change with `/factory <anything>`.
- Intake runs on Fable, once per issue. Depending on their plan, Fable can
  bill to usage credits rather than the plan's included usage.
- Codex workers run without Claude's tool limits (with this machine's Codex
  config, no sandbox). Protect `main` on GitHub so only PRs can change it.
- To start carefully, set `concurrency` to 1 in `factory/config.json` and read
  every PR until they trust it.
