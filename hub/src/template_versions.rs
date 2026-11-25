//! Outcomes of finished jobs grouped by the template commit recorded at creation.
use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::{store, util::parse_iso, Hub};

#[derive(Default)]
struct Group<'a> {
    date: Option<&'a str>,
    commit_url: Option<String>,
    rounds: Vec<f64>,
    waits: Vec<f64>,
    costs: Vec<f64>,
    reached_human: usize,
    gate_failed: usize,
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_unstable_by(f64::total_cmp);
    let mid = values.len() / 2;
    f64::midpoint(values[(values.len() - 1) / 2], values[mid])
}

fn commit_url(source: &str, commit: &str) -> Option<String> {
    if !matches!(commit.len(), 40 | 64) || !commit.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let path = [
        "https://github.com/",
        "http://github.com/",
        "git://github.com/",
        "ssh://git@github.com/",
        "git@github.com:",
    ]
    .iter()
    .find_map(|prefix| source.strip_prefix(prefix))?;
    let path = path.split('@').next()?.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, repo) = path.split_once('/')?;
    let slug_part = |s: &str| {
        !matches!(s, "" | "." | "..")
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
    };
    (slug_part(owner) && slug_part(repo))
        .then(|| format!("https://github.com/{path}/commit/{commit}"))
}

impl Hub {
    pub async fn template_versions(
        &self,
        repo: Option<&str>,
    ) -> Result<Option<Value>, store::Error> {
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
        let rows = self
            .store
            .query(
                "SELECT j.template_commit, j.template_date, j.template_source, j.wait_s, j.cost_usd, \
                 COALESCE(j.round, (SELECT MAX(round) FROM job_rounds WHERE job_id=j.id), 0) AS rounds, \
                 EXISTS(SELECT 1 FROM job_stages WHERE job_id=j.id AND stage IN ('needs-human', 'paused')) AS reached_human, \
                 (COALESCE(j.gate='FAIL', 0) OR EXISTS(SELECT 1 FROM job_rounds WHERE job_id=j.id AND gate_verdict='FAIL')) AS gate_failed \
                 FROM jobs j JOIN checkouts c ON c.id=j.checkout_id JOIN repos r ON r.id=c.repo_id \
                 WHERE j.stage IN ('merged', 'rejected') AND (? IS NULL OR r.slug=?) ORDER BY j.id",
                vec![store::opt(repo), store::opt(repo)],
            )
            .await?;
        let mut groups = BTreeMap::<Option<&str>, Group<'_>>::new();
        for row in &rows {
            let commit = store::get(row, "template_commit").filter(|s| !s.is_empty());
            let group = groups.entry(commit).or_default();
            if let Some(commit) = commit {
                group.date = group.date.or_else(|| store::get(row, "template_date"));
                if group.commit_url.is_none() {
                    group.commit_url = store::get(row, "template_source")
                        .and_then(|source| commit_url(source, commit));
                }
            }
            group.rounds.push(store::get_f64(row, "rounds"));
            group.waits.push(store::get_f64(row, "wait_s"));
            group.costs.push(store::get_f64(row, "cost_usd"));
            group.reached_human += usize::from(store::get_int(row, "reached_human") == Some(1));
            group.gate_failed += usize::from(store::get_int(row, "gate_failed") == Some(1));
        }

        let mut versions: Vec<_> = groups.into_iter().collect();
        versions.sort_by_key(|(commit, group)| {
            std::cmp::Reverse((commit.is_some(), group.date.and_then(parse_iso)))
        });
        let versions: Vec<_> = versions
            .into_iter()
            .map(|(commit, mut group)| {
                let jobs = group.rounds.len();
                json!({
                    "template_commit": commit,
                    "template_date": group.date,
                    "commit_url": group.commit_url,
                    "jobs": jobs,
                    "median_rounds": median(&mut group.rounds),
                    "human_wait_share": group.reached_human as f64 / jobs as f64,
                    "median_wait_minutes": median(&mut group.waits) / 60.0,
                    "gate_failure_share": group.gate_failed as f64 / jobs as f64,
                    "median_cost_usd": median(&mut group.costs),
                    "too_few_to_compare": jobs < 5,
                })
            })
            .collect();
        Ok(Some(json!({"repo": repo, "versions": versions})))
    }
}
