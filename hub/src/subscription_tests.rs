use serde_json::{json, Value};

use crate::store::Store;
use crate::util::parse_iso;
use crate::Hub;

async fn test_hub() -> Hub {
    Hub {
        store: Store::open(":memory:").await.unwrap(),
        broker: Default::default(),
        tokens: vec![],
        dashboard: Default::default(),
        static_dir: Default::default(),
        ingest_lock: Default::default(),
    }
}

async fn fixture() -> Hub {
    let hub = test_hub().await;
    let legacy = json!({"name": "Claude Max", "agent": "claude", "usd_per_month": 120});
    assert!(hub
        .ingest(&json!({
            "machine": "m2", "subscriptions": [legacy],
            "outside": {"status": "scanning", "months": {"2026-11": {"claude": 500}}}
        }))
        .await
        .is_ok());
    assert!(hub
        .ingest(&json!({
            "machine": "m1", "subscriptions": [legacy,
                {"name": "Codex", "agent": "codex", "usd_per_month": 80, "since": "2026-12"}],
            "outside": {"status": "ready", "months": {"2026-11": {"claude": 30}}},
            "repos": [{"repo": "o/r", "jobs": [
                {"id": "early", "job": {"started": "2026-10-31T17:30:00-07:00", "cost_usd": 30}},
                {"id": "recent", "job": {"started": "2026-11-08T17:00:00-07:00", "cost_usd": 70}}
            ]}]
        }))
        .await
        .is_ok());
    hub
}

async fn both_views(hub: &Hub, iso: &str) -> Value {
    let now = parse_iso(iso).unwrap();
    let overview = hub.overview_at(now).await.unwrap();
    let document = hub.subscriptions_at(now).await.unwrap();
    let key = document["comparison"]["current_month"].as_str().unwrap();
    let row = &document["comparison"]["months"][key];
    for (field, value) in row.as_object().unwrap() {
        assert_eq!(&overview["month"][field], value, "{key} {field}");
    }
    assert_eq!(
        overview["month"].get("monthly_pace_usd"),
        row.get("monthly_pace_usd")
    );
    row.clone()
}

#[tokio::test]
async fn both_views_agree_on_full_and_elapsed_plan_fees() {
    let hub = fixture().await;
    let november = both_views(&hub, "2026-11-16T00:00:00Z").await;
    assert_eq!(november["plan_fee_full_usd"].as_f64(), Some(120.0));
    assert_eq!(november["plan_fee_elapsed_usd"].as_f64(), Some(60.0));
    let december = both_views(&hub, "2026-12-01T12:00:00Z").await;
    assert_eq!(december["plan_fee_full_usd"].as_f64(), Some(200.0));
    assert_eq!(december["plan_fee_elapsed_usd"].as_f64(), Some(3.2258));
}

#[tokio::test]
async fn both_views_agree_on_monthly_pace_after_three_full_utc_days() {
    let hub = fixture().await;
    let month = both_views(&hub, "2026-11-16T00:00:00Z").await;
    assert_eq!(month["api_equivalent_usd"].as_f64(), Some(130.0));
    assert_eq!(month["monthly_pace_usd"].as_f64(), Some(310.0));
    let before = both_views(&hub, "2026-11-03T23:59:59Z").await;
    assert!(before.get("monthly_pace_usd").is_none());
    let after = both_views(&hub, "2026-11-04T00:00:00Z").await;
    assert!(after.get("monthly_pace_usd").is_some());
}

#[tokio::test]
async fn comparison_accepts_the_ingest_timestamp_formats() {
    let hub = test_hub().await;
    hub.ingest(&json!({
        "machine": "m1",
        "repos": [{"repo": "o/r", "jobs": [
            {"id": "compact-offset", "job": {"started": "2026-11-10T00:30:00+0000", "cost_usd": 50}},
            {"id": "lowercase", "job": {"started": "2026-11-10t00:30:00Z", "cost_usd": 25}}
        ]}]
    }))
    .await
    .ok()
    .expect("valid ingest fixture");
    let month = both_views(&hub, "2026-11-16T00:00:00Z").await;
    assert_eq!(month["api_equivalent_usd"].as_f64(), Some(75.0));
    assert_eq!(month["jobs"], 2);
}

#[tokio::test]
async fn comparison_waits_until_a_job_starts() {
    let hub = fixture().await;
    hub.ingest(&json!({
        "machine": "m1",
        "repos": [{"repo": "o/r", "jobs": [
            {"id": "future", "job": {"started": "2026-11-16T02:00:00Z", "cost_usd": 100}}
        ]}]
    }))
    .await
    .ok()
    .expect("valid ingest fixture");
    let before = both_views(&hub, "2026-11-16T00:00:00Z").await;
    assert_eq!(before["api_equivalent_usd"].as_f64(), Some(130.0));
    assert_eq!(before["monthly_pace_usd"].as_f64(), Some(310.0));
    assert_eq!(before["jobs"], 2);
    let at_start = both_views(&hub, "2026-11-16T02:00:00Z").await;
    assert_eq!(at_start["api_equivalent_usd"].as_f64(), Some(230.0));
    assert_eq!(at_start["jobs"], 3);
}

#[tokio::test]
async fn plans_history_starts_with_usage_or_an_explicit_plan_month() {
    let hub = fixture().await;
    let now = parse_iso("2026-11-16T00:00:00Z").unwrap();
    let plans = hub.subscriptions_at(now).await.unwrap();
    let months = plans["comparison"]["months"].as_object().unwrap();
    assert_eq!(months.keys().collect::<Vec<_>>(), ["2026-11"]);
    assert_eq!(
        hub.overview_at(now).await.unwrap()["month"]["prev"]["month"],
        "2026-10"
    );

    hub.ingest(&json!({
        "machine": "m2",
        "subscriptions": [{"name": "Claude Max", "agent": "claude", "usd_per_month": 120},
            {"name": "September plan", "agent": "codex", "usd_per_month": 40, "since": "2026-09"}]
    }))
    .await
    .ok()
    .expect("valid ingest fixture");
    let plans = hub.subscriptions_at(now).await.unwrap();
    let months = plans["comparison"]["months"].as_object().unwrap();
    assert_eq!(
        months.keys().collect::<Vec<_>>(),
        ["2026-09", "2026-10", "2026-11"]
    );
    assert_eq!(
        months["2026-09"]["plan_fee_elapsed_usd"].as_f64(),
        Some(160.0)
    );
}
