//! GET /api/overview: every repo on every machine, the live and waiting jobs,
//! recent events and this month's cost.

use std::collections::{BTreeMap, HashMap};

use serde_json::{json, Map, Value};

use crate::store::{get, get_or_empty, Error};
use crate::tree::{repo_served_ids, JobRow};
use crate::util::{
    date_from_days, float, now_epoch, now_iso, number, parse_iso, quote, round4, Num,
    SECONDS_PER_DAY,
};
use crate::Hub;

const LIVE: [&str; 7] = [
    "intake", "spec", "build", "gate", "review", "approve", "merging",
];
const ATTN: [&str; 3] = ["needs-human", "paused", "needs-info"];
const WEEK: i64 = 7 * SECONDS_PER_DAY;

/// When a job last did something: ended, else its newest history entry, else started.
fn job_activity(job: &Value) -> &str {
    fn text(v: Option<&Value>) -> Option<&str> {
        v.and_then(Value::as_str).filter(|s| !s.is_empty())
    }
    let newest_history = job
        .get("history")
        .and_then(Value::as_array)
        .and_then(|h| h.last())
        .and_then(|e| e.get("at"));
    text(job.get("ended"))
        .or_else(|| text(newest_history))
        .or_else(|| text(job.get("started")))
        .unwrap_or("")
}

fn prefix(s: &str, chars: usize) -> String {
    s.chars().take(chars).collect()
}

#[derive(Default)]
struct Meta {
    url: Option<String>,
    machines: Vec<String>,
    last_seen: String,
}

