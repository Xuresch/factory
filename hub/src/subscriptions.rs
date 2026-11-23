//! Monthly comparison shared by the hub overview and Plans.

use std::collections::{BTreeMap, HashSet};

use serde_json::{json, Value};

use crate::store::{get, get_f64, get_int, get_or_empty, int, Error, Store};
use crate::util::{
    civil_from_days, date_from_days, days_from_civil, iso_from_epoch, round4, SECONDS_PER_DAY,
};

const WEEK: i64 = 7 * SECONDS_PER_DAY;

type Split = [f64; 3];

fn split_json([claude, codex, other]: Split) -> Value {
    json!({"claude": round4(claude), "codex": round4(codex), "other": round4(other)})
}

fn agent_index(agent: Option<&str>) -> usize {
    match agent {
        Some("claude") => 0,
        Some("codex") => 1,
        _ => 2,
    }
}

pub fn month_start(key: &str) -> Option<i64> {
    let (year, month) = key.split_once('-')?;
    if year.len() != 4 || month.len() != 2 || !key.bytes().all(|b| b.is_ascii_digit() || b == b'-')
    {
        return None;
    }
    let month = month.parse().ok().filter(|m| (1..=12).contains(m))?;
    Some(days_from_civil(year.parse().ok()?, month, 1) * SECONDS_PER_DAY)
}

fn month_key(epoch: i64) -> String {
    date_from_days(epoch.div_euclid(SECONDS_PER_DAY))[..7].to_owned()
}

fn next_month(start: i64) -> i64 {
    let (year, month, _) = civil_from_days(start.div_euclid(SECONDS_PER_DAY));
    let (year, month) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    days_from_civil(year, month, 1) * SECONDS_PER_DAY
}

#[derive(Default)]
struct FactoryMonth {
    usd: f64,
    split: Split,
    jobs: i64,
    recent_usd: f64,
}

pub struct Comparison {
    pub plans: Vec<Value>,
    pub outside_months: BTreeMap<String, Value>,
    months: BTreeMap<String, Value>,
    now: i64,
    current: i64,
}

impl Comparison {
    pub fn overview_month(&self) -> Value {
        let mut current = self.months[&month_key(self.current)].clone();
        current["subscriptions_usd"] = current["plan_fee_full_usd"].clone();
        current["days_elapsed"] = json!((self.now - self.current) / SECONDS_PER_DAY + 1);
        current["days_in_month"] =
            json!((next_month(self.current) - self.current) / SECONDS_PER_DAY);
        current["prev"] = self.months[&month_key(self.current - SECONDS_PER_DAY)].clone();
        current
    }

    pub fn plans_comparison(&self) -> Value {
        json!({"now": iso_from_epoch(self.now), "current_month": month_key(self.current), "months": self.months})
    }
}

async fn plans(store: &Store) -> Result<Vec<Value>, Error> {
    let mut seen = HashSet::new();
    let mut plans = Vec::new();
    for row in store
        .query(
            "SELECT s.name AS name, s.agent AS agent, s.usd_per_month AS usd, s.since AS since \
             FROM subscriptions s JOIN machines m ON m.id=s.machine_id ORDER BY m.name, s.seq",
            vec![],
        )
        .await?
    {
        if seen.insert((
            get_or_empty(&row, "name").to_owned(),
            get(&row, "agent").map(str::to_owned),
        )) {
            let mut plan = json!({"name": row["name"], "agent": row["agent"], "usd_per_month": get_f64(&row, "usd")});
            if let Some(since) = get(&row, "since") {
                plan["since"] = json!(since);
            }
            plans.push(plan);
        }
    }
    Ok(plans)
}

