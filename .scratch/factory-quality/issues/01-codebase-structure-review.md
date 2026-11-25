# 01: Review the codebase's structure every N merges

**Status:** done

**Category:** enhancement

**Blocked by:** factory-v2 #27 (CodeGraph index in every checkout, bin scripts renamed to .py)

**What to build:** A periodic structure review of the whole repository, not of a diff. Today every review lens sees one job's change, and the feature review (`reviewer-feature.md`, `--mid` every `feature_review_every` merges) sees one feature branch. Nobody checks whether the codebase is getting worse across tickets: the same pattern copied in three places, a module that keeps growing, an abstraction that is overdue after ten features. Models solve the single ticket well but don't improve a codebase over time on their own (SlopCodeBench, Dex Horthy's talk "12 Factor Factories", 2026-11).

- [ ] config.json `structure_review_every` (merges, default 0 = off): after that many merges into the base, `job merge` starts a structure-review worker, like it starts a retro today. A run never waits for it.
- [ ] A new brief `factory/agents/reviewer-structure.md`: reads the whole repo at the base (CodeGraph `explore`/`impact`/`callers` when `.codegraph/` exists, `fallow audit` for TS/JS, the repo's linters), plus the merged jobs since the last structure review (their spec.md and diffs), and writes `factory/jobs/_structure/<date>.md`: duplicated logic, growing hotspots, complexity, dead code left behind, names that drifted from the glossary.
- [ ] Each finding is a proposed refactor ticket (what to merge, move or delete, which files, why now). The factory files nothing itself: a human picks which become tickets, like retro candidates.
- [ ] Findings that the previous structure review already reported and nobody acted on are marked "seen before", not repeated as new.
- [ ] Tests in `factory/tests/run.sh`: the counter, the start after N merges, no start with 0, the file location.

## Agent Brief

**Category:** enhancement
**Summary:** `job merge` starts a read-only structure review of the whole repository every `structure_review_every` merges; it proposes refactor tickets for a human.

**Current behavior:**
Each review lens sees one job's diff; the feature reviewer sees one feature branch (final, or mid-feature every `feature_review_every` merges). After a merge, `job merge` may start a retro worker that writes `retro.md` with candidates for a human. Nothing looks at the repository as a whole across jobs and features.

**Desired behavior:**
- A new config key `structure_review_every` (integer, default 0 = off; `bin/update` adds it to installations like any new key).
- The factory counts merges into the base branch (local and GitHub trackers alike) since the last structure review, kept in a small state file under the jobs folder. When the count reaches the setting, `job merge` starts a `structure` worker the same way it starts a retro: in the main checkout at the base, without waiting for it, and the run goes on. The count resets when it starts. A failed start is reported on stdout and retried on the next merge.
- The worker follows a new brief, `reviewer-structure`: it reads the repository at the base (CodeGraph when the checkout has an index, the repo's linters and `fallow audit` for TS/JS where available) and the spec.md and diffs of the jobs merged since the last structure review. It writes exactly one file in a structure-review folder under the jobs folder, named by date: duplicated logic, growing hotspots, complexity, dead code left behind, names that drifted from the glossary. Each finding is a proposed refactor ticket: what to merge, move or delete, which files, why now, and the risk.
- It reads the previous structure review and marks a finding it already reported, and nobody acted on, as "seen before" with that file's date, instead of repeating it as new.
- It edits nothing and files no ticket. `job next` / the skill tell the user when a structure review was written, like a retro.
- Routing: claude/opus by default, overridable under `stages` like the retro.

**Key interfaces:**
- config.json `structure_review_every`, `stages.structure`
- the merge workflow's post-merge step (where the retro starts today)
- the new brief and its one output file

**Acceptance criteria:**
- [ ] With `structure_review_every: 3`, the third merge starts the structure worker exactly once and resets the count; merges 1 and 2 start none.
- [ ] With 0 (the default), no merge starts one and no state file is written.
- [ ] A merge doesn't wait for the worker; a failing start doesn't fail the merge.
- [ ] The worker's prompt names the previous structure review when one exists, and the jobs merged since.
- [ ] `bin/update` adds `structure_review_every: 0` to an installation without it.
- [ ] The skill and DESIGN.md describe the new step in one paragraph each.
- [ ] `factory/tests/run.sh` and `factory/tests/check.sh` pass, with new tests for the above.

**Out of scope:**
- Filing tickets automatically or editing code.
- A dashboard or hub view of structure reviews.
- New linters per language (separate ticket).

## Decisions

- **2026-11-24** Proposes, never edits or files: a refactor changes behaviour risk, so the human decides, as with retros.
- **2026-11-24** Separate from the feature review: that one looks at how one feature's tickets fit; this one at the repo as a whole across features.

- **2026-11-24** Triage: counts merges, not days: a quiet repo needs no review. Opus by default, because it reads a whole repo; the setting is off by default so no installation pays for it unasked.

## Comments

**2026-11-24** From the analysis of Dex Horthy's talk "12 Factor Factories / the war on slop": point "know your enemy", unattended models don't keep a codebase maintainable over months.