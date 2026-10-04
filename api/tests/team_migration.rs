//! Upgrade fixtures deliberately reproduce the deployed pre-team SQLite schema.
use arrivau_api::{
    app,
    auth::{hash_password, ProductionConfig},
    AppState, Clock,
};
use reqwest::{Client, StatusCode};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    path::Path,
    sync::{Arc, OnceLock},
};
use tempfile::TempDir;

const NOW: i64 = 1_790_874_000;
const TOKEN: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const EXPIRED: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
struct TestClock;
impl Clock for TestClock {
    fn now(&self) -> i64 {
        NOW
    }
}
fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn hash() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    HASH.get_or_init(|| hash_password("migration-only-fixture-password").unwrap())
}
fn config_value() -> Value {
    json!({"fleet_id":"pilot","session_ttl_seconds":300,"accounts":[
        {"id":"dispatch","username":"dispatch","name":"Dispatcher","role":"dispatcher","password_hash":hash()},
        {"id":"driver","username":"driver","name":"Driver","role":"driver","password_hash":hash()}
    ]})
}
fn config(value: Value) -> ProductionConfig {
    serde_json::from_value(value).unwrap()
}
fn add_review(value: &mut Value) {
    value["teams"] =
        json!([{"id":"pilot","name":"Squadra pilota"},{"id":"review","name":"Squadra revisione"}]);
    value["accounts"].as_array_mut().unwrap().push(json!({
        "id":"apple","username":"apple","name":"Apple fixture", "team_id":"review",
        "roles":["driver","dispatcher"],"password_hash":hash()
    }));
}
fn delivery() -> Value {
    json!({"id":"legacy-job","shop_name":"Original shop","pickup_address":"Original pickup",
        "pickup":{"lat":36.716,"lng":15.090},"dropoff_address":"Original dropoff",
        "dropoff":{"lat":36.717,"lng":15.091},"ready_at":NOW-60,"deadline_at":NOW+3600,
        "load_units":1,"max_ride_seconds":1800,"status":"assigned","driver_id":"driver",
        "created_at":NOW-120,"picked_up_at":null,"delivered_at":null})
}
fn create_request() -> Value {
    json!({"shop_name":"Original shop","pickup_address":"Original pickup",
        "pickup":{"lat":36.716,"lng":15.090},"dropoff_address":"Original dropoff",
        "dropoff":{"lat":36.717,"lng":15.091},"ready_at":NOW-60,"deadline_at":NOW+3600,
        "load_units":1,"max_ride_seconds":1800})
}
fn legacy(path: &Path) {
    let db = Connection::open(path).unwrap();
    db.execute_batch("PRAGMA foreign_keys=ON;
        CREATE TABLE drivers(id TEXT PRIMARY KEY,body TEXT NOT NULL CHECK(json_valid(body)));
        CREATE TABLE deliveries(id TEXT PRIMARY KEY,driver_id TEXT REFERENCES drivers(id),status TEXT NOT NULL,body TEXT NOT NULL CHECK(json_valid(body)));
        CREATE TABLE route_stops(driver_id TEXT NOT NULL REFERENCES drivers(id),position INTEGER NOT NULL,delivery_id TEXT NOT NULL REFERENCES deliveries(id),kind TEXT NOT NULL,PRIMARY KEY(driver_id,position),UNIQUE(delivery_id,kind));
        CREATE TABLE deployment(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT INTO deployment VALUES ('mode','production:pilot');
        CREATE TABLE sessions(token_hash TEXT PRIMARY KEY,account_id TEXT NOT NULL,account_fingerprint TEXT NOT NULL,expires_at INTEGER NOT NULL,created_at INTEGER NOT NULL);
        CREATE TABLE login_limits(bucket TEXT PRIMARY KEY,attempts INTEGER NOT NULL,reset_at INTEGER NOT NULL);
        CREATE TABLE idempotency(principal_id TEXT NOT NULL,key TEXT NOT NULL,request_hash TEXT NOT NULL,response TEXT NOT NULL CHECK(json_valid(response)),PRIMARY KEY(principal_id,key));
        PRAGMA user_version=1;").unwrap();
    let driver = json!({"id":"driver","name":"Driver","active":true,"capacity":2,
        "location":{"lat":36.716,"lng":15.09},"location_updated_at":NOW});
    db.execute(
        "INSERT INTO drivers VALUES ('driver',?1)",
        [driver.to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO deliveries VALUES ('legacy-job','driver','assigned',?1)",
        [delivery().to_string()],
    )
    .unwrap();
    db.execute_batch("INSERT INTO route_stops VALUES ('driver',0,'legacy-job','pickup'),('driver',1,'legacy-job','dropoff');
        INSERT INTO login_limits VALUES ('retained-counter',3,1790874999);").unwrap();
    let fingerprint = digest(
        &serde_json::to_string(&("dispatch", "dispatch", "Dispatcher", "dispatcher", hash()))
            .unwrap(),
    );
    for (token, expires) in [(TOKEN, NOW + 200), (EXPIRED, NOW)] {
        db.execute(
            "INSERT INTO sessions VALUES (?1,'dispatch',?2,?3,?4)",
            params![digest(token), fingerprint, expires, NOW - 100],
        )
        .unwrap();
    }
    db.execute("INSERT INTO sessions VALUES ('historical-only','removed-dispatcher','old-fingerprint',?1,?2)", params![NOW+200,NOW-100]).unwrap();
    let request: arrivau_api::model::NewDelivery =
        serde_json::from_value(create_request()).unwrap();
    let request_hash = digest(&format!(
        "/deliveries:{}",
        serde_json::to_string(&request).unwrap()
    ));
    db.execute(
        "INSERT INTO idempotency VALUES ('dispatch','legacy-create-key',?1,?2)",
        params![request_hash, delivery().to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO idempotency VALUES ('retry-only-dispatcher','old-retry-key','old-request',?1)",
        [delivery().to_string()],
    )
    .unwrap();
}
fn snapshot(path: &Path) -> Value {
    let db = Connection::open(path).unwrap();
    let mut tables = serde_json::Map::new();
    for table in [
        "drivers",
        "deliveries",
        "route_stops",
        "sessions",
        "idempotency",
        "login_limits",
        "deployment",
    ] {
        let mut stmt = db
            .prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))
            .unwrap();
        let count = stmt.column_count();
        let rows = stmt
            .query_map([], |r| {
                let mut row = vec![];
                for i in 0..count {
                    row.push(match r.get_ref(i)? {
                        rusqlite::types::ValueRef::Null => Value::Null,
                        rusqlite::types::ValueRef::Integer(n) => json!(n),
                        rusqlite::types::ValueRef::Text(s) => json!(String::from_utf8_lossy(s)),
                        _ => panic!("unexpected SQLite value"),
                    });
                }
                Ok(Value::Array(row))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        tables.insert(table.into(), Value::Array(rows));
    }
    tables.insert(
        "version".into(),
        json!(db
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap()),
    );
    let schema: Vec<String> = db
        .prepare("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    tables.insert("schema".into(), json!(schema));
    Value::Object(tables)
}
async fn serve(state: AppState) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    (
        base,
        tokio::spawn(async move {
            axum::serve(listener, app(state)).await.unwrap();
        }),
    )
}

#[tokio::test]
async fn additive_upgrade_preserves_old_sessions_work_routes_and_retries_across_restarts() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("upgrade.db");
    legacy(&path);
    let mut cfg = config_value();
    add_review(&mut cfg);
    let client = Client::new();
    for _ in 0..2 {
        let state =
            AppState::open_production_with_clock(&path, config(cfg.clone()), Arc::new(TestClock))
                .unwrap();
        let (base, task) = serve(state).await;
        let session = client
            .get(format!("{base}/v1/session"))
            .bearer_auth(TOKEN)
            .send()
            .await
            .unwrap();
        assert_eq!(session.status(), StatusCode::OK);
        let identity: Value = session.json().await.unwrap();
        assert_eq!(identity["user"]["roles"], json!(["dispatcher"]));
        assert_eq!(identity["user"]["team_id"], "pilot");
        for token in [EXPIRED, &"c".repeat(64)] {
            assert_eq!(
                client
                    .get(format!("{base}/v1/me"))
                    .bearer_auth(token)
                    .send()
                    .await
                    .unwrap()
                    .status(),
                StatusCode::UNAUTHORIZED
            );
        }
        let jobs: Value = client
            .get(format!("{base}/v1/deliveries"))
            .bearer_auth(TOKEN)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(
            jobs,
            json!([serde_json::to_value(
                serde_json::from_value::<arrivau_api::model::Delivery>(delivery()).unwrap()
            )
            .unwrap()])
        );
        let route: Value = client
            .get(format!("{base}/v1/drivers/driver/route"))
            .bearer_auth(TOKEN)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(route["stops"].as_array().unwrap().len(), 2);
        assert_eq!(route["stops"][0]["delivery_id"], "legacy-job");
        let replay = client
            .post(format!("{base}/v1/deliveries"))
            .bearer_auth(TOKEN)
            .header("Idempotency-Key", "legacy-create-key")
            .json(&create_request())
            .send()
            .await
            .unwrap();
        assert_eq!(replay.status(), StatusCode::CREATED);
        assert_eq!(
            replay.json::<Value>().await.unwrap(),
            serde_json::to_value(
                serde_json::from_value::<arrivau_api::model::Delivery>(delivery()).unwrap()
            )
            .unwrap()
        );
        let login: Value = client
            .post(format!("{base}/v1/session"))
            .json(&json!({"username":"apple","password":"migration-only-fixture-password"}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let apple = login["token"].as_str().unwrap();
        let jobs: Value = client
            .get(format!("{base}/v1/deliveries"))
            .bearer_auth(apple)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(jobs, json!([]));
        let drivers: Value = client
            .get(format!("{base}/v1/drivers"))
            .bearer_auth(apple)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(drivers.as_array().unwrap().len(), 1);
        assert_eq!(drivers[0]["id"], "apple");
        assert_eq!(
            client
                .get(format!("{base}/v1/deliveries/legacy-job/suggestions"))
                .bearer_auth(apple)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        task.abort();
        let _ = task.await;
    }
    let db = Connection::open(path).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        3
    );
    for table in ["deliveries", "route_stops", "idempotency"] {
        assert_eq!(
            db.query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE team_id<>'pilot'"),
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
    }
    for id in [
        "driver",
        "dispatch",
        "removed-dispatcher",
        "retry-only-dispatcher",
    ] {
        assert_eq!(
            db.query_row(
                "SELECT team_id FROM account_teams WHERE account_id=?1",
                [id],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "pilot"
        );
    }
    assert_eq!(
        db.query_row(
            "SELECT attempts FROM login_limits WHERE bucket='retained-counter'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        3
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM deliveries", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn rejected_team_moves_rollback_the_entire_legacy_upgrade_including_schema() {
    for id in [
        "driver",
        "dispatch",
        "removed-dispatcher",
        "retry-only-dispatcher",
    ] {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("upgrade.db");
        legacy(&path);
        let before = snapshot(&path);
        let mut cfg = config_value();
        add_review(&mut cfg);
        let accounts = cfg["accounts"].as_array_mut().unwrap();
        if let Some(account) = accounts.iter_mut().find(|a| a["id"] == id) {
            account["team_id"] = json!("review");
        } else {
            accounts.push(json!({"id":id,"username":id,"name":"Reused ID","role":"dispatcher","team_id":"review","password_hash":hash()}));
        }
        let result = AppState::open_production_with_clock(&path, config(cfg), Arc::new(TestClock));
        assert!(result.is_err(), "{id} was allowed to move");
        assert_eq!(
            snapshot(&path),
            before,
            "rejected migration modified {id}'s database"
        );
    }
}

#[test]
fn unsupported_schema_and_invalid_config_leave_database_untouched() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("future.db");
    legacy(&path);
    let db = Connection::open(&path).unwrap();
    db.execute_batch("PRAGMA user_version=999;").unwrap();
    drop(db);
    let before = snapshot(&path);
    assert!(AppState::open_production_with_clock(
        &path,
        config(config_value()),
        Arc::new(TestClock)
    )
    .is_err());
    assert_eq!(snapshot(&path), before);
    let mut cfg = config_value();
    cfg["accounts"][0]["roles"] = json!(["root"]);
    assert!(AppState::open_production_with_clock(&path, config(cfg), Arc::new(TestClock)).is_err());
    assert_eq!(snapshot(&path), before);
}

#[test]
fn configuration_rejects_ambiguous_capabilities_and_teams() {
    assert!(config(config_value()).validate().is_ok());
    let mut dual = config_value();
    add_review(&mut dual);
    assert!(config(dual.clone()).validate().is_ok());
    let mut bad_cases = vec![];
    for roles in [
        json!([]),
        json!(["driver", "driver"]),
        json!(["dispatcher", "admin"]),
        json!(["driver"]),
    ] {
        let mut bad = dual.clone();
        bad["accounts"][0]["roles"] = roles;
        bad_cases.push(bad);
    }
    let mut bad = dual.clone();
    bad["accounts"][0]["team_id"] = json!("unknown");
    bad_cases.push(bad);
    let mut bad = dual.clone();
    bad["teams"] = json!([{"id":"review","name":"Review"}]);
    bad_cases.push(bad);
    let mut bad = dual.clone();
    bad["teams"][1]["id"] = json!("pilot");
    bad_cases.push(bad);
    let mut bad = dual.clone();
    bad["teams"][1]["name"] = json!("  ");
    bad_cases.push(bad);
    let mut bad = dual.clone();
    bad["accounts"][2]["role"] = json!("admin");
    bad_cases.push(bad);
    for bad in bad_cases {
        assert!(config(bad).validate().is_err());
    }
}

#[test]
fn database_constraints_reject_cross_team_links_and_team_relabelling() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("upgrade.db");
    legacy(&path);
    let mut cfg = config_value();
    add_review(&mut cfg);
    drop(AppState::open_production_with_clock(&path, config(cfg), Arc::new(TestClock)).unwrap());
    let db = Connection::open(&path).unwrap();
    for sql in [
        "UPDATE deliveries SET driver_id='apple' WHERE id='legacy-job'",
        "UPDATE drivers SET team_id='review' WHERE id='driver'",
        "UPDATE deliveries SET team_id='review' WHERE id='legacy-job'",
        "UPDATE route_stops SET driver_id='apple' WHERE driver_id='driver'",
        "UPDATE route_stops SET team_id='review' WHERE driver_id='driver'",
        "UPDATE sessions SET team_id='review' WHERE account_id='dispatch'",
        "UPDATE idempotency SET team_id='review' WHERE principal_id='dispatch'",
        "UPDATE account_teams SET team_id='review' WHERE account_id='dispatch'",
        "INSERT INTO route_stops(driver_id,position,delivery_id,kind,team_id) VALUES ('apple',0,'legacy-job','pickup','review')",
    ] { assert!(db.execute_batch(sql).is_err(),"unexpectedly allowed {sql}"); }
    assert_eq!(
        db.query_row(
            "SELECT body FROM deliveries WHERE id='legacy-job'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        delivery().to_string()
    );
}
