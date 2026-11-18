-- 0001: the first versioned schema.
--
-- Documents (job.json, config.json, the outside scan) are kept whole in `*doc`
-- columns; everything the hub filters, sorts, counts or sums is projected out of
-- them into typed columns and child tables by hub/src/project.rs at ingest. When
-- the projection changes, PROJECTION_VERSION goes up and the hub re-derives every
-- projected row from the stored documents at startup, no reporter involved.
--
-- Times are ISO-8601 UTC text (`2026-11-18T10:00:00Z`), money is REAL USD,
-- durations are INTEGER seconds. A released migration is never edited: a change
-- is a new file.

-- The tables before versioning were a mirror of the machines; the reporters
-- refill the new ones on the next full push (the hub answers need_full).
DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS files;
DROP TABLE IF EXISTS tickets;
DROP TABLE IF EXISTS jobs;
DROP TABLE IF EXISTS repos;
DROP TABLE IF EXISTS machines;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- ---- identity ---------------------------------------------------------------

CREATE TABLE machines (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    first_seen TEXT NOT NULL,
    last_seen  TEXT NOT NULL
);

CREATE TABLE repos (
    id         INTEGER PRIMARY KEY,
    slug       TEXT NOT NULL UNIQUE,          -- owner/name
    url        TEXT,
    first_seen TEXT NOT NULL
);

-- One repo on one machine.
CREATE TABLE checkouts (
    id          INTEGER PRIMARY KEY,
    machine_id  INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    repo_id     INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    path        TEXT,
    config_doc  TEXT,                         -- factory/config.json
    config_hash TEXT,
    first_seen  TEXT NOT NULL,
    last_seen   TEXT NOT NULL,
    removed_at  TEXT,                         -- the machine stopped reporting it
    UNIQUE (machine_id, repo_id)
);
CREATE INDEX checkouts_repo ON checkouts(repo_id);

-- ---- jobs -------------------------------------------------------------------

CREATE TABLE jobs (
    id                 INTEGER PRIMARY KEY,
    checkout_id        INTEGER NOT NULL REFERENCES checkouts(id) ON DELETE CASCADE,
    job_key            TEXT NOT NULL,         -- the folder name, 002-fix-…
    doc                TEXT NOT NULL,         -- job.json as reported
    doc_hash           TEXT NOT NULL,
    projection_version INTEGER NOT NULL,

    -- read from the document
    title           TEXT,
    stage           TEXT,
    round           INTEGER,
    round_limit     INTEGER,
    tracker         TEXT,
    issue_ref       TEXT,                     -- 198 or parity-roadmap/01
    issue_url       TEXT,
    pr              INTEGER,
    pr_url          TEXT,
    base            TEXT,
    branch          TEXT,
    fork_point      TEXT,
    review_head     TEXT,
    gate            TEXT,
    spec_skipped    INTEGER NOT NULL DEFAULT 0,
    intake_decision TEXT,
    intake_risk     TEXT,
    intake_size     TEXT,
    intake_split    INTEGER NOT NULL DEFAULT 0,
    intake_rescoped INTEGER NOT NULL DEFAULT 0,
    builder_agent   TEXT,
    builder_model   TEXT,
    builder_effort  TEXT,
    paused_after    TEXT,
    started         TEXT,
    ended           TEXT,

    -- computed at ingest
    stage_group     TEXT NOT NULL,            -- live | attention | merged | rejected | other
    started_day     TEXT,                     -- YYYY-MM-DD of started
    started_month   TEXT,                     -- YYYY-MM of started
    last_activity   TEXT,                     -- ended, else the newest stage change, else started
    duration_s      INTEGER,                  -- started → ended (or the last stage change)
    wait_s          INTEGER,                  -- time in needs-human, paused, needs-info
    work_s          INTEGER,                  -- duration_s - wait_s
    cost_usd        REAL NOT NULL DEFAULT 0,  -- as reported
    cost_claude     REAL NOT NULL DEFAULT 0,
    cost_codex      REAL NOT NULL DEFAULT 0,
    cost_other      REAL NOT NULL DEFAULT 0,  -- cost_usd not covered by claude + codex
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    cached_tokens   INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    slices_total    INTEGER NOT NULL DEFAULT 0,
    slices_done     INTEGER NOT NULL DEFAULT 0,
    findings        INTEGER NOT NULL DEFAULT 0,
    findings_disputed INTEGER NOT NULL DEFAULT 0,
    builder_changes INTEGER NOT NULL DEFAULT 0,
    continues       INTEGER NOT NULL DEFAULT 0,
    human_approvals INTEGER NOT NULL DEFAULT 0,
    review_problems INTEGER NOT NULL DEFAULT 0,

    first_seen      TEXT NOT NULL,
    last_seen       TEXT NOT NULL,
    removed_at      TEXT,                     -- gone from the machine; kept for the history
    UNIQUE (checkout_id, job_key)
);
CREATE INDEX jobs_group ON jobs(stage_group, last_activity);
CREATE INDEX jobs_day ON jobs(started_day);
CREATE INDEX jobs_month ON jobs(started_month);
CREATE INDEX jobs_ended ON jobs(ended);

-- history[]: one row per stage the job entered.
CREATE TABLE job_stages (
    job_id     INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    stage      TEXT NOT NULL,
    from_stage TEXT,                          -- the stage before, NULL for the first
    round      INTEGER,
    at         TEXT NOT NULL,
    duration_s INTEGER,                       -- until the next stage, NULL while current
    PRIMARY KEY (job_id, seq)
);
CREATE INDEX job_stages_at ON job_stages(at);

