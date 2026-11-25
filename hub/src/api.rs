//! Read API built exclusively from the projected columns and child tables.
use std::collections::{HashMap, HashSet};

use crate::{
    store::{self, Error, Row},
    tree::{all_served_ids, repo_served_ids},
    util::quote,
    Hub,
};
use serde_json::{json, Map, Value};

fn val(row: &Row, key: &str) -> Value {
    row.get(key).cloned().unwrap_or(Value::Null)
}
fn boolean(row: &Row, key: &str) -> bool {
    store::get_int(row, key).unwrap_or(0) != 0
}
fn fields(row: &Row, names: &[&str]) -> Value {
    Value::Object(
        names
            .iter()
            .map(|&name| (name.to_owned(), val(row, name)))
            .collect(),
    )
}

const JOB_FROM: &str = "FROM jobs j JOIN checkouts c ON c.id=j.checkout_id \
     JOIN repos r ON r.id=c.repo_id JOIN machines m ON m.id=c.machine_id";

#[derive(Clone, Copy)]
pub enum SummaryScope<'a> {
    List {
        repo: Option<&'a str>,
        removed: bool,
    },
    Detail {
        repo: Option<&'a str>,
        job_id: i64,
        served: &'a str,
        prefixed: bool,
    },
    Overview,
}

impl<'a> SummaryScope<'a> {
    fn repo(self) -> Option<&'a str> {
        match self {
            Self::List { repo, .. } | Self::Detail { repo, .. } => repo,
            Self::Overview => None,
        }
    }

    fn filter(self) -> (String, Vec<store::Param>) {
        let mut conditions = Vec::new();
        let mut params = Vec::new();
        if let Some(repo) = self.repo() {
            conditions.push("r.slug=?");
            params.push(store::text(repo));
        }
        if !matches!(self, Self::List { removed: true, .. }) {
            conditions.push("j.removed_at IS NULL AND c.removed_at IS NULL");
        }
        match self {
            Self::Detail { job_id, .. } => {
                conditions.push("j.id=?");
                params.push(store::int(job_id));
            }
            Self::Overview => conditions.push(
                "(j.stage_group IN ('live', 'attention') OR j.id IN (\
                SELECT recent.id FROM jobs recent JOIN checkouts rc ON rc.id=recent.checkout_id \
                WHERE recent.removed_at IS NULL AND rc.removed_at IS NULL \
                AND recent.stage_group IN ('merged', 'rejected') \
                ORDER BY recent.last_activity DESC LIMIT 20))",
            ),
            Self::List { .. } => {}
        }
        let filter = if conditions.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", conditions.join(" AND "))
        };
        (filter, params)
    }
}

