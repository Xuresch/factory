//! GET /api/overview: every repo on every machine, the live and waiting jobs,
//! recent stage changes and this month's cost. Counts and sums come from the
//! projected columns (hub/src/project.rs), not from the documents.

use std::collections::{BTreeMap, HashMap};

use serde_json::{json, Value};

use crate::store::{get, get_f64, get_int, get_or_empty, text, Error, Row};
use crate::util::{date_from_days, iso_from_epoch, now_epoch, quote, round4, SECONDS_PER_DAY};
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

#[derive(Default)]
struct RepoMeta {
    url: Option<String>,
    machines: Vec<String>,
    last_seen: String,
    /// More than one machine has jobs in it: served ids get a machine prefix.
    prefixed: bool,
}

impl Hub {
    pub async fn overview(&self) -> Result<Value, Error> {
        self.overview_at(now_epoch()).await
    }

    #[allow(clippy::too_many_lines)]
    pub(crate) async fn overview_at(&self, now_secs: i64) -> Result<Value, Error> {
        let now = iso_from_epoch(now_secs);
        let month = &now[..7];
        let today = now_secs.div_euclid(SECONDS_PER_DAY);
        let days: Vec<String> = (0..14).rev().map(|n| date_from_days(today - n)).collect();

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
        for row in self
            .store
            .query(
                &format!(
                    "SELECT r.slug AS repo, {SUMS} {JOBS} \
                     WHERE j.started_month = ? GROUP BY r.slug"
                ),
                vec![text(month)],
            )
            .await?
        {
            this_month.insert(
                get_or_empty(&row, "repo").to_owned(),
                (get_f64(&row, "usd"), split(&row)),
            );
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
        let summaries = self.summaries(crate::api::SummaryScope::Overview).await?;
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
        let comparison = {
            let _snapshot = self.ingest_lock.lock().await;
            crate::subscriptions::read(&self.store, now_secs).await?
        };
        Ok(json!({
            "now": now, "machines": machines, "repos": repos, "live": live, "needs_you": attn,
            "recent": done, "events": events, "merged_week": merged_week, "daily": total_daily,
            "month": comparison.overview_month(),
        }))
    }
}
