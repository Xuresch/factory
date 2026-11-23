//! The virtual `factory/` tree under `/r/<owner>/<name>/` and `/all/`, plus the
//! read model both it and the overview use (jobs with their served ids,
//! the aggregated `_subscriptions.json`).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::store::{self, get_or_empty, text, Error};
use crate::util::{html_escape, number, quote};
use crate::Hub;

const TEXT: &str = "text/plain; charset=utf-8";
const JSON: &str = "application/json";

/// (status, content type, body)
pub struct Answer {
    pub status: u16,
    pub ctype: &'static str,
    pub body: Vec<u8>,
}

impl Answer {
    fn ok(ctype: &'static str, body: Vec<u8>) -> Answer {
        Answer {
            status: 200,
            ctype,
            body,
        }
    }

    pub fn not_found() -> Answer {
        Answer {
            status: 404,
            ctype: TEXT,
            body: b"not found\n".to_vec(),
        }
    }

    fn json(v: &Value) -> Answer {
        Answer::ok(JSON, v.to_string().into_bytes())
    }

    /// 200 with the text, or 404 when there is none.
    fn text(body: Option<&str>, ctype: &'static str) -> Answer {
        body.map_or_else(Answer::not_found, |b| {
            Answer::ok(ctype, b.as_bytes().to_vec())
        })
    }
}

pub struct JobRow {
    pub repo: String,
    pub machine: String,
    /// The folder name on the machine.
    pub id: String,
    /// `jobs.id`
    pub job_id: i64,
    /// The id the virtual tree shows for it.
    pub served: String,
}

/// `<machine>~<id>` only when more than one machine has jobs in the repo.
pub fn repo_served_ids(keys: &[(&str, &str)]) -> Vec<String> {
    let machines: HashSet<&str> = keys.iter().map(|(m, _)| *m).collect();
    let prefixed = machines.len() > 1;
    keys.iter()
        .map(|(m, i)| {
            if prefixed {
                format!("{m}~{i}")
            } else {
                (*i).to_owned()
            }
        })
        .collect()
}

/// Served ids across repos: `<name>~<id>`, escalating on a clash to
/// `<name>~<machine>~<id>`, then `<owner>~<name>~<machine>~<id>`.
pub fn all_served_ids(keys: &[(&str, &str, &str)]) -> Vec<String> {
    type Form = fn(&str, &str, &str, &str) -> String;
    let forms: [Form; 3] = [
        |_, n, _, i| format!("{n}~{i}"),
        |_, n, m, i| format!("{n}~{m}~{i}"),
        |o, n, m, i| format!("{o}~{n}~{m}~{i}"),
    ];
    let mut out = vec![String::new(); keys.len()];
    let mut pending: Vec<usize> = (0..keys.len()).collect();
    for (level, form) in forms.iter().enumerate() {
        let names: Vec<(usize, String)> = pending
            .iter()
            .map(|&k| {
                let (repo, machine, id) = keys[k];
                let (owner, name) = repo.split_once('/').unwrap_or(("", repo));
                (k, form(owner, name, machine, id))
            })
            .collect();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for (_, name) in &names {
            *counts.entry(name).or_default() += 1;
        }
        let mut clash = Vec::new();
        for (k, name) in &names {
            if counts[name.as_str()] == 1 || level == forms.len() - 1 {
                out[*k] = name.clone();
            } else {
                clash.push(*k);
            }
        }
        pending = clash;
    }
    out
}

/// What `bin/dashboard` answers for `/_subscriptions.json`: a hash key for a subscription.
fn subscription_key(sub: &Value) -> String {
    format!(
        "{}\0{}",
        sub.get("name").unwrap_or(&Value::Null),
        sub.get("agent").unwrap_or(&Value::Null)
    )
}

