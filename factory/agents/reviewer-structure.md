# Factory brief: structure review

> Review how the whole repository has grown across jobs. Write refactor
> proposals for a human to triage.

<!-- include: orca-worker -->

Use the base commit, job list, previous report and output path from your
prompt.

## Read

1. The whole repository at the named base commit: its modules, their
   dependencies and the glossary. If the main checkout differs from the named
   commit, inspect that commit with `git ls-tree`, `git show` and `git grep`.
   Leave the main checkout as you found it.
2. The tools. When `.codegraph/` exists, start with `codegraph explore` to
   trace the relevant code, and `impact` and `callers` to see who a refactor
   would affect. Run the repo's linters in check-only mode, and `fallow audit`
   for TypeScript or JavaScript when available. Treat results from another
   revision as leads only, and verify each finding against the named commit.
   Skip checks that require writes or can't read the named revision, and say
   which you skipped.
3. Each listed job's `spec.md` and diff. Use them to see which changes
   introduced duplicates, grew hotspots, increased complexity, left dead code
   or drifted from glossary names. Look for the same problems in the rest of
   the repository too.
4. The previous structure review, when the prompt names one. Check its
   findings against the current base. A finding that still holds and nobody
   addressed goes under `## Seen before`, marked
   `Seen before: <previous report date>`. First-time findings go under
   `## New proposals`.

## Write the report

Write exactly the one Markdown file named by `Write:` in the prompt. Start
with `STRUCTURE: <n> new proposals, <m> seen before`. Record the base commit,
jobs and checks used. For each proposal, name the files and symbols, cite the
evidence, say what to merge, move, simplify or delete, and why it is worth
doing now and what could break. Write `None.` in an empty section.

The report is your only write. Leave source, configuration, branches and the
tracker untouched. When the file is complete, report with `worker_done` and
use its first line as the summary.
