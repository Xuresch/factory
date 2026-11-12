# Factory brief: retro

> After a job merged: what in the environment would have made it go better, as concrete candidates for a human to accept or drop.
>
> You run as an Orca worker, on Claude Code or Codex. This file is your whole
> brief: follow it exactly, whichever agent you are.

A factory job just merged. You look back at how it went and suggest changes to
the **environment**, so the next jobs go better: the repo's checks, docs,
coding standards, `AGENTS.md`, and the factory's own briefs and config. Your
prompt gives the job id and its folder. You write exactly one file,
`<job folder>/retro.md`. You never edit anything else: a human decides.

Read `~/.agents/skills/retro/SKILL.md` for the categories and the principles
(the reviewer imposes standards, not the builder; `AGENTS.md` holds navigation
pointers, not rules; a mechanical rule becomes an automated check). Use them,
but read the job folder instead of session logs: it is the record.

## Read

Everything in the job folder: `job.json` (its `history` timeline, cost,
`builder_log`, `continues`, follow-ups), `intake.md`, `spec.md`, every
`build.md` log entry, each `round-<N>/` (`checks.md`, `base-sync.md`,
`merge-back.md`, every review), `feedback-*.md`, `decision.md`. Earlier
`retro.md` files of other jobs (`<jobs folder>/*/retro.md`) tell you what was
already suggested; say when something comes up again.

## Look for

- Rounds that a check could have saved: a gate failure, a CHANGES finding of a
  mechanical kind (an automated check or lint rule would catch it).
- Reviewer findings that came up in earlier jobs too: a missing standard.
- A builder that stopped early, took over, or wrote BLOCKED: what was missing
  (a doc, a command, a clearer spec section)?
- Merge conflicts and base-sync conflicts: files that every job touches.
- Time and cost: the stage that took longest or cost most, and whether that
  was the work or friction.
- Intake or spec decisions a human had to correct (feedback, rewind).

## Write retro.md

```markdown
RETRO: <n> candidates

## Summary
- 3 to 5 short bullets: how the job went

## Candidates
1. **<category>**: <the change, concretely: which file, which rule, which check>.
   Why: <what happened in this job>. Seen before: <job ids, or "no">.

## Went well
What worked and should stay.
```

Order candidates by how much they would have saved. Write "None." under
Candidates when the job went cleanly. When you're done, report with
`worker_done`, the first line of retro.md as the summary.
