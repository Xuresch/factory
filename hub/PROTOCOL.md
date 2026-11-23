# Factory hub: plan and contract

One web app that every factory reports to. It shows every repo on every machine
in one place, live, and still opens each repo on its own with the same board,
costs and subscription views the per-repo dashboard has today.

```
machine A                         machine B
  factory/bin/report --watch        factory/bin/report --watch
  (reads every repo's               (same)
   factory/jobs/, config.json,
   subscriptions, outside usage)
        │  POST /api/ingest (Bearer token, gzip JSON, only what changed)
        ▼                                 ▼
   ┌──────────────────── hub/ (Rust, factory-hub) ──────────────────┐
   │ Turso: documents + projected tables (hub/migrations, project.rs) │
   │ /            overview (hub/static/index.html), live via SSE      │
   │ /api/...     JSON read API + /api/stream (SSE)                   │
   │ /r/<owner>/<name>/   virtual factory/ tree → dashboard.html      │
   │ /all/                virtual tree of every repo at once          │
   └──────────────────────────────────────────────────────────────────┘
```

Design rules:

- **Hub in Rust, reporter in Python.** The hub is one binary (`axum`, `tokio`,
  embedded Turso as a local file), image `ghcr.io/<owner>/factory-hub:<tag>`
  built by `.github/workflows/hub-image.yml`, never `:latest`. The reporter
  stays stdlib Python like the rest of `factory/bin`, so a factory machine needs
  no compiler and no extra binary.
- **The factory never waits on the hub.** `bin/job` is not touched. A separate
  reporter process reads the files `bin/job` already writes. Hub down = reports
  queue up locally as "not sent yet" and the next successful push is a full one.
- **The per-repo view is the existing `factory/dashboard.html`, unchanged in
  behaviour.** The hub serves, per repo, the same paths `factory/bin/dashboard`
  serves (`jobs/`, `jobs/<id>/...`, `config.json`, `.scratch/...`,
  `_subscriptions.json`), so the page cannot tell the difference.
- Numbers come from files, never from an LLM.

## Files

| File | What |
|---|---|
| `hub/src/*.rs`, `hub/Cargo.toml` | The hub. `cargo build --release` → `hub/target/release/factory-hub` |
| `hub/static/index.html` | The overview page. One file, inline CSS/JS, no build step. |
| `hub/test_server.py` | Black-box conformance suite over HTTP: `python3 -m unittest hub/test_server.py` (`HUB_CMD` picks the server) |
| `hub/dev/kind.sh` | Run the hub in a local kind cluster and feed it this machine's factories |
| `hub/Dockerfile`, `hub/k8s.yaml` | Container (multi-stage Rust build) + example Deployment/Service/PVC/Ingress |
| `factory/bin/report` | The reporter, one per machine. |
| `factory/tests/run.sh` | gets `t_report_*` tests |
| `factory/dashboard.html` | two small changes, see "Dashboard changes" |

## Identity

- **machine**: `hub.json` `machine`, default `socket.gethostname()`.
- **repo**: `owner/name` parsed from `git -C <repo> remote get-url origin`
  (`git@github.com:Xuresch/factory.git`, `https://github.com/Xuresch/factory`,
  any host: last two path segments, `.git` stripped). No origin:
  `local/<directory name>`. `url`: `https://github.com/owner/name` when the host
  is github.com, else null.
- A job is keyed by **(repo, machine, job id)**. When a repo has jobs from more
  than one machine, the virtual tree names them `<machine>~<id>` (and rewrites
  `id` inside the served job.json to match); with one machine, the plain `<id>`.

## Reporter config: `~/.config/factory/hub.json`

(`$XDG_CONFIG_HOME/factory/hub.json`)

```json
{"url": "https://factory.example.net", "token": "…", "machine": "niko-laptop",
 "projects": ["~/code/app"], "interval_seconds": 5, "outside": true}
```

- `projects`: optional. The repos reported are: the repo `report` lives in,
  plus `subscriptions.json` `projects`, plus `hub.json` `projects`, deduplicated
  by resolved path, only those with a `factory/` directory.
- `token` may instead come from `$FACTORY_HUB_TOKEN`; `url` from `$FACTORY_HUB_URL`.

## Reporter: `factory/bin/report`

```
report              one push, then exit (prints what it sent)
report --watch      push every interval_seconds, forever (the systemd service)
report --full       one push with full=true
report --dry-run    print the JSON it would send, send nothing
report --install-service   write ~/.config/systemd/user/factory-report.service and print the systemctl commands
```