/// Merge every machine's `outside` (bin/dashboard summarize()) into one.
fn merge_outside(outsides: &[(String, Value)]) -> Value {
    let ready: Vec<_> = outsides
        .iter()
        .filter(|(_, o)| o.get("status").and_then(Value::as_str) == Some("ready"))
        .collect();
    if ready.is_empty() {
        return json!({"status": "scanning"});
    }
    let mut months: Map<String, Value> = Map::new();
    let mut unpriced: Map<String, Value> = Map::new();
    let mut by_cwd: Vec<Value> = Vec::new();
    let mut sessions = crate::util::Num::Int(0);
    for (machine, o) in ready {
        for (m, agents) in o
            .get("months")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
        {
            let row = months
                .entry(m.clone())
                .or_insert_with(|| json!({"claude": 0.0, "codex": 0.0}));
            for (agent, v) in agents.as_object().into_iter().flatten() {
                let sum = number(row.get(agent)) + number(Some(v));
                row[agent.as_str()] = crate::util::float(sum);
            }
        }
        for (m, models) in o
            .get("unpriced")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
        {
            let row = unpriced.entry(m.clone()).or_insert_with(|| json!({}));
            for (model, n) in models.as_object().into_iter().flatten() {
                let sum = crate::util::Num::of(row.get(model)).add(crate::util::Num::of(Some(n)));
                row[model.as_str()] = sum.to_value();
            }
        }
        for c in o
            .get("by_cwd")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(c) = c.as_object() {
                let cwd = match c.get("cwd") {
                    Some(Value::String(s)) => s.clone(),
                    Some(Value::Null) | None => "None".to_owned(),
                    Some(other) => other.to_string(),
                };
                let mut c = c.clone();
                c.insert("cwd".to_owned(), Value::String(format!("{machine}:{cwd}")));
                by_cwd.push(Value::Object(c));
            }
        }
        if let Some(n) = o.get("factory_sessions").filter(|v| crate::util::truthy(v)) {
            sessions = sessions.add(crate::util::Num::of(Some(n)));
        }
    }
    let total = |c: &Value| number(c.get("claude")) + number(c.get("codex"));
    by_cwd.sort_by(|a, b| total(b).total_cmp(&total(a)));
    json!({"status": "ready", "months": months, "by_cwd": by_cwd, "unpriced": unpriced,
           "factory_sessions": sessions.to_value()})
}

pub fn content_type(path: &str) -> &'static str {
    if path.ends_with(".html") {
        "text/html; charset=utf-8"
    } else if path.ends_with(".json") {
        JSON
    } else if path.ends_with(".md") {
        "text/markdown; charset=utf-8"
    } else {
        TEXT
    }
}

/// An HTML index in `python -m http.server` format: directories end with `/`.
fn listing(title: &str, names: &[String]) -> Answer {
    let items: Vec<String> = names
        .iter()
        .map(|n| format!("<li><a href=\"{}\">{}</a></li>", quote(n), html_escape(n)))
        .collect();
    let shown = html_escape(title);
    let body = format!(
        "<!DOCTYPE HTML>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
         <title>Directory listing for {shown}</title>\n</head>\n<body>\n\
         <h1>Directory listing for {shown}</h1>\n<hr>\n<ul>\n{}\n</ul>\n<hr>\n</body>\n</html>\n",
        items.join("\n")
    );
    Answer::ok("text/html; charset=utf-8", body.into_bytes())
}

/// The jobs a tree shows: not removed, on a checkout still reported.
const SHOWN_JOBS: &str =
    "SELECT r.slug AS repo, m.name AS machine, j.job_key AS id, j.id AS job_id \
     FROM jobs j JOIN checkouts c ON c.id=j.checkout_id JOIN repos r ON r.id=c.repo_id \
     JOIN machines m ON m.id=c.machine_id \
     WHERE j.removed_at IS NULL AND c.removed_at IS NULL";

impl Hub {
    /// Every shown job (of one repo, or of all) with its served id.
    pub async fn all_jobs(&self, repo: Option<&str>) -> Result<Vec<JobRow>, Error> {
        let rows = match repo {
            Some(r) => {
                self.store
                    .query(
                        &format!("{SHOWN_JOBS} AND r.slug=? ORDER BY r.slug, m.name, j.job_key"),
                        vec![text(r)],
                    )
                    .await?
            }
            None => {
                self.store
                    .query(
                        &format!("{SHOWN_JOBS} ORDER BY r.slug, m.name, j.job_key"),
                        vec![],
                    )
                    .await?
            }
        };
        let mut rows: Vec<JobRow> = rows
            .iter()
            .map(|row| JobRow {
                repo: get_or_empty(row, "repo").to_owned(),
                machine: get_or_empty(row, "machine").to_owned(),
                id: get_or_empty(row, "id").to_owned(),
                job_id: store::get_int(row, "job_id").unwrap_or(0),
                served: String::new(),
            })
            .collect();
        let served = if repo.is_some() {
            let keys: Vec<_> = rows
                .iter()
                .map(|x| (x.machine.as_str(), x.id.as_str()))
                .collect();
            repo_served_ids(&keys)
        } else {
            let keys: Vec<_> = rows
                .iter()
                .map(|x| (x.repo.as_str(), x.machine.as_str(), x.id.as_str()))
                .collect();
            all_served_ids(&keys)
        };
        for (x, s) in rows.iter_mut().zip(served) {
            x.served = s;
        }
        Ok(rows)
    }

