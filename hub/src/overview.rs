//! GET /api/overview: every repo on every machine, the live and waiting jobs,
//! recent stage changes and this month's cost. Counts and sums come from the
//! projected columns (hub/src/project.rs), not from the documents.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::store::{get, get_f64, get_int, get_or_empty, text, Error, Row};
use crate::util::{
    civil_from_days, date_from_days, days_from_civil, float, iso_from_epoch, now_epoch, now_iso,
    quote, round4, SECONDS_PER_DAY,
};
use crate::Hub;

const WEEK: i64 = 7 * SECONDS_PER_DAY;

/// Joins every job to its checkout, repo and machine.
const JOBS: &str = "FROM jobs j JOIN checkouts c ON c.id=j.checkout_id \
     JOIN repos r ON r.id=c.repo_id JOIN machines m ON m.id=c.machine_id";

/// The sums every cost query selects.
const SUMS: &str = "SUM(j.cost_usd) AS usd, SUM(j.cost_claude) AS claude, \
     SUM(j.cost_codex) AS codex, SUM(j.cost_other) AS other, COUNT(*) AS n";

/// `[claude, codex, other]` of a row of SUMS.
fn split(row: &Row) -> [f64; 3] {
    [
        get_f64(row, "claude"),
        get_f64(row, "codex"),
        get_f64(row, "other"),
    ]
}

fn split_json(v: [f64; 3]) -> Value {
    json!({"claude": round4(v[0]), "codex": round4(v[1]), "other": round4(v[2])})
}

fn add3(a: &mut [f64; 3], b: [f64; 3]) {
    for (x, y) in a.iter_mut().zip(b) {
        *x += y;
    }
}

type Daily = Vec<(f64, i64, [f64; 3])>;