impl Hub {
    /// Load selected summaries in a bounded number of queries.
    pub async fn summaries(&self, scope: SummaryScope<'_>) -> Result<Vec<Value>, Error> {
        let repo = scope.repo();
        let (filter, params) = scope.filter();
        let rows = self
            .store
            .query(
                &format!(
                    "SELECT j.id, j.job_key, j.title, j.stage, j.stage_group, j.round, \
                 j.round_limit, j.issue_ref, j.issue_url, j.pr, j.pr_url, j.base, j.branch, \
                 j.gate, j.spec_skipped, j.intake_decision, j.intake_risk, j.intake_size, \
                 j.intake_split, j.intake_rescoped, j.builder_agent, j.builder_model, \
                 j.builder_effort, j.paused_after, j.started, j.ended, j.last_activity, \
                 j.duration_s, j.wait_s, j.work_s, j.cost_usd, j.cost_claude, j.cost_codex, \
                 j.cost_other, j.cost_split, j.input_tokens, j.cached_tokens, j.output_tokens, j.findings, \
                 j.findings_disputed, j.builder_changes, j.continues, j.human_approvals, \
                 j.review_problems, j.template_commit, j.template_date, j.removed_at, \
                 r.slug AS repo, m.name AS machine, \
                 c.removed_at AS checkout_removed {JOB_FROM}{filter} ORDER BY j.last_activity DESC"
                ),
                params.clone(),
            )
            .await?;
        let mut children: HashMap<&str, HashMap<i64, Vec<Row>>> = HashMap::new();
        for (table, columns, order) in [
            ("job_surfaces", "surface", "surface"),
            ("job_slices", "n, title, state", "n"),
            ("job_stages", "stage, from_stage, round, at, duration_s", "seq"),
            ("job_rounds", "round, gate_verdict, files, insertions, deletions, continues", "round"),
            ("job_round_reviews", "round, lens, verdict", "round, lens"),
            ("job_reviewers", "lens, agent, model, effort, verdict", "lens"),
            ("job_costs", "role, role_base, agent, model, sessions, input_tokens, cached_tokens, output_tokens, cost_usd", "seq"),
        ] {
            let mut grouped: HashMap<i64, Vec<Row>> = HashMap::new();
            let (sql, child_params) = match scope {
                SummaryScope::Detail { job_id, .. } => (
                    format!("SELECT job_id, {columns} FROM {table} WHERE job_id=? ORDER BY {order}"),
                    vec![store::int(job_id)],
                ),
                _ => (
                    format!("SELECT job_id, {columns} FROM {table} \
                         WHERE job_id IN (SELECT j.id {JOB_FROM}{filter}) ORDER BY {order}"),
                    params.clone(),
                ),
            };
            for row in self.store.query(&sql, child_params).await? {
                grouped.entry(store::get_int(&row, "job_id").unwrap_or(0)).or_default().push(row);
            }
            children.insert(table, grouped);
        }
        let shown: Vec<_> = rows
            .iter()
            .filter(|r| val(r, "removed_at").is_null() && val(r, "checkout_removed").is_null())
            .collect();
        let make_ids = |selected: &[&Row]| {
            if repo.is_some() {
                let keys: Vec<_> = selected
                    .iter()
                    .map(|r| {
                        (
                            store::get_or_empty(r, "machine"),
                            store::get_or_empty(r, "job_key"),
                        )
                    })
                    .collect();
                repo_served_ids(&keys)
            } else {
                let keys: Vec<_> = selected
                    .iter()
                    .map(|r| {
                        (
                            store::get_or_empty(r, "repo"),
                            store::get_or_empty(r, "machine"),
                            store::get_or_empty(r, "job_key"),
                        )
                    })
                    .collect();
                all_served_ids(&keys)
            }
        };
        let visible_ids: HashMap<i64, String> = shown
            .iter()
            .zip(make_ids(&shown))
            .map(|(r, id)| (store::get_int(r, "id").unwrap_or(0), id))
            .collect();
        let all_rows: Vec<_> = rows.iter().collect();
        let ids = make_ids(&all_rows);
        let mut repo_machines: HashMap<&str, HashSet<&str>> = HashMap::new();
        for row in &shown {
            repo_machines
                .entry(store::get_or_empty(row, "repo"))
                .or_default()
                .insert(store::get_or_empty(row, "machine"));
        }
        let mut out = Vec::new();
        for (r, id) in rows.iter().zip(ids) {
            let job_id = store::get_int(r, "id").unwrap_or(0);
            let id = match scope {
                SummaryScope::Detail { served, .. } => served.to_owned(),
                _ => visible_ids.get(&job_id).cloned().unwrap_or(id),
            };
            let child = |table: &str| -> &[Row] {
                children
                    .get(table)
                    .and_then(|m| m.get(&job_id))
                    .map_or(&[], Vec::as_slice)
            };
            let mut reviewers = Map::new();
            let mut reviews = Map::new();
            for x in child("job_reviewers") {
                let lens = store::get_or_empty(x, "lens");
                reviewers.insert(lens.to_owned(), fields(x, &["agent", "model", "effort"]));
                if !val(x, "verdict").is_null() {
                    reviews.insert(lens.to_owned(), val(x, "verdict"));
                }
            }
            let rounds: Vec<Value> = child("job_rounds").iter().map(|x| {
                let n = val(x,"round"); let mut rv = Map::new();
                for y in child("job_round_reviews").iter().filter(|y| val(y,"round") == n) { rv.insert(store::get_or_empty(y,"lens").to_owned(), val(y,"verdict")); }
                json!({"round":n,"gate":val(x,"gate_verdict"),"reviews":rv,"files":val(x,"files"),"insertions":val(x,"insertions"),"deletions":val(x,"deletions"),"continues":val(x,"continues")})
            }).collect();
            let repo_name = store::get_or_empty(r, "repo");
            let prefixed = match scope {
                SummaryScope::Detail { prefixed, .. } => prefixed,
                _ => repo_machines.get(repo_name).is_some_and(|m| m.len() > 1),
            };
            let repo_id = if prefixed {
                format!(
                    "{}~{}",
                    store::get_or_empty(r, "machine"),
                    store::get_or_empty(r, "job_key")
                )
            } else {
                store::get_or_empty(r, "job_key").to_owned()
            };
            let mut job = fields(
                r,
                &[
                    "title",
                    "stage",
                    "stage_group",
                    "round",
                    "round_limit",
                    "issue_url",
                    "pr",
                    "pr_url",
                    "base",
                    "branch",
                    "gate",
                    "started",
                    "ended",
                    "template_commit",
                    "template_date",
                    "last_activity",
                    "duration_s",
                    "wait_s",
                    "work_s",
                    "cost_usd",
                ],
            );
            let o = job.as_object_mut().expect("object");
            o.extend(json!({"id":id,"key":val(r,"job_key"),"machine":val(r,"machine"),"repo":repo_name,"href":format!("/r/{}/dashboard.html#job={}",quote(repo_name),quote(&repo_id)),"issue":val(r,"issue_ref"),"spec_skipped":boolean(r,"spec_skipped"),"removed":!val(r,"removed_at").is_null() || !val(r,"checkout_removed").is_null(),
                "cost_by_agent":{"claude":val(r,"cost_claude"),"codex":val(r,"cost_codex"),"other":val(r,"cost_other")},
                "cost_split":store::get(r,"cost_split").and_then(|s| serde_json::from_str::<Value>(s).ok()).filter(Value::is_object).unwrap_or(Value::Null),
                "tokens":{"input":val(r,"input_tokens"),"cached":val(r,"cached_tokens"),"output":val(r,"output_tokens")},
                "cost_breakdown":child("job_costs").iter().map(|x| fields(x,&["role","role_base","agent","model","sessions","input_tokens","cached_tokens","output_tokens","cost_usd"])).collect::<Vec<_>>(),
                "intake":{"decision":val(r,"intake_decision"),"risk":val(r,"intake_risk"),"size":val(r,"intake_size"),"split":boolean(r,"intake_split"),"rescoped":boolean(r,"intake_rescoped"),"surfaces":child("job_surfaces").iter().map(|x| val(x,"surface")).collect::<Vec<_>>()},
                "agents":{"builder":{"agent":val(r,"builder_agent"),"model":val(r,"builder_model"),"effort":val(r,"builder_effort")},"reviewers":reviewers},"reviews":reviews,
                "paused":if val(r,"paused_after").is_null() {Value::Null} else {json!({"after":val(r,"paused_after")})},
                "slices":child("job_slices").iter().map(|x| fields(x,&["n","title","state"])).collect::<Vec<_>>(),
                "history":child("job_stages").iter().map(|x| json!({"stage":val(x,"stage"),"from":val(x,"from_stage"),"round":val(x,"round"),"at":val(x,"at"),"duration_s":val(x,"duration_s")})).collect::<Vec<_>>(),"rounds":rounds,
                "counts":fields(r,&["findings","findings_disputed","builder_changes","continues","human_approvals","review_problems"])}).as_object().expect("object").clone());
            out.push(job);
        }
        Ok(out)
    }

