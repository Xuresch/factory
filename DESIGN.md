# Design

How the v2 factory works, and why it's built this way. The source is small
enough to read in one sitting: one skill, eight agents, three scripts and a
config file.

## The idea

A software factory turns a queue of requests into merged code with a fixed
pipeline. Scripts handle the deterministic stages, such as running the tests,
moving state and merging. Agents do the judgment in between: whether a request
is worth building, what exactly to build, the code itself, and whether it's
good. Each stage leaves a file behind, so you can see what happened and why.
Every step's file opens with a `## Summary` of three to five bullets, so a human can
skim a job on the dashboard and read the detail only where it matters.

## Pieces

| Piece | File | Job |
|---|---|---|
| Queue | GitHub issues labeled `ready-for-agent` | What to build. Anyone can file an issue; only people with triage or write access can label it. |
| Orchestrator | `.claude/skills/factory/SKILL.md` | The Claude Code session that runs `/factory` in an Orca terminal. Starts jobs, starts every agent as an Orca worker, calls the scripts. Writes nothing itself. |
| Agents | `factory/agents/*.md` | One brief per role, for Claude Code or Codex. Each reads files, writes exactly one file, and reports one line with `worker_done`. |
| State | `factory/jobs/<job-id>/` | `job.json` plus every agent's file. Gitignored, local to the machine running the factory. |
| Spine | `factory/bin/job`, `gate`, `route` | Deterministic. `job` is the only writer of `job.json` and refuses illegal moves. |
| Checks | `factory/checks.sh` | The repo's test, lint, typecheck and build commands. The only repo-specific script. |
| Exit | the PR | Every job ends as a PR that closes its issue. Merging it is the approval. |

## Pipeline

```
intake (fable)     → ACCEPT (scope possibly changed) | NEEDS-INFO | REJECT, posted as an issue comment
route (script)     → reviewers + models from risk/surfaces via config.json
worktree           → factory/<job-id> from origin/main
spec-writer (opus) → spec.md
builder            → commits; first round pushes + opens draft PR "Closes #<n>"
gate (script)      → checks.sh; FAIL → builder gets the log, no reviewers spawned
reviewers (routed) → parallel, WAIT FOR ALL; CHANGES → builder → gate → reviewers (max rounds)
approver (opus)    → APPROVE: sync origin/main, gate, gh pr merge
                     ESCALATE: PR ready, decision as PR comment, label ready-for-human
```

`stage` in `job.json` is one of `intake`, `needs-info`, `spec`, `build`,
`gate`, `review`, `approve`, `merging`, `needs-human`, `merged`, `rejected`.
The legal moves are in `TRANSITIONS` at the top of `factory/bin/job`.

## Decisions

**Issues are the queue; you trigger the run.** `/factory run` drains every open
`ready-for-agent` issue. Nothing runs in GitHub Actions or on a schedule: the factory
runs on your machine, on your Claude plan, when you start it. An issue can't
start a Claude Code session by itself, and keeping it local means your
worktrees, dev servers and dashboard are right there.

**One orchestrator for every job.** The session running `/factory run` starts up
to `concurrency` jobs and starts every agent as an Orca worker. There are no
per-job orchestrators to coordinate. Its context stays small because workers
report one line and the scripts print one line; the detail lives in files the
next agent reads. Each worker is a full session, so two jobs with four
reviewers each already means ten agents at once; the default `concurrency` is
2.

**Fable at the door, once.** Intake is the only Fable call per job. It decides
whether the issue is worth building, rewrites the scope when the issue is too
big or vague, and asks the author when only they can answer. Its decision goes
on the issue as a comment; the issue body stays as written. Questions go to
the author before a spec exists, so the spec writer never stalls on one.

**Risk routes the work, a script does the routing.** Intake rates risk (`low`,
`medium`, `high`) and surfaces (`ui`, `security`). `factory/bin/route` looks
them up in `config.json`:

| | code review | ux | ui | security |
|---|---|---|---|---|
| low | Haiku | | | |
| medium | Sonnet | | | |
| high | Sonnet | | | |
| + `ui` surface | | Sonnet | Haiku | |
| + `security` surface | | | | Opus |

The builder always runs on Opus.

A low-risk change with no UI runs one Haiku reviewer. Routing is visible in
one file and changes without touching a prompt.

