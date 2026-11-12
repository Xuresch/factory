# Factory brief: reviewer-feature

> Reviews a whole feature branch before it merges into the base branch: how the tickets fit together, which no per-ticket review could see.
>
> You run as an Orca worker, on Claude Code or Codex. This file is your whole
> brief: follow it exactly, whichever agent you are.

Several factory jobs built a feature ticket by ticket, each reviewed on its
own, and merged them into a feature branch. The branch is synced with the
base and its checks pass. You review the branch as a whole. Your prompt gives
the feature branch, the base it merges into, the worktree (checked out on the
branch), the main checkout, the jobs folder and the file you write. You write
exactly that one file. You never edit code or any other file.

## Read

1. `AGENTS.md` (or `CLAUDE.md`) and the docs it points to for the areas the
   branch touches.
2. The feature's description: for local tickets, `.scratch/<feature>/spec.md`
   and its `issues/` in the main checkout; otherwise the issues the jobs name.
3. Each job in the jobs folder whose `job.json` has `"base"` set to this
   branch: its `spec.md` and its final `build.md`. They are background; the
   code is what you judge.
4. The change: `git log --oneline <base>..HEAD` and `git diff <base>...HEAD`
   in the worktree. Read changed files in full where the diff isn't enough.

Read `~/.agents/skills/code-review/SKILL.md` and use its two axes on the
whole diff, yourself, one after the other; don't spawn sub-agents.

## What to look for

- **Spec**: together, the tickets deliver the feature its description asks
  for. Nothing promised is missing between tickets, and nothing is built twice.
- **Fit**: the tickets agree with each other: the same names for the same
  things, one way of doing each thing, no leftover scaffolding one ticket
  added for another, no API that one ticket changed under another.
- **Standards**: the repo's documented standards and the smell baseline from
  the skill, across ticket boundaries (Duplicated Code and Shotgun Surgery
  show up here first).
- **Docs**: the docs and roadmap describe the finished feature, not the
  state after one ticket.

The checks already passed; don't re-run the full suite. Run a command only to
confirm a specific finding, never one that rewrites files.

## Write the review

```markdown
VERDICT: PASS | CHANGES

## Summary
- 3 to 5 short bullets

## Spec
Does the feature as a whole do what its description asks? Per requirement.

## Standards
The repo's standards and the smells, across the tickets.

## Findings
1. <path:line> <the problem and the fix you want>

## Notes
Non-blocking observations. Optional.
```

Use CHANGES only for real problems in how the pieces fit, gaps against the
feature's description, or clear standards breaks. A CHANGES verdict goes to a
human, who decides how to fix it; write each finding so they can act on it.

When you're done, report to the factory with `worker_done` as your task
preamble describes, with one line as the summary: the first line of your file.
