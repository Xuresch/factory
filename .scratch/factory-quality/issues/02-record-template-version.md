# 02: Record which template version each job ran with

**Status:** done

**Category:** enhancement

**Blocked by:** factory-v2 #27 (bin scripts renamed to .py)

**What to build:** We change the briefs and the scripts from retro findings (#23, #26, #28 in one week), but nothing records which template version a job ran with, so their effect can't be measured. Record it in the installation and in every job, and send it to the hub. Ticket 03 builds the comparison view on it.

## Agent Brief

**Category:** enhancement
**Summary:** `bin/update` records the installed template commit; `job create` copies it into job.json; `bin/report` sends it; the hub stores it per job.

**Current behavior:**
`bin/update` installs the template's files and adds new config keys, and records no version. job.json has no template field. The hub stores jobs, rounds and costs per job without any template reference.

**Desired behavior:**
- `bin/update` writes `template_version` into config.json: `{"commit": "<full sha>", "date": "<commit date, ISO 8601>", "source": "<what it fetched from>"}`, overwriting the previous value on every real run (not on `--dry-run`). A source without git history (a plain directory) writes `commit: null` with the source and today's date.
- The template's own config.json carries no `template_version` (it is per installation); a missing value reads as "unknown".
- `job create` copies the installation's current `template_version` into job.json as `template_version`. Existing jobs keep none.
- `bin/report` sends job.json as today, so the field reaches the hub; the hub stores `template_commit` and `template_date` per job (protocol doc and a forward-only migration), null for jobs without it.

**Key interfaces:**
- config.json `template_version` (object as above)
- job.json `template_version` (copy of it at creation)
- hub job record: `template_commit`, `template_date`

**Acceptance criteria:**
- [ ] After `bin/update <local template checkout>`, config.json holds that checkout's HEAD sha and commit date; a second run with a newer template rewrites it; `--dry-run` changes nothing.
- [ ] `job create` writes the same object into job.json; a job created before any update has none and nothing fails.
- [ ] The hub ingests a job with and without the field; the migration runs on an existing database; the API returns the two fields per job.
- [ ] `factory/tests/run.sh`, `factory/tests/check.sh` and the hub's tests pass, with new tests for the above.

**Out of scope:**
- Any view or comparison in the hub or the dashboard (ticket 03).
- Backfilling old jobs from git history.

## Decisions

- **2026-11-24** Triage: split from the original "measure brief changes" ticket: recording the version (this) and the comparison view (03) are separate pull requests; this one is useful on its own (a job says which briefs it ran with).
- **2026-11-24** Stored in config.json, not a separate file: `bin/update` already rewrites config.json, and `bin/report` already sends it.

## Comments

**2026-11-24** From the analysis of Dex Horthy's talk "12 Factor Factories / the war on slop": point "compound over time, eval everything". The retro loop already exists; what's missing is checking that its changes worked.