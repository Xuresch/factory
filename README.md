# Software Factory: Claude Code + Codex on Orca

A software factory that works through your GitHub issues. Triage an issue to
`ready-for-agent`, run `/factory run`, and agents decide whether it's worth building,
write a spec, build it, test it with your own checks, review it, and open a
pull request that closes the issue. The approver merges what it's sure of and
hands you the rest.

Every agent runs as an [Orca](https://github.com/stablyai/orca) worker. Codex
builds; Claude Code does intake, the spec, the reviews and the final call. A
job moves to a Claude builder only when the UX or UI review asks for changes,
and the code and security reviews never run on the same agent as the builder.
It works with GitHub issues and PRs, or with local markdown tickets in
`.scratch/` merged locally, whichever `/setup-matt-pocock-skills` set the repo
up with. Labels are the [mattpocock/skills](https://github.com/mattpocock/skills)
triage roles, and the briefs use its `tdd`, `diagnosing-bugs`, `code-review`,
`pr` and `domain-modeling` skills.

## Install

Open Claude Code in your project and paste:

```text
Install this software factory in this project from the reference repository:

https://github.com/Xuresch/factory
```

Your agent reads [`INSTALL.md`](INSTALL.md), copies the skill, agents, scripts
and dashboard, fills `factory/checks.sh` with your project's real test, lint,
typecheck and build commands, tailors the reviewers to your stack, creates the
GitHub labels, and checks that `checks.sh` passes on `main`.

You need Claude Code 2.1.257 or later, Codex, Orca with the `orchestration`
and `orca-cli` skills, the mattpocock/skills in `~/.agents/skills/`,
`python3`, and an authenticated [`gh`](https://cli.github.com/) that can push
to the repo.

## The loop

```
/triage (you, outside the factory) → issue labeled `ready-for-agent`
        │
        ▼
intake (claude/fable) ── NEEDS-INFO → asks the author, label needs-info, waits
        │                REJECT     → says why, label back to needs-triage
        ▼ ACCEPT, maybe rescoped; rates risk + surfaces
route (script)    picks builder, reviewers and models from config.json
        ▼
spec-writer (claude/opus) → spec.md
        ▼
builder (codex) → commits, pushes, opens a draft PR "Closes #n"
        ▼            ▲
gate (script) ─FAIL──┤  factory/checks.sh; no reviewer runs on a failing build
        ▼ PASS       │
reviewers ─CHANGES───┘  code (claude), + ux & ui on UI changes, + security
        │               CHANGES from ux or ui → next round's builder is claude,
        │               and code/security move to codex
        ▼ all PASS
approver (claude/opus) ── APPROVE  → sync with main, gate again, gh pr merge
                       └─ ESCALATE → PR ready for you, label ready-for-human
```

One Claude Code session in an Orca terminal orchestrates every job,
`concurrency` at a time (default 2), and Orca wakes it when a worker reports.
Each job gets its own git worktree and branch. All state lives in
`factory/jobs/`, so if the session dies, `/factory run` picks every job back up.

## Commands

```
/factory run          drain the queue: every open `ready-for-agent` issue, `concurrency` at a time; also resumes
/factory run <n>      one issue now
/factory <anything>   talk to the factory: ask about jobs, give feedback, file a feature
```

You approve by merging the PR on GitHub. To change an escalated PR, tell the
factory what you want with `/factory`. To drop a job that waits on you or on
its author, tell the factory to reject it.

## What's in here

```
.claude/
  skills/factory/SKILL.md     the orchestrator: queue, concurrency, the pipeline, Orca workers
factory/
  agents/                     one brief per worker, for Claude Code or Codex
    intake.md                 claude/fable   worth building? at what scope? risk + surfaces
    spec-writer.md            claude/opus    spec.md
    builder.md                codex          code, commits, the PR, build.md; claude after UI trouble
    reviewer-code.md          routed         Standards + Spec, never the builder's agent
    reviewer-security.md      routed         only when intake flags `security`
    reviewer-ux.md            claude/sonnet  only when intake flags `ui`
    reviewer-ui.md            claude/sonnet  only when intake flags `ui`
    approver.md               claude/opus    APPROVE or ESCALATE
  config.json                 concurrency, rounds, labels, agents, routing, cross-review, prices
  checks.sh                   your repo's checks (the installer fills it in)
  bin/job                     the only writer of job.json; refuses illegal moves; merges
  bin/gate                    runs checks.sh in a job's worktree → round-N/checks.md
  bin/route                   risk + surfaces → the job's builder, reviewers and models
  dashboard.html              the board
examples/jobs/                finished jobs from a real run
INSTALL.md                    instructions for the installing agent
DESIGN.md                     how it works and why
```

[`DESIGN.md`](DESIGN.md) explains each decision and lists what changed from v1.

## Dashboard

```bash
cd factory && python3 -m http.server
```

Open <http://localhost:8000/dashboard.html>. Each job is a card with its issue
and PR, a row of gate and review chips per round, its risk, cost and
time. Click a card to read every file the job wrote; each one opens with a
short summary of what happened in that step. To see the example
jobs, copy `examples/jobs/` to `factory/jobs/` first.

Cost is the API-equivalent price of each job's Claude workers, read from
Claude Code's transcripts. Codex workers aren't counted. On a subscription plan
it shows where the spend goes, not what you're billed.

## The example jobs

They come from a test run of the earlier Claude-only version on a small
private calculator repo, with `concurrency: 2` and every agent on Haiku to
keep it cheap.

- **001-add-a-subtract-function**: low risk, no UI, so only the code reviewer
  ran. Approved and merged through its PR.
- **002-show-a-history-of**: a UI change, so the UX and UI reviewers ran too.
  Merged.
- **003-add-multiply-divide-power**: intake cut an oversized "scientific
  calculator" issue down to three functions. The gate failed round 1 because
  the builder edited a protected test file, and the job went to a human after
  three rounds.
- **005-add-a-crypto-miner**: rejected at intake.

## Cost and safety

- It opens and merges real PRs and runs on your Claude and ChatGPT plans.
  Start with `concurrency: 1` and read every PR until you trust it.
- Workers run as full Claude Code and Codex sessions, without the tool limits
  the old subagents had. The scripts refuse a review round or a merge if a
  reviewer or the approver changed the branch. Protect `main` on GitHub too.
- Intake runs on Fable once per issue. Depending on your plan, Fable can bill
  to usage credits rather than your plan's included usage.
- Only issues labeled `ready-for-agent` run, and only people with triage or write
  access can add labels. Issue text reaches the agents as quoted data, never
  as their instructions.
- The factory pushes only `factory/*` branches, merges only through
  `gh pr merge`, and never deploys.

## License

[GPLv3](LICENSE). You can use, modify and share this code, and any version you
distribute must also be released under GPLv3.

Based on the original software factory by ZazenCodes, licensed under GPLv3.