fn daily_json(days: &[String], daily: &Daily) -> Vec<Value> {
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

#[derive(Default)]
struct RepoMeta {
    url: Option<String>,
    machines: Vec<String>,
    last_seen: String,
    /// More than one machine has jobs in it: served ids get a machine prefix.
    prefixed: bool,
}

impl Hub {
    #[allow(clippy::too_many_lines)]
    pub async fn overview(&self) -> Result<Value, Error> {
        let now = now_iso();
        let now_secs = now_epoch();
        let month: String = now.chars().take(7).collect();
        let today = now_secs.div_euclid(SECONDS_PER_DAY);
        let days: Vec<String> = (0..14).rev().map(|n| date_from_days(today - n)).collect();
        let (year, mon, day_of_month) = civil_from_days(today);
        let prev = prev_month(year, mon);
        let days_in_month = if mon == 12 {
            days_from_civil(year + 1, 1, 1)
        } else {
            days_from_civil(year, mon + 1, 1)
        } - days_from_civil(year, mon, 1);

        let machines = self
            .store
            .query(
                "SELECT m.name AS machine, m.last_seen AS last_seen, \
                 (SELECT COUNT(*) FROM checkouts c WHERE c.machine_id=m.id AND c.removed_at IS NULL) AS repos \
                 FROM machines m ORDER BY m.name",
                vec![],
            )
            .await?;

        // the repos shown: those with a checkout still reported
        let mut meta: BTreeMap<String, RepoMeta> = BTreeMap::new();
        for row in self
            .store
            .query(
                "SELECT r.slug AS repo, r.url AS url, m.name AS machine, c.last_seen AS last_seen \
                 FROM checkouts c JOIN repos r ON r.id=c.repo_id JOIN machines m ON m.id=c.machine_id \
                 WHERE c.removed_at IS NULL ORDER BY r.slug, m.name",
                vec![],
            )
            .await?
        {
            let m = meta.entry(get_or_empty(&row, "repo").to_owned()).or_default();
            if m.url.is_none() {
                m.url = get(&row, "url").map(str::to_owned);
            }
            m.machines.push(get_or_empty(&row, "machine").to_owned());
            let seen = get_or_empty(&row, "last_seen");
            if seen > m.last_seen.as_str() {
                m.last_seen = seen.to_owned();
            }
        }
        // served ids get a machine prefix when two machines have jobs in the repo
        let with_jobs: Vec<Row> = self
            .store
            .query(
                &format!(
                    "SELECT r.slug AS repo, COUNT(DISTINCT c.machine_id) AS n {JOBS} \
                     WHERE j.removed_at IS NULL AND c.removed_at IS NULL GROUP BY r.slug"
                ),
                vec![],
            )
            .await?;
        for row in &with_jobs {
            if let Some(m) = meta.get_mut(get_or_empty(row, "repo")) {
                m.prefixed = get_int(row, "n").unwrap_or(0) > 1;
            }
        }

        // counts of the jobs shown
        let mut counts: HashMap<String, [i64; 5]> = HashMap::new(); // running, needs_you, merged, rejected, total
        for row in self
            .store
            .query(
                &format!(
                    "SELECT r.slug AS repo, j.stage_group AS g, COUNT(*) AS n {JOBS} \
                     WHERE j.removed_at IS NULL AND c.removed_at IS NULL GROUP BY r.slug, j.stage_group"
                ),
                vec![],
            )
            .await?
        {
            let c = counts.entry(get_or_empty(&row, "repo").to_owned()).or_default();
            let n = get_int(&row, "n").unwrap_or(0);
            match get_or_empty(&row, "g") {
                "live" => c[0] += n,
                "attention" => c[1] += n,
                "merged" => c[2] += n,
                "rejected" => c[3] += n,
                _ => {}
            }
            c[4] += n;
        }

        // costs: every job counts, also those gone from their machine
        let mut totals: HashMap<String, (f64, [f64; 3], Option<String>)> = HashMap::new();
        for row in self
            .store
            .query(
                &format!(
                    "SELECT r.slug AS repo, {SUMS}, MAX(j.last_activity) AS last {JOBS} \
                     WHERE c.removed_at IS NULL GROUP BY r.slug"
                ),
                vec![],
            )
            .await?
        {
            totals.insert(
                get_or_empty(&row, "repo").to_owned(),
                (
                    get_f64(&row, "usd"),
                    split(&row),
                    get(&row, "last").map(str::to_owned),
                ),
            );
        }
        let mut this_month: HashMap<String, (f64, [f64; 3])> = HashMap::new();
        let mut month_factory = [[0.0; 4]; 2]; // [usd, claude, codex, other] this month, last month
        for row in self
            .store
            .query(
                &format!(
                    "SELECT r.slug AS repo, j.started_month AS month, {SUMS} {JOBS} \
                     WHERE j.started_month IN (?, ?) GROUP BY r.slug, j.started_month"
                ),
                vec![text(&month), text(&prev)],
            )
            .await?
        {
            let usd = get_f64(&row, "usd");
            let parts = split(&row);
            let which = usize::from(get_or_empty(&row, "month") != month);
            month_factory[which][0] += usd;
            for (t, p) in month_factory[which][1..].iter_mut().zip(parts) {
                *t += p;
            }
            if which == 0 {
                this_month.insert(get_or_empty(&row, "repo").to_owned(), (usd, parts));
            }
        }
        let mut daily: HashMap<String, Daily> = HashMap::new();
        let mut all_daily: Daily = vec![(0.0, 0, [0.0; 3]); days.len()];
        for row in self
            .store
            .query(
                &format!(
                    "SELECT r.slug AS repo, j.started_day AS day, {SUMS} {JOBS} \
                     WHERE j.started_day >= ? GROUP BY r.slug, j.started_day"
                ),
                vec![text(&days[0])],
            )
            .await?
        {
            let Some(i) = days.iter().position(|d| d == get_or_empty(&row, "day")) else {
                continue;
            };
            let d = daily
                .entry(get_or_empty(&row, "repo").to_owned())
                .or_insert_with(|| vec![(0.0, 0, [0.0; 3]); days.len()]);
            let (usd, n, parts) = (
                get_f64(&row, "usd"),
                get_int(&row, "n").unwrap_or(0),
                split(&row),
            );
            for slot in [&mut d[i], &mut all_daily[i]] {
                slot.0 += usd;
                slot.1 += n;
                add3(&mut slot.2, parts);
            }
        }

        let mut repos = Vec::new();
        for (repo, m) in &meta {
            let c = counts.get(repo).copied().unwrap_or_default();
            let (cost, by_all, last) = totals.get(repo).cloned().unwrap_or_default();
            let (cost_month, by_month) = this_month.get(repo).copied().unwrap_or_default();
            let empty = vec![(0.0, 0, [0.0; 3]); days.len()];
            repos.push(json!({
                "repo": repo, "url": m.url, "machines": m.machines, "last_seen": m.last_seen,
                "href": format!("/r/{}/dashboard.html", quote(repo)),
                "counts": {"running": c[0], "needs_you": c[1], "merged": c[2],
                           "rejected": c[3], "total": c[4]},
                "cost_usd": round4(cost), "cost_month": round4(cost_month),
                "daily": daily_json(&days, daily.get(repo).unwrap_or(&empty)),
                "cost_by_agent": split_json(by_all), "cost_month_by_agent": split_json(by_month),
                "last_activity": last}));
        }

        // Share the same projected summaries as the read API.
        let summaries = self.summaries(None, false).await?;
        let mut live = Vec::new();
        let mut attn = Vec::new();
        let mut done = Vec::new();
        for mut job in summaries {
            let repo = job["repo"].as_str().unwrap_or("").to_owned();
            let machine = job["machine"].as_str().unwrap_or("").to_owned();
            let key = job["key"].as_str().unwrap_or("").to_owned();
            let id = if meta.get(&repo).is_some_and(|m| m.prefixed) {
                format!("{machine}~{key}")
            } else {
                key
            };
            let href = format!("/r/{}/dashboard.html#job={}", quote(&repo), quote(&id));
            job["id"] = json!(id);
            job["href"] = json!(href);
            let group = job["stage_group"].as_str().unwrap_or("").to_owned();
            let entry = json!({"repo":repo,"machine":machine,"id":id,"href":href,"job":job});
            match group.as_str() {
                "live" => live.push(entry),
                "attention" => attn.push(entry),
                "merged" | "rejected" if done.len() < 20 => done.push(entry),
                _ => {}
            }
        }

        let week_ago = iso_from_epoch(now_secs - WEEK);
        let merged_week = self
            .store
            .query(
                &format!(
                    "SELECT COUNT(*) AS n {JOBS} WHERE j.stage='merged' AND j.ended >= ? \
                     AND j.removed_at IS NULL AND c.removed_at IS NULL"
                ),
                vec![text(&week_ago)],
            )
            .await?
            .first()
            .and_then(|r| get_int(r, "n"))
            .unwrap_or(0);

        // outside usage of ready scans, this month and last
        let mut outside = [[0.0; 2]; 2]; // [claude, codex] this month, last month
        let mut outside_total = [0.0; 2];
        let mut by_agent = Map::new();
        for (agent, usd) in [
            ("claude", month_factory[0][1]),
            ("codex", month_factory[0][2]),
        ] {
            if usd != 0.0 {
                by_agent.insert(agent.to_owned(), float(usd));
            }
        }
        for row in self
            .store
            .query(
                "SELECT o.month AS month, o.agent AS agent, SUM(o.cost_usd) AS usd FROM outside_months o \
                 JOIN outside_scans s ON s.machine_id=o.machine_id WHERE s.status='ready' \
                 AND o.month IN (?, ?) GROUP BY o.month, o.agent",
                vec![text(&month), text(&prev)],
            )
            .await?
        {
            let which = usize::from(get_or_empty(&row, "month") != month);
            let agent = get_or_empty(&row, "agent");
            let usd = get_f64(&row, "usd");
            outside_total[which] += usd;
            match agent {
                "claude" => outside[which][0] += usd,
                "codex" => outside[which][1] += usd,
                _ => {}
            }
            if which == 0 {
                let sum = by_agent.get(agent).and_then(Value::as_f64).unwrap_or(0.0) + usd;
                by_agent.insert(agent.to_owned(), float(sum));
            }
        }
        for v in by_agent.values_mut() {
            *v = float(round4(v.as_f64().unwrap_or(0.0)));
        }
        let mut seen = HashSet::new();
        let mut subscriptions_usd = 0.0;
        for row in self
            .store
            .query(
                "SELECT s.name AS name, s.agent AS agent, s.usd_per_month AS usd FROM subscriptions s \
                 JOIN machines m ON m.id=s.machine_id ORDER BY m.name, s.seq",
                vec![],
            )
            .await?
        {
            let key = (get_or_empty(&row, "name").to_owned(), get(&row, "agent").map(str::to_owned));
            if seen.insert(key) {
                subscriptions_usd += get_f64(&row, "usd");
            }
        }

        let events: Vec<Value> = self
            .store
            .query(
                "SELECT s.at AS at, m.name AS machine, r.slug AS repo, j.job_key AS job, \
                     j.title AS title, s.from_stage AS from_stage, s.stage AS to_stage \
                     FROM job_stages s JOIN jobs j ON j.id=s.job_id \
                     JOIN checkouts c ON c.id=j.checkout_id JOIN repos r ON r.id=c.repo_id \
                     JOIN machines m ON m.id=c.machine_id ORDER BY s.at DESC, s.seq DESC LIMIT 100",
                vec![],
            )
            .await?
            .into_iter()
            .map(|e| {
                json!({"at": e["at"], "machine": e["machine"], "repo": e["repo"], "job": e["job"],
                       "title": e["title"], "from": e["from_stage"], "to": e["to_stage"]})
            })
            .collect();

        let total_daily = daily_json(&days, &all_daily);
        let [f_now, f_prev] = month_factory;
        Ok(json!({
            "now": now, "machines": machines, "repos": repos, "live": live, "needs_you": attn,
            "recent": done, "events": events, "merged_week": merged_week, "daily": total_daily,
            "month": {"month": month,
                      "api_equivalent_usd": round4(f_now[0] + outside_total[0]),
                      "subscriptions_usd": float(subscriptions_usd), "by_agent": by_agent,
                      "factory": split_json([f_now[1], f_now[2], f_now[3]]),
                      "outside": json!({"claude": round4(outside[0][0]), "codex": round4(outside[0][1])}),
                      "days_elapsed": day_of_month, "days_in_month": days_in_month,
                      "prev": {"month": prev,
                               "api_equivalent_usd": round4(f_prev[0] + outside_total[1]),
                               "factory": split_json([f_prev[1], f_prev[2], f_prev[3]]),
                               "outside": json!({"claude": round4(outside[1][0]),
                                                 "codex": round4(outside[1][1])})}}}))
    }
}
