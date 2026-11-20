-- The Agent split as job.json recorded it (cost_by_agent, a JSON object), NULL when the job
-- recorded none. cost_claude/codex/other are derived and cannot tell a recorded zero from a
-- missing split; the pages resolve the split from this, the priced rows and the total
-- (factory/job-summary.js). Filled by re-projection (PROJECTION_VERSION 2).
ALTER TABLE jobs ADD COLUMN cost_split TEXT;