    pub async fn api_jobs(
        &self,
        repo: Option<&str>,
        removed: bool,
    ) -> Result<Option<Value>, Error> {
        let machines = self
            .store
            .query(
                "SELECT DISTINCT m.name FROM machines m \
             JOIN checkouts c ON c.machine_id=m.id JOIN repos r ON r.id=c.repo_id \
             WHERE (? IS NULL OR r.slug=?) AND (c.removed_at IS NULL OR ?=1) ORDER BY m.name",
                vec![
                    store::opt(repo),
                    store::opt(repo),
                    store::int(i64::from(removed)),
                ],
            )
            .await?;
        if let Some(repo) = repo {
            if self
                .store
                .query("SELECT id FROM repos WHERE slug=?", vec![store::text(repo)])
                .await?
                .is_empty()
            {
                return Ok(None);
            }
        }
        let jobs = self.summaries(SummaryScope::List { repo, removed }).await?;
        Ok(Some(
            json!({"repo":repo,"machines":machines.iter().map(|r| val(r,"name")).collect::<Vec<_>>(),"jobs":jobs}),
        ))
    }

    pub async fn api_detail(&self, repo: Option<&str>, id: &str) -> Result<Option<Value>, Error> {
        let identities = self.all_jobs(repo).await?;
        let Some(identity) = identities.iter().find(|job| job.served == id) else {
            return Ok(None);
        };
        let prefixed = identities
            .iter()
            .filter(|x| x.repo == identity.repo)
            .map(|x| x.machine.as_str())
            .collect::<HashSet<_>>()
            .len()
            > 1;
        let Some(mut job) = self
            .summaries(SummaryScope::Detail {
                repo,
                job_id: identity.job_id,
                served: &identity.served,
                prefixed,
            })
            .await?
            .into_iter()
            .next()
        else {
            return Ok(None);
        };
        let rows = self
            .store
            .query(
                "SELECT fork_point, review_head FROM jobs WHERE id=?",
                vec![store::int(identity.job_id)],
            )
            .await?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        let id = identity.job_id;
        let o = job.as_object_mut().expect("object");
        o.insert("fork_point".into(), val(row, "fork_point"));
        o.insert("review_head".into(), val(row, "review_head"));
        for (name, table, order, cols) in [
            (
                "cost_breakdown",
                "job_costs",
                "seq",
                &[
                    "role",
                    "role_base",
                    "agent",
                    "model",
                    "sessions",
                    "input_tokens",
                    "cached_tokens",
                    "output_tokens",
                    "cost_usd",
                ][..],
            ),
            (
                "reviewers",
                "job_reviewers",
                "lens",
                &[
                    "lens",
                    "agent",
                    "model",
                    "effort",
                    "verdict",
                    "skipped_reason",
                    "held",
                ],
            ),
            (
                "round_reviews",
                "job_round_reviews",
                "round, lens",
                &["round", "lens", "verdict", "agent", "model", "effort"],
            ),
            (
                "findings",
                "job_findings",
                "round, finding",
                &["round", "finding", "lens", "status", "answer"],
            ),
            (
                "builder_changes",
                "job_builder_changes",
                "seq",
                &["round", "agent", "model", "reason"],
            ),
            (
                "approvals",
                "job_approvals",
                "seq",
                &[
                    "kind", "by", "human", "round", "after", "note", "head", "at",
                ],
            ),
            (
                "follow_ups",
                "job_follow_ups",
                "seq",
                &["issue_ref", "title"],
            ),
            ("files", "job_files", "path", &["path"]),
        ] {
            let rows = self
                .store
                .query(
                    &format!(
                        "SELECT {} FROM {table} WHERE job_id=? ORDER BY {order}",
                        cols.join(", ")
                    ),
                    vec![store::int(id)],
                )
                .await?;
            let values: Vec<_> = rows
                .iter()
                .map(|r| {
                    if name == "files" {
                        return val(r, "path");
                    }
                    let mut x = fields(r, cols);
                    let obj = x.as_object_mut().expect("object");
                    if name == "follow_ups" {
                        let issue = obj.remove("issue_ref").unwrap_or(Value::Null);
                        obj.insert("issue".into(), issue);
                    }
                    if name == "reviewers" {
                        obj.insert("held".into(), Value::Bool(boolean(r, "held")));
                    }
                    if name == "approvals" {
                        obj.insert("human".into(), Value::Bool(boolean(r, "human")));
                    }
                    x
                })
                .collect();
            o.insert(name.into(), json!(values));
        }
        Ok(Some(job))
    }

