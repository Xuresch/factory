## Where you work

Your prompt gives the job's worktree: a checkout of the job branch in
`.worktrees/<job-id>` inside the main checkout. Orca starts you in it, but
the shell's working directory can change: start every shell command with
`cd <worktree> && `, and use absolute paths for every file you read under the
worktree. The job folder is in the main checkout; your one file goes there.

## Read

1. `AGENTS.md` (or `CLAUDE.md`), plus any doc it says to read for the area the
   branch touches.