/// Read the projected job costs and ready Outside usage from one ingest snapshot.
/// The caller holds the ingest lock while reading the comparison and its related data.
pub async fn read(store: &Store, now: i64) -> Result<Comparison, Error> {
    let current = month_start(&month_key(now)).expect("UTC month");
    let previous = month_start(&month_key(current - SECONDS_PER_DAY)).expect("UTC month");
    let recent = (now - WEEK).max(current);
    let mut factory = BTreeMap::new();
    for row in store
        .query(
            "SELECT strftime('%Y-%m', started) AS month, COUNT(*) AS jobs, SUM(cost_usd) AS usd, \
             SUM(cost_claude) AS claude, SUM(cost_codex) AS codex, SUM(cost_other) AS other, \
             SUM(CASE WHEN unixepoch(started) BETWEEN ? AND ? THEN cost_usd ELSE 0 END) AS recent_usd \
             FROM jobs WHERE started IS NOT NULL GROUP BY 1",
            vec![int(recent), int(now)],
        )
        .await?
    {
        if let Some(start) = get(&row, "month").and_then(month_start).filter(|&start| start <= current) {
            factory.insert(start, FactoryMonth {
                usd: get_f64(&row, "usd"),
                split: [get_f64(&row, "claude"), get_f64(&row, "codex"), get_f64(&row, "other")],
                jobs: get_int(&row, "jobs").unwrap_or(0),
                recent_usd: get_f64(&row, "recent_usd"),
            });
        }
    }
    let mut outside = BTreeMap::<i64, Split>::new();
    let mut outside_months = BTreeMap::<String, Value>::new();
    for row in store
        .query(
            "SELECT o.month AS month, o.agent AS agent, SUM(o.cost_usd) AS usd FROM outside_months o \
             JOIN outside_scans s ON s.machine_id=o.machine_id WHERE s.status='ready' GROUP BY o.month, o.agent",
            vec![],
        )
        .await?
    {
        let key = get_or_empty(&row, "month");
        let agent = get_or_empty(&row, "agent");
        let usd = get_f64(&row, "usd");
        if let Some(start) = month_start(key) {
            outside.entry(start).or_default()[agent_index(Some(agent))] += usd;
        }
        outside_months.entry(key.to_owned()).or_insert_with(|| json!({"claude": 0.0, "codex": 0.0}))[agent] = json!(usd);
    }

    let plans = plans(store).await?;
    let first = factory
        .keys()
        .chain(outside.keys())
        .copied()
        .fold(previous, i64::min);
    let mut months = BTreeMap::new();
    let mut start = first;
    while start <= current {
        let end = next_month(start);
        let elapsed = now.min(end) - start;
        let share = elapsed as f64 / (end - start) as f64;
        let key = month_key(start);
        let job = factory.remove(&start).unwrap_or_default();
        let out = outside.remove(&start).unwrap_or_default();
        let outside_usd = out.iter().sum::<f64>();
        let api = job.usd + outside_usd;
        let mut fee = [0.0; 3];
        for plan in &plans {
            if plan["since"]
                .as_str()
                .is_none_or(|since| since <= key.as_str())
            {
                fee[agent_index(plan["agent"].as_str())] +=
                    plan["usd_per_month"].as_f64().unwrap_or(0.0);
            }
        }
        let full_fee = fee.iter().sum::<f64>();
        let mut row = json!({
            "month": key, "jobs": job.jobs, "elapsed_share": share,
            "api_equivalent_usd": round4(api), "factory_usd": round4(job.usd), "outside_usd": round4(outside_usd),
            "factory": split_json(job.split), "outside": split_json(out),
            "by_agent": split_json(std::array::from_fn(|i| job.split[i] + out[i])),
            "plan_fee_full_usd": round4(full_fee), "plan_fee_elapsed_usd": round4(full_fee * share),
            "plan_fee_elapsed_by_agent": split_json(fee.map(|fee| fee * share)),
        });
        if start == current && elapsed >= 3 * SECONDS_PER_DAY {
            let remaining = (end - now) as f64;
            let factory_rate = job.recent_usd / (now - recent) as f64;
            let outside_rate = outside_usd / elapsed as f64;
            row["monthly_pace_usd"] =
                json!(round4(api + remaining * (factory_rate + outside_rate)));
        }
        months.insert(key, row);
        start = end;
    }
    Ok(Comparison {
        plans,
        outside_months,
        months,
        now,
        current,
    })
}