    pub async fn api_costs(
        &self,
        group: &str,
        repo: Option<&str>,
        since: Option<&str>,
        until: Option<&str>,
    ) -> Result<Option<Value>, Error> {
        if let Some(repo) = repo {
            if self
                .store
                .query("SELECT id FROM repos WHERE slug=?", vec![store::text(repo)])
                .await?
                .is_empty()
            {
                return Ok(None);
            }
        }
        let (key, costs) = match group {
            "day" => ("j.started_day", false),
            "month" => ("j.started_month", false),
            "repo" => ("r.slug", false),
            "agent" => ("k.agent", true),
            "model" => ("k.model", true),
            "role" => ("k.role_base", true),
            _ => return Ok(None),
        };
        let join = if costs {
            "JOIN job_costs k ON k.job_id=j.id"
        } else {
            ""
        };
        let prefix = if costs { "k" } else { "j" };
        let sql = format!(
            "SELECT {key} AS key, SUM({prefix}.cost_usd) AS cost_usd, \
             SUM({prefix}.input_tokens) AS input_tokens, \
             SUM({prefix}.cached_tokens) AS cached_tokens, \
             SUM({prefix}.output_tokens) AS output_tokens, COUNT(DISTINCT j.id) AS jobs \
             FROM jobs j JOIN checkouts c ON c.id=j.checkout_id \
             JOIN repos r ON r.id=c.repo_id {join} \
             WHERE (? IS NULL OR r.slug=?) AND (? IS NULL OR j.started_day>=?) \
             AND (? IS NULL OR j.started_day<=?) GROUP BY {key} ORDER BY {}",
            if matches!(group, "day" | "month") {
                "key"
            } else {
                "cost_usd DESC, key"
            }
        );
        let rows = self
            .store
            .query(
                &sql,
                vec![
                    store::opt(repo),
                    store::opt(repo),
                    store::opt(since),
                    store::opt(since),
                    store::opt(until),
                    store::opt(until),
                ],
            )
            .await?;
        Ok(Some(json!({"group":group,"rows":rows})))
    }
}
