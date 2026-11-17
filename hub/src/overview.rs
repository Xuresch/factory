//! GET /api/overview: every repo on every machine, the live and waiting jobs,
//! recent events and this month's cost.

use std::collections::{BTreeMap, HashMap};

use serde_json::{json, Map, Value};

use crate::store::{get, get_or_empty, Error};
use crate::tree::{repo_served_ids, JobRow};
use crate::util::{
    civil_from_days, date_from_days, days_from_civil, float, now_epoch, now_iso, number, parse_iso,
    quote, round4, Num, SECONDS_PER_DAY,
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

/// `[claude, codex, other]` of a job: `other` is what `cost_by_agent` leaves of
/// `cost_usd` (all of it when the job has no split), noise under half a cent is 0.
fn split(job: &Value, usd: f64) -> [f64; 3] {
    let agents = job.get("cost_by_agent");
    let claude = number(agents.and_then(|a| a.get("claude")));
    let codex = number(agents.and_then(|a| a.get("codex")));
    let rest = usd - claude - codex;
    [claude, codex, if rest > 0.005 { rest } else { 0.0 }]
}

fn add3(a: &mut [f64; 3], b: [f64; 3]) {
    for (x, y) in a.iter_mut().zip(b) {
        *x += y;
    }
}

fn split_json(v: [f64; 3]) -> Value {
    json!({"claude": round4(v[0]), "codex": round4(v[1]), "other": round4(v[2])})
}

fn daily_json(days: &[String], daily: &[(f64, i64, [f64; 3])]) -> Vec<Value> {
    days.iter()
        .zip(daily)
        .map(|(d, (usd, n, by))| {
            json!({"day": d, "cost_usd": round4(*usd), "jobs": n, "by_agent": split_json(*by)})
        })
        .collect()
}

/// `YYYY-MM` of the month before `year-month`.
fn prev_month(year: i64, month: i64) -> String {
    if month == 1 {
        format!("{:04}-12", year - 1)
    } else {
        format!("{year:04}-{:02}", month - 1)
    }
}

/// A month's outside usage `[claude, codex]` and the sum over every agent in it.
fn outside_month(outside: Option<&Value>, month: &str) -> ([f64; 2], f64) {
    let row = outside
        .and_then(|o| o.get("months"))
        .and_then(|m| m.get(month));
    let mut pair = [0.0; 2];
    let mut total = 0.0;
    for (agent, v) in row.and_then(Value::as_object).into_iter().flatten() {
        total += number(Some(v));
        match agent.as_str() {
            "claude" => pair[0] += number(Some(v)),
            "codex" => pair[1] += number(Some(v)),
            _ => {}
        }
    }
    (pair, total)
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
        let (year, mon, day_of_month) = civil_from_days(today);
        let prev = prev_month(year, mon);
        let days_in_month = if mon == 12 {
            days_from_civil(year + 1, 1, 1)
        } else {
            days_from_civil(year, mon + 1, 1)
        } - days_from_civil(year, mon, 1);
        // [usd, claude, codex, other] of factory jobs started in the month
        let mut month_factory = [0.0; 4];
        let mut prev_factory = [0.0; 4];
        let mut all_daily: Vec<(f64, i64, [f64; 3])> = vec![(0.0, 0, [0.0; 3]); days.len()];

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
            let (mut by_all, mut by_month) = ([0.0; 3], [0.0; 3]);
            let mut daily: Vec<(f64, i64, [f64; 3])> = vec![(0.0, 0, [0.0; 3]); days.len()];
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
                let parts = split(&x.job, usd);
                add3(&mut by_all, parts);
                let started = x.job.get("started").and_then(Value::as_str).unwrap_or("");
                if let Some(i) = days.iter().position(|d| *d == prefix(started, 10)) {
                    daily[i].0 += usd;
                    daily[i].1 += 1;
                    add3(&mut daily[i].2, parts);
                    all_daily[i].0 += usd;
                    all_daily[i].1 += 1;
                    add3(&mut all_daily[i].2, parts);
                }
                if prefix(started, 7) == month {
                    cost_month += usd;
                    month_usd += usd;
                    add3(&mut by_month, parts);
                    month_factory[0] += usd;
                    for (t, p) in month_factory[1..].iter_mut().zip(parts) {
                        *t += p;
                    }
                    let agents = x.job.get("cost_by_agent").and_then(Value::as_object);
                    for (agent, v) in agents.into_iter().flatten() {
                        let sum = number(by_agent.get(agent)) + number(Some(v));
                        by_agent.insert(agent.clone(), float(sum));
                    }
                }
                if prefix(started, 7) == prev {
                    prev_factory[0] += usd;
                    for (t, p) in prev_factory[1..].iter_mut().zip(parts) {
                        *t += p;
                    }
                }
                last = last.max(job_activity(&x.job));
            }
            let daily = daily_json(&days, &daily);
            m.machines.sort();
            repos.push(json!({
                "repo": repo, "url": m.url, "machines": m.machines, "last_seen": m.last_seen,
                "href": format!("/r/{}/dashboard.html", quote(repo)),
                "counts": {"running": counts[0], "needs_you": counts[1], "merged": counts[2],
                           "rejected": counts[3], "total": jobs.len()},
                "cost_usd": round4(cost), "cost_month": round4(cost_month), "daily": daily,
                "cost_by_agent": split_json(by_all), "cost_month_by_agent": split_json(by_month),
                "last_activity": (!last.is_empty()).then_some(last)}));
        }
        for list in [&mut live, &mut attn, &mut done] {
            list.sort_by(|a: &Value, b: &Value| {
                job_activity(&b["job"]).cmp(job_activity(&a["job"]))
            });
        }

        let subs = self.subscriptions().await?;
        let outside_ready = subs.get("outside").filter(|o| o["status"] == "ready");
        let (outside_now, _) = outside_month(outside_ready, &month);
        let (outside_prev, outside_prev_usd) = outside_month(outside_ready, &prev);
        if let Some(outside) = outside_ready {
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
                        "daily": daily_json(&days, &all_daily),
            "month": {"month": month, "api_equivalent_usd": round4(month_usd),
                      "subscriptions_usd": subscriptions_usd.to_value(), "by_agent": by_agent,
                      "factory": split_json([month_factory[1], month_factory[2], month_factory[3]]),
                      "outside": json!({"claude": round4(outside_now[0]), "codex": round4(outside_now[1])}),
                      "days_elapsed": day_of_month, "days_in_month": days_in_month,
                      "prev": {"month": prev,
                               "api_equivalent_usd": round4(prev_factory[0] + outside_prev_usd),
                               "factory": split_json([prev_factory[1], prev_factory[2], prev_factory[3]]),
                               "outside": json!({"claude": round4(outside_prev[0]),
                                                 "codex": round4(outside_prev[1])})}}}))
    }
}