-- cost_breakdown[]
CREATE TABLE job_costs (
    job_id        INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    seq           INTEGER NOT NULL,
    role          TEXT NOT NULL,              -- builder-s2
    role_base     TEXT NOT NULL,              -- builder
    agent         TEXT,
    model         TEXT,
    sessions      INTEGER NOT NULL DEFAULT 0,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    cached_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (job_id, seq)
);
CREATE INDEX job_costs_model ON job_costs(model);

-- One row per round the job reached: the gate verdict (round-N/checks.md),
-- the diff size (diff_sizes) and the builder continues.
CREATE TABLE job_rounds (
    job_id       INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    round        INTEGER NOT NULL,
    gate_verdict TEXT,                        -- PASS | FAIL | invalid, NULL = not yet
    files        INTEGER,
    insertions   INTEGER,
    deletions    INTEGER,
    continues    INTEGER NOT NULL DEFAULT 0,
    started_at   TEXT,                        -- first build of the round
    PRIMARY KEY (job_id, round)
);

-- round-N/review-<lens>.md and review_log: who reviewed what and the verdict.
CREATE TABLE job_round_reviews (
    job_id  INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    round   INTEGER NOT NULL,
    lens    TEXT NOT NULL,
    verdict TEXT,                             -- PASS | CHANGES | FAIL | invalid, NULL = none
    agent   TEXT,
    model   TEXT,
    effort  TEXT,
    PRIMARY KEY (job_id, round, lens)
);

-- agents.reviewers + reviews + skipped_reviews + holds: the lenses of the job now.
CREATE TABLE job_reviewers (
    job_id         INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    lens           TEXT NOT NULL,
    agent          TEXT,
    model          TEXT,
    effort         TEXT,
    verdict        TEXT,                      -- reviews[lens]
    skipped_reason TEXT,
    held           INTEGER NOT NULL DEFAULT 0, -- the ticket asked for it
    PRIMARY KEY (job_id, lens)
);

-- answers: the builder's answer to each review finding, per round.
CREATE TABLE job_findings (
    job_id  INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    round   INTEGER NOT NULL,
    finding TEXT NOT NULL,                    -- "code F1"
    lens    TEXT,                             -- code
    status  TEXT,                             -- fixed | disputed | …
    answer  TEXT,
    PRIMARY KEY (job_id, round, finding)
);

-- builder_log
CREATE TABLE job_builder_changes (
    job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    seq    INTEGER NOT NULL,
    round  INTEGER,
    agent  TEXT,
    model  TEXT,
    reason TEXT,
    PRIMARY KEY (job_id, seq)
);

-- accepted[] and approved: sign-offs by a human or the approver.
CREATE TABLE job_approvals (
    job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    seq    INTEGER NOT NULL,
    kind   TEXT NOT NULL,                     -- accepted | approved
    by     TEXT,
    human  INTEGER NOT NULL DEFAULT 0,
    round  INTEGER,
    after  TEXT,
    note   TEXT,
    head   TEXT,
    at     TEXT,
    PRIMARY KEY (job_id, seq)
);

CREATE TABLE job_surfaces (
    job_id  INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    surface TEXT NOT NULL,
    PRIMARY KEY (job_id, surface)
);

CREATE TABLE job_follow_ups (
    job_id    INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    seq       INTEGER NOT NULL,
    issue_ref TEXT,
    title     TEXT,
    PRIMARY KEY (job_id, seq)
);

CREATE TABLE job_slices (
    job_id     INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    n          INTEGER NOT NULL,
    title      TEXT,
    state      TEXT,
    taken_over INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (job_id, n)
);

-- Every *.md of the job folder.
CREATE TABLE job_files (
    job_id     INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    path       TEXT NOT NULL,                 -- round-2/review-code.md
    content    TEXT NOT NULL,
    first_line TEXT,                          -- the verdict line of checks/review files
    updated    TEXT NOT NULL,
    PRIMARY KEY (job_id, path)
);

-- .scratch/ tickets of the local tracker.
CREATE TABLE tickets (
    checkout_id INTEGER NOT NULL REFERENCES checkouts(id) ON DELETE CASCADE,
    path        TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated     TEXT NOT NULL,
    PRIMARY KEY (checkout_id, path)
);

-- ---- usage ------------------------------------------------------------------

CREATE TABLE subscriptions (
    machine_id    INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    seq           INTEGER NOT NULL,
    name          TEXT NOT NULL,
    agent         TEXT,
    usd_per_month REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (machine_id, seq)
);

-- The machine's last outside-usage scan (bin/dashboard summarize()).
CREATE TABLE outside_scans (
    machine_id       INTEGER PRIMARY KEY REFERENCES machines(id) ON DELETE CASCADE,
    status           TEXT,
    factory_sessions INTEGER,
    doc              TEXT NOT NULL,
    doc_hash         TEXT NOT NULL,
    received_at      TEXT NOT NULL
);

CREATE TABLE outside_months (
    machine_id INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    month      TEXT NOT NULL,
    agent      TEXT NOT NULL,
    cost_usd   REAL NOT NULL,
    PRIMARY KEY (machine_id, month, agent)
);

CREATE TABLE outside_unpriced (
    machine_id INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    month      TEXT NOT NULL,
    model      TEXT NOT NULL,
    tokens     INTEGER NOT NULL,
    PRIMARY KEY (machine_id, month, model)
);

CREATE TABLE outside_cwds (
    machine_id INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    cwd        TEXT,
    sessions   INTEGER NOT NULL DEFAULT 0,
    claude_usd REAL NOT NULL DEFAULT 0,
    codex_usd  REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (machine_id, seq)
);
