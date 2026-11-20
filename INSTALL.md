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
  Set `check_for_update_on_startup = false` at the top of the Codex config
  Orca starts workers with (`~/.config/orca/codex-accounts/*/home/config.toml`,
  and `~/.codex/config.toml`): otherwise an update prompt at startup blocks
  every Codex worker until someone answers it. Update Codex deliberately
  (`codex update` or `npm i -g @openai/codex`) between runs. `job claim`
  warns about every Codex config that is missing the line.
- Orca is installed and running, and the project is added to it
  (`<orca> repo list --json` lists its path; otherwise `<orca> repo add`).
  `<orca>` is `$ORCA_CLI_COMMAND` if set, else `orca-ide` on Linux, else `orca`.
  Never run bare `orca` on Linux outside an Orca terminal: that is the screen
  reader. The orchestrator starts every agent as an Orca worker.
- The `orchestration` and `orca-cli` skills are installed (`<orca> skills
  installed`), and the mattpocock/skills the briefs use exist under
  `~/.agents/skills/`: `tdd`, `diagnosing-bugs`, `code-review`, `pr`,
  `domain-modeling`, `codebase-design`, `triage`. For a web project also
  Chrome's `modern-web-guidance` (`npx skills add GoogleChrome/modern-web-guidance`),
  which the builder and the UI reviewer use for HTML, CSS and client-side JS.
  A missing one doesn't stop the factory, but tell the user which.
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
factory/bin/report
factory/bin/update
factory/agents/reviewer-feature.md
factory/agents/retro.md
factory/tests/run.sh
factory/tests/job_summary.test.js
factory/tests/job_summary_fixtures.json
factory/dashboard.html
factory/job-summary.js
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
- `commit_types` (default `feat`, `fix`, `docs`, `style`, `refactor`,
  `perf`, `test`, `build`, `ci`, `chore`, `revert`): the Conventional Commits
  types the factory allows. Every commit a job makes and its PR title must be
  `<type>(<scope>): <summary>`, at most 72 characters, no trailing period,
  even when the repo's own history uses another style; the round gate fails
  the job otherwise and checks.md tells the builder how to reword. The spec's
  first line is that title (intake's `TITLE:` when the spec writer is
  skipped), so with `squash` it is the commit on the base. The factory's own
  commits and PRs use `chore(factory): ...`. Jobs created before this rule
  (no `commit_format` in job.json) aren't checked.
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
- `worktree_cache_dirs`: build directories `env.sh` gives each worktree, as
  paths in the main checkout with `{name}` for the worktree's folder, such as
  `"target/factory-jobs/{name}"` for Rust. The factory deletes them with the
  worktree. Leave it `[]` when builds don't keep a directory per worktree.
- `worktree_setup`: a shell script run in every new job and slice worktree,
  for what a fresh checkout needs (env files, dependency install, indexes).
  The factory creates its worktrees itself, so a setup hook configured in Orca
  (`<orca> repo list --json`, `hookSettings.scripts.setup`) never runs for
  them: copy that script here. `ORCA_ROOT_PATH` and `FACTORY_MAIN_CHECKOUT`
  point at the main checkout. A failing setup is logged in the job folder
  (`worktree-setup.log`) and doesn't stop the job.
- `worktree_teardown`: its counterpart, run in a job or slice worktree just
  before the factory removes it (the job merged or was rejected, a slice
  merged). Use it to stop what `worktree_setup` or the builder started and the
  removal won't: dev servers, containers, port forwards. Same variables; the
  output goes to `worktree-teardown.log` in the job folder.
- `hold.after_spec_risk` with `hold.only_when_needed` (default `true`): a job
  of that risk pauses after the spec only when the spec's `## Needs a human`
  lists something for the human to check or do; set it `false` to hold every
  one. A ticket that says `**Factory:** hold after spec` always pauses.
