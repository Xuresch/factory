use serde_json::{json, Value};

use crate::store::Store;
use crate::util::parse_iso;
use crate::Hub;

async fn fixture() -> Hub {
    let hub = Hub {
        store: Store::open(":memory:").await.unwrap(),
        broker: Default::default(),
        tokens: vec![],
        dashboard: Default::default(),
        static_dir: Default::default(),
        ingest_lock: Default::default(),
    };
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