    /// A stored job.json, with `id` set to the served id.
    pub async fn job_doc(&self, job_id: i64, served: &str) -> Result<Value, Error> {
        let rows = self
            .store
            .query("SELECT doc FROM jobs WHERE id=?", vec![store::int(job_id)])
            .await?;
        let mut doc: Value = rows
            .first()
            .and_then(|r| serde_json::from_str(get_or_empty(r, "doc")).ok())
            .unwrap_or_else(|| json!({}));
        if let Some(o) = doc.as_object_mut() {
            if o.get("id").and_then(Value::as_str) != Some(served) {
                o.insert("id".to_owned(), Value::String(served.to_owned()));
            }
        }
        Ok(doc)
    }

    /// What bin/dashboard's `/_subscriptions.json` answers, over every repo and machine.
    pub async fn subscriptions(&self) -> Result<Value, Error> {
        let machines = self
            .store
            .query("SELECT id, name FROM machines ORDER BY name", vec![])
            .await?;
        if machines.is_empty() {
            return Ok(json!({"configured": false, "config": "factory hub"}));
        }
        let mut subs = Vec::new();
        let mut seen = HashSet::new();
        for row in self
            .store
            .query(
                "SELECT s.name AS name, s.agent AS agent, s.usd_per_month AS usd FROM subscriptions s \
                 JOIN machines m ON m.id=s.machine_id ORDER BY m.name, s.seq",
                vec![],
            )
            .await?
        {
            let sub = json!({"name": row["name"], "agent": row["agent"],
                             "usd_per_month": crate::util::float(store::get_f64(&row, "usd"))});
            if seen.insert(subscription_key(&sub)) {
                subs.push(sub);
            }
        }
        let outsides: Vec<(String, Value)> = self
            .store
            .query(
                "SELECT m.name AS machine, o.doc AS doc FROM outside_scans o \
                 JOIN machines m ON m.id=o.machine_id ORDER BY m.name",
                vec![],
            )
            .await?
            .iter()
            .filter_map(|r| {
                let doc = serde_json::from_str(get_or_empty(r, "doc")).ok()?;
                Some((get_or_empty(r, "machine").to_owned(), doc))
            })
            .collect();
        // every job counts for the costs, also those gone from their machine
        let mut projects: BTreeMap<String, Vec<Value>> = BTreeMap::new();
        for row in self
            .store
            .query(
                "SELECT r.slug AS repo, j.job_key AS id, j.stage AS stage, j.started AS started, \
                 j.ended AS ended, j.cost_usd AS cost_usd, j.cost_claude AS claude, j.cost_codex AS codex \
                 FROM jobs j JOIN checkouts c ON c.id=j.checkout_id JOIN repos r ON r.id=c.repo_id \
                 ORDER BY r.slug, c.machine_id, j.job_key",
                vec![],
            )
            .await?
        {
            // both agents, zeroes too: an empty split would read as a total-only job (all claude)
            let mut by_agent = Map::new();
            for agent in ["claude", "codex"] {
                by_agent.insert(
                    agent.to_owned(),
                    crate::util::float(store::get_f64(&row, agent)),
                );
            }
            projects
                .entry(get_or_empty(&row, "repo").to_owned())
                .or_default()
                .push(json!({"id": row["id"], "stage": row["stage"], "started": row["started"],
                             "ended": row["ended"],
                             "cost_usd": crate::util::float(store::get_f64(&row, "cost_usd")),
                             "cost_by_agent": by_agent}));
        }
        let projects: Vec<Value> = projects
            .into_iter()
            .map(|(name, jobs)| json!({"name": name, "jobs": jobs, "missing": false}))
            .collect();
        Ok(json!({"subscriptions": subs, "config": "factory hub",
                  "outside": merge_outside(&outsides), "projects": projects}))
    }

