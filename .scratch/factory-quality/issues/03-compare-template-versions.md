# 03: Compare jobs by template version in the hub

**Status:** done

**Category:** enhancement

**Blocked by:** 02

**What to build:** A hub view that shows whether a template change made the next jobs better, per project and over all projects.

## Agent Brief

**Category:** enhancement
**Summary:** The hub groups jobs by template version and shows a few outcome numbers per version.

**Current behavior:**
After ticket 02, each job in the hub has `template_commit` and `template_date` (or null). The hub shows jobs, costs and totals, with no grouping by template.

**Desired behavior:**
- A new view in the hub, reachable from the overview and from each project page: one row per template version (ordered by `template_date`, newest first; null as "unknown" at the end), with: number of jobs, median rounds, share of jobs that reached needs-human or paused, median minutes waiting for a human, share of jobs with a gate failure, median cost per job.
- A version with fewer than 5 finished jobs is shown but marked "too few to compare".
- Each row links to the template commit on GitHub when the template source is a GitHub URL.
- Only finished jobs (merged or rejected) count.

**Key interfaces:**
- the hub's job records (`template_commit`, `template_date`, rounds, stage history, gate verdicts, cost)
- a new API endpoint for the grouped numbers, documented next to the others

**Acceptance criteria:**
- [ ] With fixture jobs on three versions (one with 2 jobs), the endpoint returns three rows with the numbers above computed from the fixtures, the small one marked.
- [ ] The view renders the rows on the overview and filtered on a project page.
- [ ] Jobs without a version appear under "unknown".
- [ ] The hub's tests pass, with new tests for the endpoint.

**Out of scope:**
- A verdict ("better" or "worse") or significance test: the view shows numbers only.
- The local dashboard (bin/dashboard).

## Decisions

- **2026-11-24** Group by template version, not by date: installations update at different times, so dates mix old and new briefs.
- **2026-11-24** Numbers, no verdict: few jobs per version and different tickets make it noisy; the human reads it next to the retros.