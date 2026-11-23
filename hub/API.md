# Hub read API v2 (from the projected tables)

The contract between the hub's Rust read side and the pages. Everything here is
read from the projected columns and child tables of `hub/migrations/0001_schema.sql`
(filled by `hub/src/project.rs`), never by parsing `jobs.doc` per request.
All answers are JSON, `Cache-Control: no-store`, unknown repo/job → 404.

`<served id>` is the id the virtual tree uses: the job folder name, or
`<machine>~<id>` when more than one machine has jobs in the repo (`/api/all/…`:
`hub/src/tree.rs` `all_served_ids`).

## Job summary

One object per job. Names follow job.json where a field exists there, so a page
moving from job.json to the API changes little.

```json
{
  "id": "<served id>", "key": "002-fix-x", "machine": "neo", "repo": "owner/name",
  "href": "/r/owner/name/dashboard.html#job=<served id>",
  "title": "…", "stage": "review", "stage_group": "live",
  "round": 2, "round_limit": 6,
  "issue": "198", "issue_url": "…", "pr": 234, "pr_url": "…",
  "base": "dev", "branch": "factory/002-…", "gate": "PASS", "spec_skipped": false,
  "started": "…", "ended": null, "last_activity": "…",
  "duration_s": 3600, "wait_s": 600, "work_s": 3000,
  "cost_usd": 9.29, "cost_by_agent": {"claude": 5.2, "codex": 4.0, "other": 0.09},
  "cost_split": {"claude": 5.2, "codex": 4.0},
  "tokens": {"input": 1, "cached": 2, "output": 3},
  "cost_breakdown": [{"role": "builder-s1", "role_base": "builder", "agent": "claude",
                      "model": "claude-opus-5-5", "sessions": 1, "input_tokens": 1,
                      "cached_tokens": 2, "output_tokens": 3, "cost_usd": 1.2}],
  "intake": {"decision": "ACCEPT", "risk": "medium", "size": "small", "split": false,
             "rescoped": false, "surfaces": ["ui"]},
  "agents": {"builder": {"agent": "claude", "model": "opus", "effort": "high"},
             "reviewers": {"code": {"agent": "codex", "model": null, "effort": null}}},
  "reviews": {"code": "PASS"},
  "paused": {"after": "spec"},
  "slices": [{"n": 1, "title": "…", "state": "done"}],
  "history": [{"stage": "build", "from": "spec", "round": 1, "at": "…", "duration_s": 600}],
  "rounds": [{"round": 1, "gate": "PASS", "reviews": {"code": "CHANGES"},
              "files": 3, "insertions": 40, "deletions": 2, "continues": 0}],
  "counts": {"findings": 2, "findings_disputed": 1, "builder_changes": 0,
             "continues": 0, "human_approvals": 1, "review_problems": 0},
  "removed": false
}
```

`cost_by_agent` is derived (projected columns; `other` is what the total holds beyond
claude and codex). `cost_split` is the split as job.json recorded it, null when it
recorded none; the pages resolve the Agent split from it, `cost_breakdown` and
`cost_usd` (`factory/job-summary.js`).

`cost_breakdown` is job_costs by seq (a handful of rows per job; the costs pages
aggregate it per model and role over any range of jobs). `paused` is null unless `paused_after` is set. `rounds[].gate` / `reviews[lens]`
are the Verdicts the first lines of `round-N/checks.md` / `round-N/review-<lens>.md`
declare: `GATE: PASS|FAIL` and `VERDICT: PASS|CHANGES`, whitespace after the colon
allowed; `invalid` for any other first line, null when the file is not there yet.

## Endpoints

- `GET /api/repos/<owner>/<name>/jobs` →
  `{"repo": "owner/name", "machines": ["neo"], "jobs": [summary, …]}`, the shown
  jobs (not removed, checkout not removed), newest `last_activity` first.
  `?removed=1` also lists removed jobs (`"removed": true`).
- `GET /api/all/jobs` → the same over every repo (`"repo": null`), served ids
  as in `/all/`.
- `GET /api/repos/<owner>/<name>/jobs/<served id>` (and `/api/all/jobs/<served id>`)
  → the summary plus:
  - `reviewers`: `[{lens, agent, model, effort, verdict, skipped_reason, held}]`
  - `round_reviews`: `[{round, lens, verdict, agent, model, effort}]`
  - `findings`: `[{round, finding, lens, status, answer}]`
  - `builder_changes`: `[{round, agent, model, reason}]`
  - `approvals`: `[{kind, by, human, round, after, note, head, at}]`
  - `follow_ups`: `[{issue, title}]`
  - `files`: `["spec.md", "round-1/checks.md", …]` (paths; contents stay under
    the virtual tree `/r/<owner>/<name>/jobs/<served id>/<path>`)
  - `fork_point`, `review_head`
- `GET /api/costs?group=<g>[&repo=owner/name][&since=YYYY-MM-DD][&until=YYYY-MM-DD]`,
  `g` one of `day`, `month` (by job start), `repo`, `agent`, `model`, `role`
  (role_base; from job_costs) →
  `{"group": "model", "rows": [{"key": "claude-opus-5-5", "cost_usd": 1.2,
   "input_tokens": 1, "cached_tokens": 2, "output_tokens": 3, "jobs": 4}]}`,
  rows sorted by key for day/month, by cost descending otherwise. Removed jobs
  count (their cost happened).

## Overview

`GET /api/overview` keeps its shape (hub/PROTOCOL.md), except that the entries of
`live`, `needs_you` and `recent` carry the **summary** as `job` instead of the
raw job.json.