impl Hub {
    pub async fn overview(&self) -> Result<Value, Error> {
        let now = now_iso();
        let now_secs = now_epoch();
        let month = prefix(&now, 7);
        let today = now_secs.div_euclid(SECONDS_PER_DAY);
        let days: Vec<String> = (0..14).rev().map(|n| date_from_days(today - n)).collect();

        let machines = self
            .store
            .query(
                "SELECT m.machine AS machine, m.last_seen AS last_seen, \
                 (SELECT COUNT(*) FROM repos r WHERE r.machine=m.machine) AS repos \
                 FROM machines m ORDER BY m.machine",
                vec![],
            )
            .await?;
        let mut meta: BTreeMap<String, Meta> = BTreeMap::new();
        let rows = self
            .store
            .query("SELECT repo, machine, url, last_seen FROM repos", vec![])
            .await?;
        for row in &rows {
            let m = meta
                .entry(get_or_empty(row, "repo").to_owned())
                .or_default();
            if m.url.as_deref().is_none_or(str::is_empty) {
                m.url = get(row, "url").map(str::to_owned);
            }
            m.machines.push(get_or_empty(row, "machine").to_owned());
            let seen = get_or_empty(row, "last_seen");
            if seen > m.last_seen.as_str() {
                m.last_seen = seen.to_owned();
            }
        }

        let mut by_repo: HashMap<String, Vec<JobRow>> = HashMap::new();
        for x in self.all_jobs(None).await? {
            by_repo.entry(x.repo.clone()).or_default().push(x);
        }
        let (mut month_usd, mut by_agent) = (0.0, Map::new());
        let mut merged_week = 0;
        let (mut repos, mut live, mut attn, mut done) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for (repo, m) in &mut meta {
            let jobs = by_repo.remove(repo).unwrap_or_default();
            let keys: Vec<_> = jobs
                .iter()
                .map(|x| (x.machine.as_str(), x.id.as_str()))
                .collect();
            let served = repo_served_ids(&keys);
            let mut counts = [0; 4]; // running, needs_you, merged, rejected
            let (mut cost, mut cost_month) = (0.0, 0.0);
            let mut daily: Vec<(f64, i64)> = vec![(0.0, 0); days.len()];
            let mut last = "";
            for (x, sid) in jobs.iter().zip(&served) {
                let stage = x.job.get("stage").and_then(Value::as_str).unwrap_or("");
                let mut job = x.job.clone();
                if *sid != x.id {
                    if let Some(o) = job.as_object_mut() {
                        o.insert("id".to_owned(), Value::String(sid.clone()));
                    }
                }
                let entry = json!({"repo": repo, "machine": x.machine, "id": sid,
                    "href": format!("/r/{}/dashboard.html#job={}", quote(repo), quote(sid)),
                    "job": job});
                if LIVE.contains(&stage) {
                    counts[0] += 1;
                    live.push(entry);
                } else if ATTN.contains(&stage) {
                    counts[1] += 1;
                    attn.push(entry);
                } else if stage == "merged" || stage == "rejected" {
                    counts[if stage == "merged" { 2 } else { 3 }] += 1;
                    if stage == "merged" {
                        let ended = x
                            .job
                            .get("ended")
                            .and_then(Value::as_str)
                            .and_then(parse_iso);
                        merged_week += i32::from(ended.is_some_and(|t| t >= now_secs - WEEK));
                    }
                    done.push(entry);
                }
                let usd = number(x.job.get("cost_usd"));
                cost += usd;
                let started = x.job.get("started").and_then(Value::as_str).unwrap_or("");
                if let Some(i) = days.iter().position(|d| *d == prefix(started, 10)) {
                    daily[i].0 += usd;
                    daily[i].1 += 1;
                }
                if prefix(started, 7) == month {
                    cost_month += usd;
                    month_usd += usd;
                    let agents = x.job.get("cost_by_agent").and_then(Value::as_object);
                    for (agent, v) in agents.into_iter().flatten() {
                        let sum = number(by_agent.get(agent)) + number(Some(v));
                        by_agent.insert(agent.clone(), float(sum));
                    }
                }
                last = last.max(job_activity(&x.job));
            }
            let daily: Vec<Value> = days
                .iter()
                .zip(&daily)
                .map(|(d, (usd, n))| json!({"day": d, "cost_usd": round4(*usd), "jobs": n}))
                .collect();
            m.machines.sort();
            repos.push(json!({
                "repo": repo, "url": m.url, "machines": m.machines, "last_seen": m.last_seen,
                "href": format!("/r/{}/dashboard.html", quote(repo)),
                "counts": {"running": counts[0], "needs_you": counts[1], "merged": counts[2],
                           "rejected": counts[3], "total": jobs.len()},
                "cost_usd": round4(cost), "cost_month": round4(cost_month), "daily": daily,
                "last_activity": (!last.is_empty()).then_some(last)}));
        }
        for list in [&mut live, &mut attn, &mut done] {
            list.sort_by(|a: &Value, b: &Value| {
                job_activity(&b["job"]).cmp(job_activity(&a["job"]))
            });
        }

        let subs = self.subscriptions().await?;
        if let Some(outside) = subs.get("outside").filter(|o| o["status"] == "ready") {
            let this_month = outside.get("months").and_then(|m| m.get(&month));
            for (agent, v) in this_month.and_then(Value::as_object).into_iter().flatten() {
                month_usd += number(Some(v));
                let sum = number(by_agent.get(agent)) + number(Some(v));
                by_agent.insert(agent.clone(), float(sum));
            }
        }
        let subscriptions_usd = subs
            .get("subscriptions")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .fold(Num::Int(0), |sum, s| {
                sum.add(Num::of(s.get("usd_per_month")))
            });

        let events: Vec<Value> = self
            .store
            .query(
                "SELECT at, machine, repo, job, title, from_stage, to_stage FROM events \
                 ORDER BY id DESC LIMIT 100",
                vec![],
            )
            .await?
            .into_iter()
            .map(|e| {
                json!({"at": e["at"], "machine": e["machine"], "repo": e["repo"], "job": e["job"],
                       "title": e["title"], "from": e["from_stage"], "to": e["to_stage"]})
            })
            .collect();
        for v in by_agent.values_mut() {
            *v = float(round4(number(Some(v))));
        }
        done.truncate(20);
        Ok(json!({
            "now": now, "machines": machines, "repos": repos, "live": live, "needs_you": attn,
            "recent": done, "events": events, "merged_week": merged_week,
            "month": {"month": month, "api_equivalent_usd": round4(month_usd),
                      "subscriptions_usd": subscriptions_usd.to_value(), "by_agent": by_agent}}))
    }
}