- `overlap_wait` (default `true`): a job's first builder doesn't start while
  another running job (build to merging) has changed a file its `spec.md`
  names, committed on that job's branch or not yet committed in its worktree.
  `job next` says `wait: overlaps <job> (<file>)` and `job start <job>
  builder` refuses; the wait clears once that job merges or leaves those
  stages. Paths count when they are backticked or read as repo paths: files
  and directories that exist (not a top-level directory) or new files with a
  directory and an extension; `## Out of scope` is left out. Set it `false`
  to let jobs build on the same files at once.
- `gate_parallel`: how many gates (round and merge) run `checks.sh` at once
  on this machine for this repo; default 1, `0` for no limit. Raise it only
  when two `checks.sh` runs can't fight over ports, a database, a shared cache
  or the CPU. A gate that waits prints `gate: waiting for <job>'s gate (since
  HH:MM)`, and checks.md records the wait apart from `checks.sh`'s own time.
  The builder's `gate --hook` self-check doesn't wait for other gates.
- `lockfile_regenerate`: `{lockfile path: shell command}` (a key may be an
  fnmatch pattern). When merging the base into a job branch conflicts only in
  these files, the factory takes the base's lockfile, runs the command in the
  worktree with `factory/env.sh` sourced, and commits the merge, instead of
  sending the job back to a builder; `checks.sh`'s frozen install then
  verifies it. A conflict in any other file still goes to the builder. Leave
  it `{}` when the project has no lockfile; otherwise, by package manager:

  | Package manager | Entry |
  |---|---|
  | pnpm | `"pnpm-lock.yaml": "pnpm install --lockfile-only"` |
  | npm | `"package-lock.json": "npm install --package-lock-only"` |
  | yarn (berry) | `"yarn.lock": "yarn install --mode update-lockfile"` |
  | bun | `"bun.lock": "bun install --lockfile-only"` |
  | cargo | `"Cargo.lock": "cargo update --workspace"` (not `generate-lockfile`, which bumps every crate) |
  | uv | `"uv.lock": "uv lock"` |

  Only the lockfile may change: if the command rewrites any other tracked
  file, the conflict goes to the builder. Don't list a manifest
  (`package.json`, `Cargo.toml`): a conflict there is a real one. The lockfile
  paths are also left out when the factory decides whether a round after a
  failed merge changed the job's code (if not, its reviews and approval
  carry over).
