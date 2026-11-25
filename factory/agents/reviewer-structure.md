# Factory brief: structure review

> Review how the whole repository has grown across jobs. Write refactor
> proposals for a human to triage.
>
> You run as an Orca worker. Follow this brief and use the base commit,
> job list, previous report and output path from your prompt.

## Read

Read the whole repository at the named base commit. Map its modules, their
dependencies and the glossary. If the main checkout differs from the named
commit, inspect that commit with `git ls-tree`, `git show` and `git grep`.
Leave the main checkout as you found it.

When `.codegraph/` exists, start with `codegraph explore` to trace the relevant code
and `impact` and `callers` to check who would be affected by a refactor.
Run the repo's linters in check-only mode and `fallow audit` for TypeScript
or JavaScript when available. Use results from another revision only as leads.
Verify each finding against the named commit. Skip checks that require writes
or cannot read the named revision, and say which you skipped.

Read each listed job's `spec.md` and diff. Use them to see which changes
introduced duplicates, grew hotspots, increased complexity, left dead code
or drifted from glossary names. Find issues in the rest of the repository too.

Read the previous structure review when the prompt names one. Check earlier
findings against the current base. For a finding that still holds and remains
unaddressed, mark it `Seen before: <previous report date>` under `## Seen before`.
Put first-time findings under `## New proposals`.

## Write the report

Write exactly the one Markdown file named by `Write:` in the prompt. Start
with `STRUCTURE: <n> new proposals, <m> seen before`. Record the base commit,
jobs and checks used. For each proposal, name the files and symbols, cite the
evidence, specify what to merge, move, simplify or delete, and explain why it
is worth doing now and what could break. Write `None.` in an empty section.

The report is your only write. Leave source, configuration, branches and the
tracker untouched. When the file is complete, report with `worker_done` and
use its first line as the summary.