- Reads per repo: `factory/jobs/[!_]*/job.json`, every `*.md` under each job
  folder (recursive, relative paths like `round-1/review-code.md`), the repo's
  `factory/config.json`, and, when a job's `issue_url` starts with `.scratch/`,
  that ticket file (key: the path relative to the repo, e.g. `.scratch/x/03.md`).
  No `*.log`, no lock files, nothing outside these.
- Diffing: keeps `~/.cache/factory/report-state.json`: `{hub url: {repo: {job id:
  {path: sha1}}, "config": {repo: sha1}, "outside": sha1, "subscriptions": sha1}}`.
  Sends only jobs where something changed, and per job only changed files plus
  `files_removed`. `job.json` always goes as `job` for a changed job. The state
  is written only after the hub answered 2xx.
- Full push: on the first run, when the hub answers `need_full: true`, after any
  failed push, and every 10 minutes.
- Outside usage: imports `factory/bin/session_usage.py`, the scan
  `factory/bin/dashboard` serves, and calls `scan_outside()` on its own thread
  every 5 minutes; sends `outside_summary()`'s result when its hash changed. `outside: false` or
  `subscriptions.json` `"outside": false` turns it off.
- Subscriptions: the `subscriptions` list from `subscriptions.json`, when it
  changed. Missing file: `[]`.
- Body is gzip'd JSON (`Content-Encoding: gzip`), `urllib.request`, timeout 20 s.
  Errors are printed one line each (no stack traces) and retried next interval.
- Exit codes: 0 ok, 1 push failed, 2 no config.

## Ingest

```
POST /api/ingest
Authorization: Bearer <token>
Content-Type: application/json
Content-Encoding: gzip            (optional)
```

```json
{
  "v": 1,
  "machine": "niko-laptop",
  "sent_at": "2026-11-17T20:00:00Z",
  "full": false,
  "repos": [{
    "repo": "Xuresch/nerdround_2",
    "url": "https://github.com/Xuresch/nerdround_2",
    "path": "/home/niko/Documents/projects/nerdround_2",
    "config": { "...factory/config.json, only when changed or full..." : 1 },
    "job_ids": ["001-build-deps", "002-chore-deps"],
    "jobs": [{
      "id": "002-chore-deps",
      "job": { "...job.json...": 1 },
      "files": {"spec.md": "...", "round-1/review-code.md": "..."},
      "files_removed": ["round-2/review-ux.md"]
    }],
    "tickets": {".scratch/deps/02.md": "..."}
  }],
  "subscriptions": [{"name": "Claude Max 5x", "agent": "claude", "usd_per_month": 100, "since": "2026-11"}],
  "outside": { "...bin/session_usage outside_summary() result, or omitted when unchanged...": 1 }
}
```

- `job_ids` is always the complete list for that repo on that machine. The hub
  marks that machine's jobs of that repo not in it as removed (`removed_at`):
  they leave the board and the tree but their cost stays in the history, and
  they come back when listed again.
- `full: true`: the hub also replaces each listed job's file set with exactly
  what was sent (files not sent are deleted), and a repo the machine reported
  before but that is absent from `repos` is marked removed for that machine.
- Omitted `config` / `subscriptions` / `outside` keys = unchanged.
- A subscription's optional `since` is its first active UTC month (`YYYY-MM`).
  Plans without `since` count as active in every month.
- Response `200 {"ok": true, "need_full": bool}`. `need_full` is true when the
  hub has no record of this machine (fresh database) or of a repo in a non-full
  push. `401` wrong/missing token, `400` bad body, `413` body over 64 MB.
- Tokens: `$FACTORY_HUB_TOKENS`, comma-separated. Empty = ingest is refused (403).
- On every job whose `stage` differs from the stored one (or which is new) the
  hub pushes an **event** `{at, machine, repo, job, title, from, to}` (from
  null for new) to every SSE client. Also an event `type: "seen"` per ingest so
  the page can show the heartbeat. The overview's `events` list is read from
  the jobs' `history` (table `job_stages`), with the times `bin/job` recorded.

## Storage

The schema is `hub/migrations/NNNN_*.sql`, applied in order at startup, each in
one transaction, after the database file is copied to `<db>.bak-<version>`.
A released migration is never edited; a change is a new file.

- Documents are kept whole: `jobs.doc` (job.json), `checkouts.config_doc`,
  `outside_scans.doc`, `job_files.content`, `tickets.content`.