**Scripts decide whether it works.** The gate runs `checks.sh` before any
reviewer is spawned, and again after syncing with `main` before the merge.
A failing build goes straight back to the builder with the log. The gate runs
the main checkout's copy of `checks.sh`, so a branch can't edit the checks it
is judged by. It fails any branch that modifies or deletes a file under
`protected_paths`: the factory's own checks and config. Tests aren't
protected, since features have to update them; the code reviewer fails any
test that was weakened, skipped or special-cased to pass. The
builder also has a `SubagentStop` hook that runs the checks before it finishes,
as a nudge; the gate is still what decides.

**Agents judge what scripts can't.** Reviewers don't re-run the test suite;
they read the diff for correctness, scope, security, UX and visual fit.

**A PR per issue, merged through GitHub.** v1 merged locally, which broke when
the main checkout was dirty or busy. v2 merges with `gh pr merge`, so branch
protection, required checks and the PR history all apply, and your main
checkout is never touched. Before merging, the branch is synced with `main` and
gated again, because another job may have merged since it was tested.

**You approve by merging.** The approver merges what it would merge itself and
escalates the rest with a specific question. An escalated PR is ready for
review and its issue is labeled `ready-for-human`. Merge it to approve, or
tell the factory what to change with `/factory <anything>`: your words go to
the builder as `feedback-<k>.md` and the job runs another round. To drop a
job that waits on you or on its author, tell the factory to reject it: the
reason goes on the issue, its PR closes, and the job moves to Done.

**State is files, so runs resume.** Every fact the orchestrator needs is in
`factory/jobs/`. If the session dies or compacts, a fresh `/factory run` reads
the queue and resumes every job from its stage.

**Cost is measured per job.** Claude Code writes each subagent's transcript,
with model and token counts per message, to
`~/.claude/projects/<project>/<session>/subagents/`. Every factory prompt starts
with the job's folder, so `factory/bin/job` sums the transcripts that name it
and prices them with `prices_usd_per_mtok`. The figure is the API-equivalent
cost of the job's agents; on a subscription it shows relative spend, not your
bill. The orchestrator's own tokens aren't attributed to a job. The
transcript format isn't a documented interface, so a Claude Code update could
break this.

## Guardrails

- Only issues labeled `ready-for-agent` run. Labels need triage or write access, so the
  label is the trust boundary.
- Issue text reaches agents as quoted data in `issue.md`, with comments only
  from the issue's author and the factory's operator. It is never part of a
  worker spec or message. Intake, which reads it first, now runs as a full
  Claude Code session with a shell: see Orca and Codex below.
- Agents push only `factory/*` branches. Only `factory/bin/job merge` merges,
  through `gh pr merge`. The factory never deploys.
- One PR per issue; at most `max_rounds` build rounds per job before a human
  is asked.

## Orca, Codex and Claude Code

This fork runs every agent as an Orca worker instead of a Claude Code
subagent.

**Codex builds, Claude judges.** Codex is the default builder. Claude Code
does intake, the spec, the reviews and the final call. `cross_review` in
`config.json` keeps the code and security reviews off the builder's agent, so
a second model family reads every change.

**Claude takes over on UI trouble.** When the UX or UI review asks for
changes, `job advance` switches the job's builder to the fallback (Claude) for
the next round, moves the cross-review lenses to Codex, and records why in
`builder_log`. The new builder takes over from `build.md` and `git log`.

**Orca wakes the orchestrator.** Workers report with `worker_done`; the
orchestrator ends its turn after starting them and never polls. The builder's
dispatch id is stored in `job.json`, so later rounds are messages to the same
worker and a new session can still reach it.

**The scripts are the limit now.** Subagents had tool lists: reviewers had no
Edit, intake had no shell. Orca workers are full sessions, and Codex on this
setup has no sandbox. So `job advance` refuses a review round when the
worktree or HEAD changed during review, and refuses a merge when the branch
changed after review. Branch protection on `main` is the backstop for
pushes.

**Labels are the triage roles.** The queue is `ready-for-agent`, set by a human
with `/triage` from mattpocock/skills. Waiting jobs trade it for `needs-info` or
`ready-for-human`, intake sends an issue it turns away back to `needs-triage`,
and a job a human rejects gets `wontfix`. The issue stays open; closing it is
the human's call.

**Cost counts both.** Claude workers are read from Claude Code's transcripts, Codex workers from the session files of every Codex home, including the accounts Orca launches them with. Both are priced with `prices_usd_per_mtok`, and the dashboard breaks each job down by role, agent and model.

