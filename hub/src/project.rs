//! The projection: what the hub derives from a stored job.json (and the first
//! lines of the job's files) into typed columns and child tables.
//!
//! Pure: the same document and files always give the same rows, and nothing
//! here reads the clock or the database. When it changes, PROJECTION_VERSION
//! goes up; at startup the hub re-projects every job whose stored version is
//! older (see `Hub::reproject`), from the documents it already holds.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde_json::{Map, Value};

use crate::store::{int, opt, real, text, Param, Statement};
use crate::util::parse_iso;

pub const PROJECTION_VERSION: i64 = 5;

pub const LIVE: [&str; 7] = [
    "intake", "spec", "build", "gate", "review", "approve", "merging",
];
pub const ATTN: [&str; 3] = ["needs-human", "paused", "needs-info"];

/// live | attention | merged | rejected | other
pub fn stage_group(stage: &str) -> &'static str {
    if LIVE.contains(&stage) {
        "live"
    } else if ATTN.contains(&stage) {
        "attention"
    } else if stage == "merged" {
        "merged"
    } else if stage == "rejected" {
        "rejected"
    } else {
        "other"
    }
}

/// The kind of round artifact a Verdict is read from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Artifact {
    /// round-N/checks.md: `GATE: PASS | FAIL`
    Checks,
    /// round-N/review-<lens>.md: `VERDICT: PASS | CHANGES`
    Review,
}

impl Artifact {
    fn declaration(self) -> (&'static str, &'static [&'static str]) {
        match self {
            Artifact::Checks => ("GATE:", &["PASS", "FAIL"]),
            Artifact::Review => ("VERDICT:", &["PASS", "CHANGES"]),
        }
    }
}

/// The Verdict an artifact's first line declares, the rule of factory/bin/jobfiles.py
/// and dashboard.html: None (pending) without the file; "invalid" unless the line is
/// the kind's prefix, optional whitespace and one of its values.
pub fn verdict(kind: Artifact, first_line: Option<&str>) -> Option<String> {
    let line = first_line?.trim();
    let (prefix, values) = kind.declaration();
    let value = line.strip_prefix(prefix).map(str::trim_start);
    Some(match value {
        Some(v) if values.contains(&v) => v.to_owned(),
        _ => "invalid".to_owned(),
    })
}

/// The line a file's verdict is read from.
pub fn first_line(content: &str) -> &str {
    content.split('\n').next().unwrap_or("").trim()
}

// ---- reading loosely typed JSON ---------------------------------------------

fn s(v: Option<&Value>) -> Option<&str> {
    v.and_then(Value::as_str).filter(|x| !x.is_empty())
}

/// A string, or a number written as one (issue 198 → "198").
fn s_or_num(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::String(x) if !x.is_empty() => Some(x.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn i(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(x) => x.trim().parse().ok(),
        _ => None,
    }
}

fn f(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(x)) => x.trim().parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

fn agent_index(agent: &str) -> usize {
    match agent {
        "claude" => 0,
        "codex" => 1,
        _ => 2,
    }
}

fn b(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(x)) => *x,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|x| x != 0.0),
        _ => false,
    }
}

fn obj(v: Option<&Value>) -> Option<&Map<String, Value>> {
    v.and_then(Value::as_object)
}