    /// The answer for a path below `/r/<repo>/` or `/all/` (repo None).
    pub async fn tree_answer(&self, repo: Option<&str>, rest: &str) -> Result<Answer, Error> {
        let parts: Vec<&str> = rest.split('/').collect();
        if rest == "dashboard.html" {
            return Ok(match tokio::fs::read(&self.dashboard).await {
                Ok(body) => Answer::ok("text/html; charset=utf-8", body),
                Err(_) => Answer {
                    status: 404,
                    ctype: TEXT,
                    body: b"dashboard.html not found\n".to_vec(),
                },
            });
        }
        if matches!(rest, "job-summary.js" | "cost-aggregation.js") {
            let path = self.dashboard.with_file_name(rest);
            return Ok(match tokio::fs::read(&path).await {
                Ok(body) => Answer::ok("text/javascript; charset=utf-8", body),
                Err(_) => Answer::not_found(),
            });
        }
        if rest == "hub" {
            return Ok(Answer::json(
                &json!({"repo": repo.unwrap_or("all"), "overview": "/"}),
            ));
        }
        if rest == "_subscriptions.json" {
            return Ok(Answer::json(&self.subscriptions().await?));
        }
        if rest == "config.json" {
            let base =
                "SELECT c.config_doc AS config FROM checkouts c JOIN repos r ON r.id=c.repo_id \
                        WHERE c.config_doc IS NOT NULL AND c.removed_at IS NULL";
            let rows = match repo {
                Some(r) => {
                    self.store
                        .query(
                            &format!("{base} AND r.slug=? ORDER BY c.last_seen DESC LIMIT 1"),
                            vec![text(r)],
                        )
                        .await?
                }
                None => {
                    self.store
                        .query(&format!("{base} ORDER BY c.last_seen DESC LIMIT 1"), vec![])
                        .await?
                }
            };
            return Ok(Answer::text(
                rows.first().and_then(|r| store::get(r, "config")),
                JSON,
            ));
        }
        if let (Some(repo), ".scratch", true) = (repo, parts[0], parts.len() > 1) {
            let rows = self
                .store
                .query(
                    "SELECT t.content AS content FROM tickets t JOIN checkouts c ON c.id=t.checkout_id \
                     JOIN repos r ON r.id=c.repo_id WHERE r.slug=? AND t.path=? \
                     ORDER BY t.updated DESC LIMIT 1",
                    vec![text(repo), text(rest)],
                )
                .await?;
            return Ok(Answer::text(
                rows.first().and_then(|r| store::get(r, "content")),
                content_type(rest),
            ));
        }
        if parts[0] == "jobs" {
            return self.jobs_answer(repo, &parts).await;
        }
        Ok(Answer::not_found())
    }

    async fn jobs_answer(&self, repo: Option<&str>, parts: &[&str]) -> Result<Answer, Error> {
        if parts == ["jobs", ""] {
            let names: BTreeSet<String> = self
                .all_jobs(repo)
                .await?
                .into_iter()
                .map(|x| x.served)
                .collect();
            let names: Vec<String> = names.into_iter().map(|n| n + "/").collect();
            return Ok(listing("/jobs/", &names));
        }
        if parts.len() < 3 {
            return Ok(Answer::not_found());
        }
        let Some(x) = self
            .all_jobs(repo)
            .await?
            .into_iter()
            .find(|x| x.served == parts[1])
        else {
            return Ok(Answer::not_found());
        };
        let sub = &parts[2..];
        if sub[sub.len() - 1].is_empty() {
            // a directory listing
            let prefix = if sub.len() > 1 {
                sub[..sub.len() - 1].join("/") + "/"
            } else {
                String::new()
            };
            let rows = self
                .store
                .query(
                    "SELECT path FROM job_files WHERE job_id=?",
                    vec![store::int(x.job_id)],
                )
                .await?;
            let mut names = BTreeSet::new();
            if prefix.is_empty() {
                names.insert("job.json".to_owned());
            }
            for row in &rows {
                if let Some(tail) = get_or_empty(row, "path").strip_prefix(prefix.as_str()) {
                    let (head, slash) = match tail.find('/') {
                        Some(i) => (&tail[..i], "/"),
                        None => (tail, ""),
                    };
                    names.insert(format!("{head}{slash}"));
                }
            }
            if names.is_empty() {
                return Ok(Answer::not_found());
            }
            let mut names: Vec<String> = names.into_iter().collect();
            names.sort_by_key(|n| n.to_lowercase());
            return Ok(listing(&format!("/jobs/{}/{prefix}", parts[1]), &names));
        }
        let path = sub.join("/");
        if path == "job.json" {
            return Ok(Answer::json(&self.job_doc(x.job_id, &x.served).await?));
        }
        let rows = self
            .store
            .query(
                "SELECT content FROM job_files WHERE job_id=? AND path=?",
                vec![store::int(x.job_id), text(&path)],
            )
            .await?;
        Ok(Answer::text(
            rows.first().and_then(|r| store::get(r, "content")),
            content_type(&path),
        ))
    }
}