**Big jobs are sized at the door.** Intake writes `SIZE` and, for a large
job, either rescopes it, asks the author to narrow it, or sets `SPLIT: yes`
when the work divides cleanly. The spec writer then cuts it into 2 to 7
slices, each with the paths it owns, the slices it needs, and its criteria.
Up to `max_parallel_builders` builders work at once, each in its own worktree;
`job slice-done` refuses a slice that changed files it doesn't own, merges the
rest into the job branch as they finish, and starts dependent slices only
after their needs are merged. The merged branch then goes through one gate and
one set of reviews, and later rounds use a single builder. A slice, like a
whole build, can report PARTIAL and continue in place.

**The scripts start the workers.** `job start <job> <role>` reads the agent,
model, worktree and brief from `job.json`, writes the header, runs Orca's
`worker-start` and records the dispatch; `job send` messages a recorded
worker. The orchestrator never passes `--agent` or `--model` itself: in the
first real run it started every reviewer on Claude, so cross-review never
happened.

**Jobs build on a current base.** Before every build round after the first,
`job advance` merges the base into the job branch and writes
`round-<N>/base-sync.md`; a conflict is resolved by the builder at the start
of that round. A conflict or a failing gate during `job merge` sends the job
back to the builder too. Only with no round left does it reach a human.
`job approve` merges an escalated job the same way.

**Every job keeps a timeline and its follow-ups.** `job advance` appends each
stage with its round and time to `history`; the dashboard's overview shows how
long each stage took. When intake leaves work out, it lists it under
`## Follow-ups`, and the factory files each one once as a `needs-triage`
ticket (or GitHub issue), so nothing intake cut is lost.

**A human can steer any job.** A ticket line `**Factory:** hold after spec`
(or `intake`), or a risk listed in `hold.after_spec_risk` (default `high`),
pauses the job after that step as `ready-for-human`. The human reviews the
file, edits it if they want (the edit is binding and marked as theirs), and
resumes it, sends feedback to redo the step, or rejects it. `job rewind`
sends a running job back to intake, spec or build with feedback, keeping its
branch and archiving the old files; `job route-set` pins the builder or a
reviewer for one job.

**Jobs can target other branches.** A `**Branch:** <name>` line in the ticket,
or in a local feature's `spec.md`, makes jobs fork from and merge into that
branch (created from `base_branch` when missing), for a `dev` line or a
feature branch that collects several tickets. When the last ticket for a
branch is done, `job finish <branch>` syncs it with `base_branch`, runs the
full checks and merges it; a conflict or a failure is left for a human.

**Builders stay open, everything else closes.** Orca releases a worker's
terminal soon after `worker_done`. `job start` keeps the builder open
(`keep_open_roles`), so every round of a job reaches the same agent with its
context, and releases it when the job ends or waits for a human. `job send`
always points the worker at its brief, so a worker that was closed and comes
back fresh still knows its job.

**Any stack.** The scripts don't know the language. A project's stack lives in
three places: `checks.sh`, `env.sh` (build settings and caches that the gate
and the builders share, since every job is a fresh worktree) and the project
blocks in the briefs. INSTALL.md has notes per stack, and `worktree_root`
moves job worktrees out of the repo for tools that scan it whole.

## What changed from v1

| v1 | v2 | Asked for by |
|---|---|---|
| `/factory <feature>`, one job per session | `/factory run` drains the issue queue, `concurrency` jobs at once, one orchestrator | Alex; @spec2k5, @MrHossamsaraya |
| Copy-paste build prompt | One install prompt pointing at this folder | @felipeclavijo1736 |
| Every job gets all four reviewers | Fable intake rates risk and surfaces; a script routes reviewers and models | @mptrista, @Robin-ox2mz |
| Every verdict is an LLM opinion | `checks.sh` gates before review and before merge | @Robin-ox2mz |
| Local `git merge`, needs a clean main checkout | A PR per issue, merged with `gh pr merge` | v1 on-camera merge failures |
| `/factory approve` | Merge the PR on GitHub | v1 |
| The spec writer can stall on questions | Intake asks on the issue and parks the job | @acidrazor |
| Cost invisible | Cost and time per job on the dashboard and in the run summary | the most common comment |
| No license | GPLv3 | @mapledev9335 |