- `ci_wait_minutes` (default 30) and `ci_start_grace_seconds` (default 180),
  GitHub only: `job merge` pushes the synced, gated branch and waits for the
  PR's checks on that commit before `gh pr merge`. When the reviewed commit
  had no check at approve (the PR's base runs no CI) and the branch changes
  no workflow, it waits only a couple of polls instead of the grace. The
  merge gate reuses the round gate's PASS when the commit and checks.sh are
  the ones it passed and checks.sh doesn't read `FACTORY_GATE`. A failing GitHub Actions
  check is rerun once per commit (`gh run rerun --failed`), at approve and at
  merge; only a check that fails again counts, and one that passed on rerun
  is listed as `Passed on rerun` in `ci.md` and `merge-ci.md`. A failing check
  sends the job back to the builder; checks still pending after `ci_wait_minutes` send
  it to a human; no check within the grace period means the repo has no CI,
  and it merges. Raise the minutes if CI takes longer; a repo without CI loses
  the grace period on every merge, so lower it there (`0` skips the wait).
- `main_ci` (default `true`), GitHub only: after a merge (by `job merge`, or a
  PR merged by hand that `job queue` finds), the factory watches the CI the
  merge starts on the base branch, in a background `job main-ci <job>` (log:
  `factory/jobs/<job>/main-ci.log`). It waits for the check runs on the merge
  commit (`ci_start_grace_seconds`, `ci_wait_minutes`), reruns a failing
  Actions run once, and writes `round-<N>/main-ci.md` and job.json `main_ci`.
  Skipped checks (a deploy whose `needs` failed, say) are listed, not counted.
  When CI fails or is still running at the timeout, it comments on the issue
  and notifies you on the `notify` channels; the job stays merged, the
  dashboard marks it `main CI failed` and `job next` says so until a later
  merge passes CI on that base. `false` turns the watch off.
- `rerun_every_round`: which lenses review every round, by risk (default
  code always, security at high). From round 2 on every other lens that passed
  carries its PASS forward; only the lenses that asked for CHANGES run again,
  on the diff since they last looked.
- `max_disputes` (default `1`): how often the builder may answer the same
  finding with `disagree` and have the reviewer keep it open before the job
  goes to a human with both sides, instead of spending another round. `0`
  never escalates early; the round limit still applies. `binding_lenses`
  (default `["ux", "ui"]`): lenses whose findings are build instructions, so
  the builder can't dispute them.
- `diff_growth` (default `{"ratio": 1.5, "min_lines": 50}`): every reviewed
  round writes the size of the change to `round-<N>/diff.md`. When the change
  is `ratio` times its first reviewed size and at least `min_lines` changed
  lines bigger, the file says `DIFF: GROWN`; the reviewers look for what can
  be cut and the approver escalates growth nothing asked for. `null` turns
  the flag off.
- `trusted_commenters` (default `"write"`), GitHub: whose issue comments go
  into `issue.md` besides the issue's author and the operator. `"write"`:
  anyone with write access to the repo (admin, maintain or write; the factory
  asks `gh api repos/{owner}/{repo}/collaborators/<login>/permission` once per
  login, so read and triage members don't count). `"author"`: only the author
  and the operator. Bots never count; the local tracker always uses the author
  and the operator. `comment_check_minutes` (default 5): while a job runs,
  `job next` looks for new trusted comments at most this often per job (and
  `job advance` at every transition); one it finds is a `tell:` line until a
  human makes it feedback or dismisses it with `job comments <job> --seen`.
- `review_skip`: leave it `{}`, or name a lens's files so it runs again when a
  later round touches them:
  `{"ui": {"paths": ["src/components/*"], "except": ["*.test.tsx"]}}`.
- `notify`: how the factory tells the user that a job waits on them (see
  **Notifications** below). Leave `["desktop"]` unless they want more; ask
  whether they want push on their phone.
- `labels`: leave them. They are only the fallback; the factory reads the real
  strings from `docs/agents/triage-labels.md`. The exception is
  `labels.factory` (default `null`, off): when the user also works on
  `ready-for-agent` tickets by hand or with ordinary agents, set it to a label
  such as `"factory"`, and the factory takes only issues carrying both
  `ready-for-agent` and that label; `job queue` lists the others as `skip`
  (`no factory label: left to people`) and `job create` refuses them. The
  factory never adds or removes it, except on the follow-up tickets it files
  itself, which get it. A row `| factory | <label> |` in
  `docs/agents/triage-labels.md` sets it too. On a local tracker a ticket
  carries it in a `**Labels:** factory` line (a comma-separated list) next to
  its Status.
- Agents: every `{"agent": ...}` entry may name a `model` and an `effort`
  (Orca passes both on). The Claude entries set `effort` on purpose: `high`
  where a missed error is expensive (spec, code and security review, approver,
  feature review, the Claude builder), `medium` for procedural work (intake,
  retro, UX/UI review, low-risk code review). Without it a Claude worker takes
  the model default (`medium` on Opus 5.5). Without a model, Codex uses whatever is the default
  in its own config at that moment. `builder.by_risk` picks the builder's model
  per risk; `model_presets` are short names for `job route-set`. Add each
  model you use to `prices_usd_per_mtok`, or its cost shows as unpriced.
- `builder.ui_fixes_before_fallback` (default 2): how many rounds the default
  builder gets to carry out the UX/UI reviewers' findings before the fallback
  builder takes over. The last round a job has always goes to the fallback.
- `feature_review` (default `true`): `job finish` has a reviewer read the
  whole feature branch before it merges. `feature_review_every` (default `0`,
  off): after every N-th job merged into a feature branch while it still has
  open tickets, `job merge` starts a mid-feature review; its findings go to
  `factory/jobs/_features/<branch>-integration.md` for the later jobs of that
  feature, not into tickets. Try `2` or `3` for features of five tickets or
  more.
- `builder.pre_review` (default `["codex review --base {base}"]`): the
  commands the builder runs on its own branch before READY, `{base}` being
  the job's base. In a TypeScript or JavaScript repo with `fallow` installed,
  add `"fallow audit --base {base} --format json --quiet"`: the builder then
  cleans up the dead code, duplication and complexity its change introduced.
  Fallow is advice here, not a gate; a repo that wants a hard rule puts a
  `fallow` command in `checks.sh`.
  It catches plain bugs before the reviewers, so a code review that would ask
  for changes doesn't cost a round. It doesn't replace the code review: it
  knows neither the spec nor the repo's conventions. The builder fixes the
  real findings and records them on a `Pre-review:` line under
  `## Self-review`; the factory refuses READY without it. Split jobs skip it.
  `null` turns it off, for a repo where it only adds noise.
- `min_risk_for_surface`: a floor under intake's risk per surface (default
  `security` → `medium`, so auth work never skips the spec writer).
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
# only with labels.factory set (see Configure):
gh label create factory --force --color 0E8A16 --description "ready-for-agent work the software factory may take"
gh label create bug --force --color D73A4A --description "Something is broken"
gh label create enhancement --force --color A2EEEF --description "New feature or improvement"
```

## Notifications

Most of a job's time is spent waiting on the human, so `factory/bin/job` sends
one message each time a job starts waiting (`paused`, including budget and
new-dependency pauses, `needs-human`, `needs-info`), saying which job, why,
and what to do (`Do: merge PR #235, or give feedback with /factory`). Merged and
rejected jobs get a low-priority message, and `job queue` sends `run finished`
once when nothing is left to start or running. `config.json` `notify` lists the
channels; each one is best effort with a 5 s timeout, and a failing one never
fails a job command:

| Channel | What it does |
|---|---|
| `"desktop"` | `notify-send` on this machine (the default) |
| `"orca"` | the main checkout's card in Orca gets the message as its comment and an unread dot |
| `{"ntfy_env": "FACTORY_NTFY_URL"}` | POST to [ntfy](https://ntfy.sh), URL from that environment variable; a tap opens the PR or GitHub issue |
| `{"ntfy": "https://ntfy.sh/<topic>"}` | the same with the URL in the config (the topic is then in the repo) |
| `{"command": "<shell command>"}` | the title and message on stdin; `FACTORY_NOTIFY_TITLE`, `_PRIORITY` (`low`, `default`, `high`) and `_URL` in its environment |

Any channel takes `"min": "high"` to get only the waiting messages (`orca`
defaults to `"default"`, the rest to `"low"`). A ntfy channel takes
`"token_env": "<VAR>"` for an access token. `"auto"` (the old default) still
means desktop, `""` turns notifications off. Nothing outside this machine is
contacted unless a channel says so.

Push to a phone with ntfy, without putting the topic in the repo:

1. Install the ntfy app and subscribe to a long random topic, e.g. `factory-$(openssl rand -hex 12)`.
2. `export FACTORY_NTFY_URL=https://ntfy.sh/<that topic>` in the shell profile of the session that runs `/factory run`.
3. Set `"notify": ["desktop", {"ntfy_env": "FACTORY_NTFY_URL"}]` and check it with
   `curl -d test "$FACTORY_NTFY_URL"`.

Anyone who knows a topic on the public ntfy.sh server can read it, so keep it
long and random, or use a self-hosted server with `token_env`.

## Stack notes

Every job works in a fresh worktree. What a stack keeps per checkout decides
how slow and how big each job is. Put the fixes in `factory/env.sh` and
`factory/checks.sh`, and the project's test and UI tools in the builder's and
reviewers' project blocks. Let `checks.sh` report every failing test, not stop
at the first: each failing gate costs the builder a round.

| Stack | Per worktree | In `env.sh` / `checks.sh` |
|---|---|---|
| Rust | `target/`, many GB | `CARGO_TARGET_DIR` in the main checkout, one per worktree (`target/factory-jobs/<worktree>`, listed in `worktree_cache_dirs`): worktrees sharing one dir overwrite each other's path crates. `CARGO_BUILD_JOBS`, `CARGO_INCREMENTAL=0`, `CARGO_PROFILE_DEV_DEBUG=line-tables-only`; one target dir per pinned toolchain; `cargo test --no-fail-fast` (otherwise the first failing test binary hides the rest) |
| Go | nothing big | `GOCACHE` and `GOMODCACHE` are global already; `go vet ./... && go test -count=1 ./...` (`-count=1` so the gate never reports a cached result) |
| pnpm | `node_modules`, hard links | `pnpm install --frozen-lockfile --prefer-offline` in `checks.sh`; the store is shared already |
| bun | `node_modules` | `bun install --frozen-lockfile`; the cache is global already |
| npm / yarn | `node_modules`, copied | `npm ci --prefer-offline`; set `npm_config_cache` (or yarn's cache folder) to one shared path |
| Next.js, Vite, Turbo | `.next/`, `.vite/`, `.turbo/` | fine to rebuild; a remote or shared Turbo cache helps big monorepos |
| Python | `.venv/` | `uv sync --frozen` with `UV_CACHE_DIR` shared; or one venv outside the worktrees |
| Godot | `.godot/` import cache, re-imports every asset | `godot --headless --import` in `checks.sh`; tests headless with GUT or gdUnit4; put a `.gdignore` file in `.worktrees/` or set `worktree_root` so the editor doesn't import the job checkouts |

The project's linters and formatters must leave `factory/` alone: its scripts,
`dashboard.html` and `config.json` follow the template's style, and
`factory/jobs/` is runtime state. Exclude `factory` in their config (Biome
`files.includes` `"!factory"`, ESLint `ignores`, Prettier `.prettierignore`),
or the first gate fails on the factory's own files.

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
   `factory/bin/job queue` runs without an error. `factory/bin/job claim
   --status` says `no claim` (don't claim the run yourself: `/factory run`
   does that in the session that orchestrates).
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
Commit the install there with a one-line Conventional Commits message
(`chore(factory): install the software factory`) and show the user the diff.
Ask before pushing: the factory branches every job from `origin/<base_branch>`,
so the install must be on that branch there before the first run.

Then tell the user, in a few lines:

- Triage one or two small issues with `/triage` (or label them
  `ready-for-agent`), then run `/factory run` in Claude Code **from an Orca
  terminal** in the project root, so Orca can wake the orchestrator. That
  session claims the run (`factory/jobs/_orchestrator.json`); any other
  Claude session Orca wakes for the run's workers is a stand-in that only
  finishes jobs already in flight. After an interruption, `factory/bin/job
  next` prints each job's next step.
- Every job ends as a PR. The approver merges what it approves; the rest wait
  labeled `ready-for-human`. Approve one by merging it on GitHub, or tell
  the factory what to change with `/factory <anything>`.
- A job that waits on them sends a desktop notification saying what to do.
  For push on their phone, see **Notifications** (ntfy, three steps).
- Intake runs on Fable, once per issue. Depending on their plan, Fable can
  bill to usage credits rather than the plan's included usage.
- Codex workers run without Claude's tool limits (with this machine's Codex
  config, no sandbox). Protect `main` on GitHub so only PRs can change it.
- To start carefully, set `concurrency` to 1 in `factory/config.json` and read
  every PR until they trust it.