- Everything the hub filters, sorts, counts or sums is projected from them by
  `hub/src/project.rs` into typed columns of `jobs` (stage group, cost split,
  tokens, durations, …) and child tables (`job_stages`, `job_costs`,
  `job_rounds`, `job_round_reviews`, `job_reviewers`, `job_findings`,
  `job_builder_changes`, `job_approvals`, `job_surfaces`, `job_follow_ups`,
  `job_slices`), and the outside scan into `outside_months`, `outside_unpriced`,
  `outside_cwds`.
- The projection is pure and versioned (`PROJECTION_VERSION`). When it changes,
  the hub re-projects every older job from the stored documents at startup; no
  reporter has to send anything again.

## Read API

The projected job list, detail, and cost endpoints are specified in [API.md](API.md). Overview job entries use the same summaries.

All JSON, `Cache-Control: no-store`.

- `GET /api/overview` →

```json
{
  "now": "…",
  "machines": [{"machine": "niko-laptop", "last_seen": "…", "repos": 3}],
  "repos": [{
    "repo": "Xuresch/nerdround_2", "url": "…", "machines": ["niko-laptop"],
    "last_seen": "…", "href": "/r/Xuresch/nerdround_2/dashboard.html",
    "counts": {"running": 1, "needs_you": 2, "merged": 30, "rejected": 1, "total": 43},
    "cost_usd": 123.4, "cost_month": 12.3,
    "cost_by_agent": {"claude": 90.0, "codex": 30.0, "other": 3.4},
    "cost_month_by_agent": {"claude": 9.0, "codex": 3.0, "other": 0.3},
    "daily": [{"day": "2026-11-04", "cost_usd": 1.2, "jobs": 2,
               "by_agent": {"claude": 1.0, "codex": 0.2, "other": 0.0}}],
    "last_activity": "…"
  }],
  "live":      [{"repo": "…", "machine": "…", "id": "…", "href": "…", "job": {summary}}],
  "needs_you": [{"repo": "…", "machine": "…", "id": "…", "href": "…", "job": {summary}}],
  "recent":    [{"repo": "…", "machine": "…", "id": "…", "href": "…", "job": {summary}}],
  "events":    [{"at": "…", "machine": "…", "repo": "…", "job": "…", "title": "…", "from": "build", "to": "gate"}],
  "daily": [{"day": "2026-11-04", "cost_usd": 2.4, "jobs": 5,
             "by_agent": {"claude": 2.0, "codex": 0.4, "other": 0.0}}],
  "month": {"month": "2026-11", "api_equivalent_usd": 81.1, "subscriptions_usd": 200,
             "jobs": 5, "factory_usd": 31.1, "outside_usd": 50.0, "elapsed_share": 0.6,
             "by_agent": {"claude": 50.0, "codex": 30.1, "other": 1.0},
             "factory": {"claude": 20.0, "codex": 10.1, "other": 1.0},
             "outside": {"claude": 30.0, "codex": 20.0, "other": 0.0},
             "plan_fee_full_usd": 200, "plan_fee_elapsed_usd": 120,
             "plan_fee_elapsed_by_agent": {"claude": 120, "codex": 0, "other": 0},
             "monthly_pace_usd": 139.1,
             "days_elapsed": 19, "days_in_month": 30,
             "prev": {"month": "2026-10", "...": "same comparison row for the previous month"}}
}
```

  `daily` covers the last 14 days by job start (local hub time, UTC is fine).
  `recent`: the 20 most recently ended jobs in merged/rejected. `events`: last 100.
  `href` of a job: `/r/<owner>/<name>/dashboard.html#job=<served id>`.
  `month` contains the current UTC month's comparison row. `month.prev` is the
  previous UTC month's row. The API-equivalent adds all factory jobs started
  by the comparison clock in the month, including retained jobs, and Outside
  usage from ready scans using the reported month keys.
  Totals sum the projected `{claude, codex, other}` Agent split per job.
  A non-empty stored split wins, including explicit zeroes. Otherwise the hub
  uses priced rows, or attributes a total-only job entirely to `claude`.
  Unknown agents and any positive residue of at least $0.005 go to `other`.
  `repos[].cost_by_agent` covers all jobs, `cost_month_by_agent` the jobs
  started this month, and `daily[].by_agent` each day. Top-level `daily` is
  the same 14 days summed over all repos.
  The comparison row includes the factory and Outside usage totals and their
  Agent splits. Active plans are deduplicated by name and agent in machine name
  and report order. The elapsed Plan fee uses elapsed UTC time, and equals the
  full Plan fee in completed months. The current row gains `monthly_pace_usd`
  after three full UTC days, based on the latest seven days of factory jobs
  within the month and the month-to-date mean of Outside usage.
  `subscriptions_usd`, `days_elapsed` (today's UTC day of month), and
  `days_in_month` remain on the overview response for existing readers.
- `GET /api/stream` → `text/event-stream`. Events: `event: job` (the event
  object), `event: seen` (`{machine, at}`). A `: ping` comment every 15 s.
- `GET /healthz` → `ok`.

Stage sets (same as dashboard.html):
`LIVE = intake spec build gate review approve merging`,
`ATTN (needs you) = needs-human paused needs-info`, terminal `merged rejected`.

## Virtual tree per repo

Under `/r/<owner>/<name>/` the hub answers exactly what `factory/bin/dashboard`
serves from `factory/`:

| Path | Answer |
|---|---|
| `dashboard.html` | the hub's copy of `factory/dashboard.html` (`$FACTORY_HUB_DASHBOARD`, default `../factory/dashboard.html` next to `hub/`, in the image `/app/factory/dashboard.html`) |
| `job-summary.js` | `factory/job-summary.js`, read next to the dashboard file (in the image `/app/factory/job-summary.js`); the overview loads it from `/all/job-summary.js` |
| `cost-aggregation.js` | `factory/cost-aggregation.js`, read next to the dashboard file. The overview loads it from `/all/cost-aggregation.js`. |
| `config.json` | the repo's last reported config (404 if none) |
| `jobs/` | an HTML directory listing in `python -m http.server` format: `<a href="<id>/"><id>/</a>` per job |
| `jobs/<id>/` | listing of that job's files and subdirectories (`round-1/`), plus `job.json` |
| `jobs/<id>/job.json` | the stored job.json (id rewritten when prefixed) |
| `jobs/<id>/<path>` | the stored file, `text/markdown; charset=utf-8` |
| `.scratch/<path>` | the stored ticket |
| `_subscriptions.json` | Over **every** repo and machine. The hub adds `comparison: {now, current_month, months}` to the standalone document shape. `months` holds the same UTC rows as `/api/overview`, starting with the first month of recorded usage or the earliest explicit plan `since`, whichever is earlier. `projects[].jobs[].cost_by_agent` includes the projected `claude`, `codex`, and `other` split. `outside` combines ready scans: `months` summed by month and agent, `by_cwd` concatenated with `cwd` prefixed `<machine>:`, `unpriced` summed, `factory_sessions` summed, `status` "ready" when at least one scan is ready or `{"status": "scanning"}` otherwise. |
| `hub` | (JSON) `{"repo": "...", "overview": "/"}` so the page knows it is under a hub |

`/all/` is the same tree over every repo at once: job ids `<name>~<id>` (or
`<name>~<machine>~<id>` when needed), `config.json` from the repo reported most
recently, tickets under `.scratch/<name>~/<path>` is NOT needed: local tickets
in `/all/` may 404.

Unknown paths 404. Path traversal (`..`) is rejected.

## Dashboard changes (`factory/dashboard.html`)

1. `fetch('/_subscriptions.json')` → `fetch('_subscriptions.json')` (relative;
   locally the page is at `/dashboard.html`, so it is the same URL).
2. On load, `fetch('hub')`; when it answers JSON with `overview`, show a
   "← All repos" link to it before the title and the repo name as title
   (`Software Factory · owner/name`), and put the page `<title>` to the repo name.
   Locally it 404s and nothing changes.
3. `#job=<id>` in the hash opens that job's drawer on load (so the overview can
   deep-link a job). Check what the hash routing does today (`#board`, `#costs`,
   `#plan`) and keep it working.

## Server config (env)

| Var | Default |
|---|---|
| `FACTORY_HUB_BIND` | `127.0.0.1` (container: `0.0.0.0`) |
| `FACTORY_HUB_PORT` | `8080` |
| `FACTORY_HUB_DB` | `./hub.db` (container: `/data/hub.db`) |
| `FACTORY_HUB_TOKENS` | empty: ingest refused |
| `FACTORY_HUB_DASHBOARD` | see above |

Viewing has no login of its own: put it behind the cluster's auth proxy
(Authentik forward-auth on the ingress) and leave `/api/ingest` and `/healthz`
outside the auth, token only.