fn arr(v: Option<&Value>) -> &[Value] {
    v.and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

/// The round a key like `3` or `3-s2` belongs to.
fn round_key(k: &str) -> Option<i64> {
    k.split(|c: char| !c.is_ascii_digit())
        .next()
        .and_then(|n| n.parse().ok())
}

/// `builder-s2` → `builder`
fn role_base(role: &str) -> &str {
    if let Some((head, tail)) = role.rsplit_once("-s") {
        if !tail.is_empty() && tail.bytes().all(|c| c.is_ascii_digit()) {
            return head;
        }
    }
    role
}

/// `claude/sonnet:medium` → (claude, sonnet, medium)
fn parse_reviewer(v: &str) -> (Option<String>, Option<String>, Option<String>) {
    let (who, effort) = match v.split_once(':') {
        Some((w, e)) => (w, Some(e.to_owned())),
        None => (v, None),
    };
    let (agent, model) = match who.split_once('/') {
        Some((a, m)) => (Some(a.to_owned()), Some(m.to_owned())),
        None => (Some(who.to_owned()).filter(|x| !x.is_empty()), None),
    };
    (agent, model, effort.filter(|x| !x.is_empty()))
}

fn secs_between(a: &str, b: &str) -> Option<i64> {
    Some((parse_iso(b)? - parse_iso(a)?).max(0))
}

// ---- the projection ---------------------------------------------------------

struct Stage {
    stage: String,
    from: Option<String>,
    round: Option<i64>,
    at: String,
}

/// What a job projects to.
pub struct Projection {
    /// The `jobs` columns, in the order of JOB_COLUMNS.
    pub columns: Vec<Param>,
    pub stage: Option<String>,
    pub title: String,
    /// Statements replacing the child rows; each binds the job id first.
    children: Vec<(&'static str, Vec<Param>)>,
}

/// The projected columns of `jobs`, after id, checkout_id, job_key, doc, doc_hash.
pub const JOB_COLUMNS: [&str; 56] = [
    "projection_version",
    "title",
    "stage",
    "round",
    "round_limit",
    "tracker",
    "issue_ref",
    "issue_url",
    "pr",
    "pr_url",
    "base",
    "branch",
    "fork_point",
    "review_head",
    "gate",
    "spec_skipped",
    "intake_decision",
    "intake_risk",
    "intake_size",
    "intake_split",
    "intake_rescoped",
    "builder_agent",
    "builder_model",
    "builder_effort",
    "paused_after",
    "started",
    "ended",
    "stage_group",
    "started_day",
    "started_month",
    "last_activity",
    "duration_s",
    "wait_s",
    "work_s",
    "cost_usd",
    "cost_claude",
    "cost_codex",
    "cost_other",
    "cost_split",
    "input_tokens",
    "cached_tokens",
    "output_tokens",
    "slices_total",
    "slices_done",
    "findings",
    "findings_disputed",
    "builder_changes",
    "continues",
    "human_approvals",
    "review_problems",
    "template_commit",
    "template_date",
    "template_source",
    "first_seen",
    "last_seen",
    "removed_at",
];

const DELETE_CHILDREN: [&str; 11] = [
    "DELETE FROM job_stages WHERE job_id=?",
    "DELETE FROM job_costs WHERE job_id=?",
    "DELETE FROM job_rounds WHERE job_id=?",
    "DELETE FROM job_round_reviews WHERE job_id=?",
    "DELETE FROM job_reviewers WHERE job_id=?",
    "DELETE FROM job_findings WHERE job_id=?",
    "DELETE FROM job_builder_changes WHERE job_id=?",
    "DELETE FROM job_approvals WHERE job_id=?",
    "DELETE FROM job_surfaces WHERE job_id=?",
    "DELETE FROM job_follow_ups WHERE job_id=?",
    "DELETE FROM job_slices WHERE job_id=?",
];

const INS_STAGE: &str =
    "INSERT INTO job_stages (job_id, seq, stage, from_stage, round, at, duration_s) \
     VALUES (?,?,?,?,?,?,?)";
const INS_COST: &str =
    "INSERT INTO job_costs (job_id, seq, role, role_base, agent, model, sessions, \
     input_tokens, cached_tokens, output_tokens, cost_usd) VALUES (?,?,?,?,?,?,?,?,?,?,?)";
const INS_ROUND: &str = "INSERT INTO job_rounds (job_id, round, gate_verdict, files, insertions, \
     deletions, continues, started_at) VALUES (?,?,?,?,?,?,?,?)";
const INS_ROUND_REVIEW: &str =
    "INSERT INTO job_round_reviews (job_id, round, lens, verdict, agent, \
     model, effort) VALUES (?,?,?,?,?,?,?)";
const INS_REVIEWER: &str =
    "INSERT INTO job_reviewers (job_id, lens, agent, model, effort, verdict, \
     skipped_reason, held) VALUES (?,?,?,?,?,?,?,?)";
const INS_FINDING: &str =
    "INSERT INTO job_findings (job_id, round, finding, lens, status, answer) \
     VALUES (?,?,?,?,?,?)";
const INS_BUILDER: &str =
    "INSERT INTO job_builder_changes (job_id, seq, round, agent, model, reason) \
     VALUES (?,?,?,?,?,?)";
const INS_APPROVAL: &str =
    "INSERT INTO job_approvals (job_id, seq, kind, by, human, round, after, note, \
     head, at) VALUES (?,?,?,?,?,?,?,?,?,?)";
const INS_SURFACE: &str = "INSERT INTO job_surfaces (job_id, surface) VALUES (?,?)";
const INS_FOLLOW_UP: &str =
    "INSERT INTO job_follow_ups (job_id, seq, issue_ref, title) VALUES (?,?,?,?)";
const INS_SLICE: &str =
    "INSERT INTO job_slices (job_id, n, title, state, taken_over) VALUES (?,?,?,?,?)";

impl Projection {
    /// The statements that replace this job's child rows.
    pub fn child_statements(&self, job_id: i64) -> Vec<Statement> {
        let mut out: Vec<Statement> = DELETE_CHILDREN
            .iter()
            .map(|sql| (*sql, vec![int(job_id)]))
            .collect();
        for (sql, params) in &self.children {
            let mut p = Vec::with_capacity(params.len() + 1);
            p.push(int(job_id));
            p.extend(params.iter().cloned());
            out.push((*sql, p));
        }
        out
    }
}

/// When the job is first and last seen and whether it is gone, owned by the ingest.
pub struct Seen<'a> {
    pub first_seen: &'a str,
    pub last_seen: &'a str,
    pub removed_at: Option<&'a str>,
}

/// Project a job.json. `lines` maps each file path of the job to its first line.
#[allow(clippy::too_many_lines)]
pub fn project(doc: &Value, lines: &HashMap<String, String>, seen: &Seen<'_>) -> Projection {
    let g = |k: &str| doc.get(k);
    let stage = s(g("stage")).map(str::to_owned);
    let title = s(g("title")).unwrap_or("").to_owned();
    let started = s(g("started")).map(str::to_owned);
    let ended = s(g("ended")).map(str::to_owned);
    let intake = g("intake");
    let builder = g("agents").and_then(|a| a.get("builder"));
    let version = |key| s(g("template_version").and_then(|v| v.get(key)));
    let mut children: Vec<(&'static str, Vec<Param>)> = Vec::new();

    // history → stages, waiting time
    let mut stages: Vec<Stage> = Vec::new();
    for h in arr(g("history")) {
        let (Some(st), Some(at)) = (s(h.get("stage")), s(h.get("at"))) else {
            continue;
        };
        stages.push(Stage {
            stage: st.to_owned(),
            from: stages.last().map(|p: &Stage| p.stage.clone()),
            round: i(h.get("round")),
            at: at.to_owned(),
        });
    }
    // a job without a history (older bin/job) still shows where it stands
    if stages.is_empty() {
        if let (Some(st), Some(at)) = (stage.as_deref(), started.as_deref()) {
            stages.push(Stage {
                stage: st.to_owned(),
                from: None,
                round: i(g("round")),
                at: at.to_owned(),
            });
        }
    }
    let mut wait_s = 0;
    for (n, st) in stages.iter().enumerate() {
        let until = stages
            .get(n + 1)
            .map(|x| x.at.as_str())
            .or(ended.as_deref());
        let duration = until.and_then(|u| secs_between(&st.at, u));
        if ATTN.contains(&st.stage.as_str()) {
            wait_s += duration.unwrap_or(0);
        }
        children.push((
            INS_STAGE,
            vec![
                int(n as i64),
                text(&st.stage),
                opt(st.from.as_deref()),
                st.round.map_or(Param::Null, int),
                text(&st.at),
                duration.map_or(Param::Null, int),
            ],
        ));
    }
    let last_stage_at = stages.last().map(|x| x.at.clone());
    let last_activity = ended
        .clone()
        .or_else(|| last_stage_at.clone())
        .or_else(|| started.clone());
    let duration_s = started.as_deref().and_then(|st| {
        ended
            .as_deref()
            .or(last_stage_at.as_deref())
            .and_then(|e| secs_between(st, e))
    });
    let work_s = duration_s.map(|d| (d - wait_s).max(0));

    // cost_breakdown → costs and tokens
    let (mut tokens_in, mut tokens_cached, mut tokens_out) = (0, 0, 0);
    let mut priced_split = [0.0; 3];
    let priced_rows = arr(g("cost_breakdown"));
    for (n, c) in priced_rows.iter().enumerate() {
        let role = s(c.get("role")).unwrap_or("");
        let agent = s(c.get("agent"));
        let usd = f(c.get("cost_usd"));
        let (ti, tc, to) = (
            i(c.get("input_tokens")).unwrap_or(0),
            i(c.get("cached_tokens")).unwrap_or(0),
            i(c.get("output_tokens")).unwrap_or(0),
        );
        tokens_in += ti;
        tokens_cached += tc;
        tokens_out += to;
        priced_split[agent_index(agent.unwrap_or(""))] += usd;
        children.push((
            INS_COST,
            vec![
                int(n as i64),
                text(role),
                text(role_base(role)),
                opt(agent),
                opt(s(c.get("model"))),
                int(i(c.get("sessions")).unwrap_or(0)),
                int(ti),
                int(tc),
                int(to),
                real(usd),
            ],
        ));
    }
    let cost_usd = f(g("cost_usd"));
    let stored_split = obj(g("cost_by_agent"));
    // Agent split rule, also used for local jobs in factory/job-summary.js.
    let [claude, codex, mut other] = match stored_split.filter(|m| !m.is_empty()) {
        Some(split) => {
            let mut amounts = [0.0; 3];
            for (agent, usd) in split {
                amounts[agent_index(agent)] += f(Some(usd));
            }
            amounts
        }
        None if !priced_rows.is_empty() => priced_split,
        None => [cost_usd, 0.0, 0.0],
    };
    const RESIDUE: f64 = 0.005;
    let rest = cost_usd - claude - codex - other;
    let max_amount = cost_usd
        .abs()
        .max(claude.abs())
        .max(codex.abs())
        .max(other.abs());
    // Allow for accumulated rounding across four dollar amounts and three subtractions.
    let rounding = 4.0 * f64::EPSILON * max_amount;
    if rest > 0.0 && rest >= RESIDUE - rounding {
        other += rest.max(RESIDUE);
    }
    let cost_split = stored_split.map(|m| Value::Object(m.clone()).to_string());

    // rounds: gate verdict, diff size, continues
    let round = i(g("round"));
    let diff_sizes = obj(g("diff_sizes"));
    let mut continues: BTreeMap<i64, i64> = BTreeMap::new();
    for (k, v) in obj(g("continues")).into_iter().flatten() {
        if let Some(r) = round_key(k) {
            *continues.entry(r).or_default() += i(Some(v)).unwrap_or(0);
        }
    }
    let review_log = obj(g("review_log"));
    let mut rounds: BTreeSet<i64> = (1..=round.unwrap_or(0)).collect();
    rounds.extend(stages.iter().filter_map(|x| x.round).filter(|r| *r > 0));
    for path in lines.keys() {
        if let Some(r) = path
            .strip_prefix("round-")
            .and_then(|p| p.split('/').next())
            .and_then(|n| n.parse().ok())
        {
            rounds.insert(r);
        }
    }
    let reviewers = obj(g("agents").and_then(|a| a.get("reviewers")));
    for &r in &rounds {
        let size = diff_sizes.and_then(|d| d.get(&r.to_string()));
        let gate = verdict(
            Artifact::Checks,
            lines
                .get(&format!("round-{r}/checks.md"))
                .map(String::as_str),
        );
        let first_build = stages
            .iter()
            .find(|x| x.round == Some(r) && x.stage == "build")
            .map(|x| x.at.as_str());
        children.push((
            INS_ROUND,
            vec![
                int(r),
                opt(gate.as_deref()),
                i(size.and_then(|x| x.get("files"))).map_or(Param::Null, int),
                i(size.and_then(|x| x.get("insertions"))).map_or(Param::Null, int),
                i(size.and_then(|x| x.get("deletions"))).map_or(Param::Null, int),
                int(continues.get(&r).copied().unwrap_or(0)),
                opt(first_build),
            ],
        ));
        // lenses of the round: its review files and its review_log entry
        let prefix = format!("round-{r}/review-");
        let mut lenses: BTreeSet<String> = lines
            .keys()
            .filter_map(|p| p.strip_prefix(&prefix)?.strip_suffix(".md"))
            .map(str::to_owned)
            .collect();
        let log = review_log.and_then(|l| obj(l.get(&r.to_string())));
        lenses.extend(log.into_iter().flatten().map(|(k, _)| k.clone()));
        for lens in lenses {
            let who = log.and_then(|l| s(l.get(&lens))).map(parse_reviewer);
            // without a log entry, the current round's reviewer is the configured one
            let who = who.or_else(|| {
                (Some(r) == round)
                    .then(|| reviewers.and_then(|m| m.get(&lens)))
                    .flatten()
                    .map(|x| {
                        (
                            s(x.get("agent")).map(str::to_owned),
                            s(x.get("model")).map(str::to_owned),
                            s(x.get("effort")).map(str::to_owned),
                        )
                    })
            });
            let (agent, model, effort) = who.unwrap_or((None, None, None));
            let v = verdict(
                Artifact::Review,
                lines.get(&format!("{prefix}{lens}.md")).map(String::as_str),
            );
            children.push((
                INS_ROUND_REVIEW,
                vec![
                    int(r),
                    text(&lens),
                    opt(v.as_deref()),
                    opt(agent.as_deref()),
                    opt(model.as_deref()),
                    opt(effort.as_deref()),
                ],
            ));
        }
    }

    // the lenses now
    let reviews = obj(g("reviews"));
    let skipped = obj(g("skipped_reviews"));
    let holds: BTreeSet<&str> = arr(g("holds")).iter().filter_map(Value::as_str).collect();
    let mut lenses: BTreeSet<&str> = BTreeSet::new();
    for m in [reviewers, reviews, skipped].into_iter().flatten() {
        lenses.extend(m.keys().map(String::as_str));
    }
    for lens in lenses {
        let who = reviewers.and_then(|m| m.get(lens));
        children.push((
            INS_REVIEWER,
            vec![
                text(lens),
                opt(s(who.and_then(|x| x.get("agent")))),
                opt(s(who.and_then(|x| x.get("model")))),
                opt(s(who.and_then(|x| x.get("effort")))),
                opt(s(reviews.and_then(|m| m.get(lens)))),
                opt(s(skipped.and_then(|m| m.get(lens)))),
                int(i64::from(holds.contains(lens))),
            ],
        ));
    }

    // answers → findings
    let (mut findings, mut disputed) = (0, 0);
    for (r, answers) in obj(g("answers")).into_iter().flatten() {
        let Some(r) = round_key(r) else { continue };
        for (finding, a) in obj(Some(answers)).into_iter().flatten() {
            let status = s(a.get("status"));
            findings += 1;
            disputed += i64::from(matches!(status, Some("disagree" | "declined")));
            children.push((
                INS_FINDING,
                vec![
                    int(r),
                    text(finding),
                    opt(finding.split_whitespace().next()),
                    opt(status),
                    opt(s(a.get("text"))),
                ],
            ));
        }
    }

    // builder_log
    let builder_log = arr(g("builder_log"));
    for (n, x) in builder_log.iter().enumerate() {
        let who = x.get("builder");
        children.push((
            INS_BUILDER,
            vec![
                int(n as i64),
                i(x.get("round")).map_or(Param::Null, int),
                opt(s(who.and_then(|w| w.get("agent")))),
                opt(s(who.and_then(|w| w.get("model")))),
                opt(s(x.get("why"))),
            ],
        ));
    }

    // accepted[] and approved
    let mut approvals = 0;
    let mut human = 0;
    for x in arr(g("accepted")) {
        children.push((
            INS_APPROVAL,
            vec![
                int(approvals),
                text("accepted"),
                opt(s(x.get("by"))),
                int(1),
                i(x.get("round")).map_or(Param::Null, int),
                opt(s(x.get("after"))),
                opt(s(x.get("note"))),
                Param::Null,
                opt(s(x.get("at"))),
            ],
        ));
        approvals += 1;
        human += 1;
    }
    if let Some(x) = obj(g("approved")) {
        let by = s(x.get("by"));
        let is_human = by == Some("human");
        children.push((
            INS_APPROVAL,
            vec![
                int(approvals),
                text("approved"),
                opt(by),
                int(i64::from(is_human)),
                i(x.get("round")).map_or(Param::Null, int),
                Param::Null,
                Param::Null,
                opt(s(x.get("head"))),
                Param::Null,
            ],
        ));
        human += i64::from(is_human);
    }

    let mut surfaces = BTreeSet::new();
    for x in arr(intake.and_then(|v| v.get("surfaces"))) {
        if let Some(x) = s(Some(x)) {
            if surfaces.insert(x) {
                children.push((INS_SURFACE, vec![text(x)]));
            }
        }
    }
    for (n, x) in arr(g("follow_ups")).iter().enumerate() {
        children.push((
            INS_FOLLOW_UP,
            vec![
                int(n as i64),
                opt(s_or_num(x.get("issue")).as_deref()),
                opt(s(x.get("title"))),
            ],
        ));
    }
    let slices = arr(g("slices"));
    let mut slice_numbers = BTreeSet::new();
    let mut slices_done = 0;
    for (n, x) in slices.iter().enumerate() {
        let number = i(x.get("n")).unwrap_or(n as i64 + 1);
        if !slice_numbers.insert(number) {
            continue;
        }
        let state = s(x.get("state"));
        slices_done += i64::from(state == Some("done"));
        children.push((
            INS_SLICE,
            vec![
                int(number),
                opt(s(x.get("title"))),
                opt(state),
                int(i64::from(b(x.get("taken_over")))),
            ],
        ));
    }

    let continues_total: i64 = continues.values().sum();
    let review_problems = obj(g("review_problems")).map_or(0, Map::len) as i64;
    let num = |v: Option<i64>| v.map_or(Param::Null, int);
    let day = |n: usize| {
        started
            .as_deref()
            .filter(|x| x.len() >= n && parse_iso(x).is_some())
            .map(|x| x[..n].to_owned())
    };
    let columns = vec![
        int(PROJECTION_VERSION),
        text(&title),
        opt(stage.as_deref()),
        num(round),
        num(i(g("round_limit"))),
        opt(s(g("tracker"))),
        opt(s_or_num(g("issue")).as_deref()),
        opt(s(g("issue_url"))),
        num(i(g("pr"))),
        opt(s(g("pr_url"))),
        opt(s(g("base"))),
        opt(s(g("branch"))),
        opt(s(g("fork_point"))),
        opt(s(g("review_head"))),
        opt(s(g("gate"))),
        int(i64::from(b(g("spec_skipped")))),
        opt(s(intake.and_then(|x| x.get("decision")))),
        opt(s(intake.and_then(|x| x.get("risk")))),
        opt(s(intake.and_then(|x| x.get("size")))),
        int(i64::from(b(intake.and_then(|x| x.get("split"))))),
        int(i64::from(b(intake.and_then(|x| x.get("rescoped"))))),
        opt(s(builder.and_then(|x| x.get("agent")))),
        opt(s(builder.and_then(|x| x.get("model")))),
        opt(s(builder.and_then(|x| x.get("effort")))),
        opt(s(g("paused").and_then(|x| x.get("after")))),
        opt(started.as_deref()),
        opt(ended.as_deref()),
        text(stage_group(stage.as_deref().unwrap_or(""))),
        opt(day(10).as_deref()),
        opt(day(7).as_deref()),
        opt(last_activity.as_deref()),
        num(duration_s),
        int(wait_s),
        num(work_s),
        real(cost_usd),
        real(claude),
        real(codex),
        real(other),
        opt(cost_split.as_deref()),
        int(tokens_in),
        int(tokens_cached),
        int(tokens_out),
        int(slice_numbers.len() as i64),
        int(slices_done),
        int(findings),
        int(disputed),
        int(builder_log.len() as i64),
        int(continues_total),
        int(human),
        int(review_problems),
        opt(version("commit")),
        opt(version("date")),
        opt(version("source")),
        text(seen.first_seen),
        text(seen.last_seen),
        opt(seen.removed_at),
    ];
    debug_assert_eq!(columns.len(), JOB_COLUMNS.len());
    Projection {
        columns,
        stage,
        title,
        children,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn seen() -> Seen<'static> {
        Seen {
            first_seen: "2026-11-18T00:00:00Z",
            last_seen: "2026-11-18T00:00:00Z",
            removed_at: None,
        }
    }

    fn col<'a>(p: &'a Projection, name: &str) -> &'a Param {
        let n = JOB_COLUMNS.iter().position(|c| *c == name).unwrap();
        &p.columns[n]
    }

    fn rows<'a>(p: &'a Projection, sql: &str) -> Vec<&'a Vec<Param>> {
        p.children
            .iter()
            .filter(|(s, _)| *s == sql)
            .map(|(_, v)| v)
            .collect()
    }

    #[test]
    fn verdict_reads_like_the_dashboard() {
        use Artifact::{Checks, Review};
        assert_eq!(verdict(Checks, None), None);
        assert_eq!(verdict(Checks, Some("GATE: PASS")).as_deref(), Some("PASS"));
        assert_eq!(
            verdict(Review, Some("VERDICT: CHANGES")).as_deref(),
            Some("CHANGES")
        );
        assert_eq!(
            verdict(Review, Some("# Review")).as_deref(),
            Some("invalid")
        );
        // each kind has its own prefix and values
        assert_eq!(
            verdict(Review, Some("GATE: PASS")).as_deref(),
            Some("invalid")
        );
        assert_eq!(
            verdict(Review, Some("VERDICT: FAIL")).as_deref(),
            Some("invalid")
        );
        assert_eq!(
            verdict(Checks, Some("GATE: CHANGES")).as_deref(),
            Some("invalid")
        );
        assert_eq!(
            verdict(Checks, Some("VERDICT: PASS")).as_deref(),
            Some("invalid")
        );
    }

    /// Every file of a job folder in factory/tests/fixtures/, as the reporter sends it
    /// (UTF-8 with U+FFFD for bad bytes): job.json and the first line of each .md.
    fn fixture(name: &str) -> (Value, HashMap<String, String>, Value) {
        fn walk(dir: &std::path::Path, root: &std::path::Path, out: &mut HashMap<String, String>) {
            for e in std::fs::read_dir(dir).unwrap() {
                let p = e.unwrap().path();
                if p.is_dir() {
                    walk(&p, root, out);
                } else {
                    let rel = p
                        .strip_prefix(root)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/");
                    let (rel, bytes) = if rel.ends_with(".md") {
                        (rel.as_str(), std::fs::read(&p).unwrap())
                    } else if let Some(rel) =
                        rel.strip_suffix(".hex").filter(|p| p.ends_with(".md"))
                    {
                        // Keep invalid UTF-8 out of the old updater's input.
                        let bytes = std::fs::read_to_string(&p)
                            .unwrap()
                            .split_ascii_whitespace()
                            .map(|byte| u8::from_str_radix(byte, 16).unwrap())
                            .collect();
                        (rel, bytes)
                    } else {
                        continue;
                    };
                    out.insert(
                        rel.to_owned(),
                        first_line(&String::from_utf8_lossy(&bytes)).to_owned(),
                    );
                }
            }
        }
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../factory/tests/fixtures")
            .join(name);
        let read = |f: &str| -> Value {
            serde_json::from_str(&std::fs::read_to_string(root.join(f)).unwrap()).unwrap()
        };
        let mut lines = HashMap::new();
        walk(&root, &root, &mut lines);
        (read("job.json"), lines, read("expected.json"))
    }

    #[test]
    fn verdicts_match_the_shared_fixtures() {
        let (doc, lines, expected) = fixture("verdicts");
        let want = |path: &str| -> Param {
            match expected["verdicts"][path].as_str() {
                None | Some("pending") => Param::Null,
                Some(v) => text(v),
            }
        };
        let p = project(&doc, &lines, &seen());
        let rounds = rows(&p, INS_ROUND);
        assert_eq!(rounds.len(), 16);
        for r in &rounds {
            let path = format!(
                "round-{}/checks.md",
                match r[0] {
                    Param::Integer(n) => n,
                    _ => unreachable!(),
                }
            );
            assert_eq!(r[1], want(&path), "{path}");
        }
        let reviews = rows(&p, INS_ROUND_REVIEW);
        let mut seen_paths = 0;
        for r in &reviews {
            let (Param::Integer(n), Param::Text(lens)) = (&r[0], &r[1]) else {
                unreachable!()
            };
            let path = format!("round-{n}/review-{lens}.md");
            assert_eq!(r[2], want(&path), "{path}");
            seen_paths += 1;
        }
        let reviews_expected = expected["verdicts"]
            .as_object()
            .unwrap()
            .keys()
            .filter(|k| k.contains("/review-"))
            .count();
        assert_eq!(
            seen_paths, reviews_expected,
            "every review artifact is projected"
        );
        // the historical round keeps the reviewers its review_log recorded
        for (lens, who) in expected["reviewers"]["1"].as_object().unwrap() {
            let row = reviews
                .iter()
                .find(|r| r[0] == int(1) && r[1] == text(lens))
                .unwrap();
            for (n, key) in [(3, "agent"), (4, "model"), (5, "effort")] {
                let want = who[key].as_str().map_or(Param::Null, text);
                assert_eq!(row[n], want, "round 1 {lens} {key}");
            }
        }
    }

    #[test]
    fn helpers() {
        assert_eq!(role_base("builder-s2"), "builder");
        assert_eq!(role_base("reviewer-code"), "reviewer-code");
        assert_eq!(role_base("x-s"), "x-s");
        assert_eq!(round_key("3-s2"), Some(3));
        assert_eq!(
            parse_reviewer("claude/sonnet:medium"),
            (
                Some("claude".into()),
                Some("sonnet".into()),
                Some("medium".into())
            )
        );
        assert_eq!(
            parse_reviewer("claude/opus"),
            (Some("claude".into()), Some("opus".into()), None)
        );
    }

    #[test]
    fn a_full_job() {
        let doc = json!({
            "id": "007-x", "title": "fix: x", "stage": "merged", "round": 2, "round_limit": 6,
            "issue": "parity-roadmap/01", "pr": 12, "tracker": "local",
            "intake": {"decision": "ACCEPT", "risk": "high", "size": "small", "split": false,
                       "surfaces": ["ui", "ui", "security"]},
            "agents": {"builder": {"agent": "claude", "model": "opus", "effort": "high"},
                       "reviewers": {"code": {"agent": "codex"}, "ui": {"agent": "claude", "model": "sonnet"}}},
            "reviews": {"code": "PASS", "ui": "PASS"},
            "skipped_reviews": {"ux": "PASS in round 1"},
            "holds": ["ui"],
            "started": "2026-11-13T10:00:00Z", "ended": "2026-11-13T12:00:00Z",
            "history": [
                {"stage": "intake", "round": 0, "at": "2026-11-13T10:00:00Z"},
                {"stage": "build", "round": 1, "at": "2026-11-13T10:10:00Z"},
                {"stage": "needs-human", "round": 1, "at": "2026-11-13T10:40:00Z"},
                {"stage": "build", "round": 2, "at": "2026-11-13T11:40:00Z"},
                {"stage": "merged", "round": 2, "at": "2026-11-13T12:00:00Z"}
            ],
            "cost_usd": 3.5, "cost_by_agent": {"claude": 2.0, "codex": 1.0},
            "cost_breakdown": [
                {"role": "builder-s1", "agent": "claude", "model": "claude-opus-5-5", "sessions": 1,
                 "input_tokens": 10, "cached_tokens": 100, "output_tokens": 5, "cost_usd": 2.0},
                {"role": "reviewer-code", "agent": "codex", "model": "gpt-6.1-terra", "sessions": 2,
                 "input_tokens": 1, "cached_tokens": 2, "output_tokens": 3, "cost_usd": 1.0}
            ],
            "diff_sizes": {"1": {"files": 3, "insertions": 40, "deletions": 2}},
            "continues": {"1": 1, "1-s2": 2},
            "review_log": {"1": {"code": "codex/gpt-6.1-terra:high"}},
            "answers": {"2": {"code F1": {"status": "fixed", "text": "done"},
                              "ui F1": {"status": "disagree", "text": "no"}}},
            "builder_log": [{"round": 2, "builder": {"agent": "codex", "model": "x"}, "why": "CHANGES from ui"}],
            "accepted": [{"after": "spec", "by": "Xuresch", "note": "ok", "at": "2026-11-13T10:05:00Z"}],
            "approved": {"round": 2, "head": "abc", "by": "approver"},
            "review_problems": {"ux": "empty"},
            "slices": [{"n": 1, "title": "a", "state": "done"}, {"n": 2, "title": "b", "state": "running"}],
            "follow_ups": [{"issue": "241", "title": "later"}],
            "paused": {"after": "spec"}
        });
        let lines: HashMap<String, String> = [
            ("round-1/checks.md", "GATE: PASS"),
            ("round-1/review-code.md", "VERDICT: CHANGES"),
            ("round-2/checks.md", "GATE: PASS"),
            ("round-2/review-ui.md", "VERDICT: PASS"),
            ("spec.md", "# Spec"),
        ]
        .into_iter()
        .map(|(a, b)| (a.to_owned(), b.to_owned()))
        .collect();
        let p = project(&doc, &lines, &seen());
        assert_eq!(p.columns.len(), JOB_COLUMNS.len());
        assert_eq!(*col(&p, "stage_group"), text("merged"));
        assert_eq!(*col(&p, "issue_ref"), text("parity-roadmap/01"));
        assert_eq!(*col(&p, "started_day"), text("2026-11-13"));
        assert_eq!(*col(&p, "started_month"), text("2026-11"));
        assert_eq!(*col(&p, "duration_s"), int(7200));
        assert_eq!(*col(&p, "wait_s"), int(3600));
        assert_eq!(*col(&p, "work_s"), int(3600));
        assert_eq!(*col(&p, "cost_claude"), real(2.0));
        assert_eq!(*col(&p, "cost_other"), real(0.5));
        assert_eq!(*col(&p, "cached_tokens"), int(102));
        assert_eq!(*col(&p, "slices_total"), int(2));
        assert_eq!(*col(&p, "slices_done"), int(1));
        assert_eq!(*col(&p, "findings"), int(2));
        assert_eq!(*col(&p, "findings_disputed"), int(1));
        assert_eq!(*col(&p, "continues"), int(3));
        assert_eq!(*col(&p, "human_approvals"), int(1));
        assert_eq!(*col(&p, "review_problems"), int(1));
        assert_eq!(*col(&p, "paused_after"), text("spec"));

        let stages = rows(&p, INS_STAGE);
        assert_eq!(stages.len(), 5);
        assert_eq!(stages[1][2], text("intake")); // from_stage
        assert_eq!(stages[4][5], int(0)); // merged lasts until ended
        let costs = rows(&p, INS_COST);
        assert_eq!(costs[0][2], text("builder"));
        let rounds = rows(&p, INS_ROUND);
        assert_eq!(rounds.len(), 2);
        assert_eq!(rounds[0][1], text("PASS"));
        assert_eq!(rounds[0][2], int(3));
        assert_eq!(rounds[0][5], int(3)); // 1 + 2 from the slice
        assert_eq!(rounds[1][2], Param::Null);
        let rr = rows(&p, INS_ROUND_REVIEW);
        assert_eq!(rr.len(), 2);
        assert_eq!(rr[0][1], text("code"));
        assert_eq!(rr[0][2], text("CHANGES"));
        assert_eq!(rr[0][4], text("gpt-6.1-terra"));
        assert_eq!(rr[1][1], text("ui"));
        assert_eq!(rr[1][4], text("sonnet")); // current round falls back to agents.reviewers
        let reviewers = rows(&p, INS_REVIEWER);
        assert_eq!(reviewers.len(), 3);
        assert_eq!(reviewers[1][6], int(1)); // ui is held
        assert_eq!(reviewers[2][5], text("PASS in round 1"));
        assert_eq!(rows(&p, INS_SURFACE).len(), 2);
        assert_eq!(rows(&p, INS_APPROVAL).len(), 2);
        assert_eq!(rows(&p, INS_FINDING)[1][2], text("ui"));
    }

    #[test]
    fn agent_split_matches_shared_job_summaries() {
        let fixtures: Value = serde_json::from_str(include_str!(
            "../../factory/tests/job_summary_fixtures.json"
        ))
        .unwrap();
        for fixture in fixtures["jobs"].as_array().unwrap() {
            let doc = &fixture["doc"];
            let p = project(doc, &HashMap::new(), &seen());
            for (agent, column) in [
                ("claude", "cost_claude"),
                ("codex", "cost_codex"),
                ("other", "cost_other"),
            ] {
                let Param::Real(got) = col(&p, column) else {
                    panic!("{column} must be a dollar amount");
                };
                let want = fixture["expect"][agent].as_f64().unwrap();
                assert!(
                    (got - want).abs() < 1e-9,
                    "{} {agent}: expected {want}, got {got}",
                    doc["id"]
                );
            }
        }
    }

    #[test]
    fn cost_split_keeps_what_was_recorded() {
        let split = |doc: serde_json::Value| {
            col(&project(&doc, &HashMap::new(), &seen()), "cost_split").clone()
        };
        assert_eq!(
            split(json!({"cost_usd": 3.0, "cost_by_agent": {"claude": 0, "codex": 0}})),
            text(r#"{"claude":0,"codex":0}"#)
        );
        assert_eq!(
            split(json!({"cost_usd": 3.0, "cost_by_agent": {}})),
            text("{}")
        );
        assert_eq!(split(json!({"cost_usd": 12.0})), Param::Null);
        assert_eq!(split(json!({"cost_by_agent": "x"})), Param::Null);
    }

    #[test]
    fn an_empty_job_projects() {
        let p = project(&json!({}), &HashMap::new(), &seen());
        assert_eq!(p.columns.len(), JOB_COLUMNS.len());
        assert_eq!(*col(&p, "stage_group"), text("other"));
        assert_eq!(*col(&p, "duration_s"), Param::Null);
        assert!(p.children.is_empty());
    }

    #[test]
    fn odd_types_do_not_panic() {
        let doc = json!({"stage": 3, "history": "x", "cost_breakdown": {"a": 1}, "slices": null,
                         "answers": [1], "issue": 5, "started": "not a date", "intake": "?"});
        let p = project(&doc, &HashMap::new(), &seen());
        assert_eq!(*col(&p, "issue_ref"), text("5"));
        assert_eq!(*col(&p, "started_day"), Param::Null);
    }
}
