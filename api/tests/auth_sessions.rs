//! All credentials here are ephemeral test fixtures, not provisioned accounts.
use arrivau_api::{
    app,
    auth::{hash_password, Account, ProductionConfig},
    AppState, Clock,
};
use reqwest::{Client, StatusCode};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc, OnceLock,
    },
};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};

const NOW: i64 = 1_790_874_000;
const PASSWORD: &str = "fixture-only-password-for-tests";
struct TestClock(AtomicI64);
impl Clock for TestClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}
fn config() -> ProductionConfig {
    static HASH: OnceLock<String> = OnceLock::new();
    let hash = HASH.get_or_init(|| hash_password(PASSWORD).unwrap());
    ProductionConfig {
        fleet_id: "test-fleet".into(),
        teams: vec![],
        session_ttl_seconds: 300,
        accounts: vec![
            Account {
                id: "dispatcher-alice".into(),
                username: "alice".into(),
                name: "Alice fixture".into(),
                role: "dispatcher".into(),
                roles: None,
                team_id: None,
                password_hash: hash.clone(),
            },
            Account {
                id: "driver-bob".into(),
                username: "bob".into(),
                name: "Bob fixture".into(),
                role: "driver".into(),
                roles: None,
                team_id: None,
                password_hash: hash.clone(),
            },
            Account {
                id: "driver-carol".into(),
                username: "carol".into(),
                name: "Carol fixture".into(),
                role: "driver".into(),
                roles: None,
                team_id: None,
                password_hash: hash.clone(),
            },
        ],
    }
}
struct Server {
    base: String,
    client: Client,
    task: JoinHandle<()>,
}
impl Server {
    async fn start(path: &Path, clock: Arc<TestClock>, config: ProductionConfig) -> Self {
        let state = AppState::open_production_with_clock(path, config, clock).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app(state)).await.unwrap();
        });
        Self {
            base,
            client: Client::new(),
            task,
        }
    }
    async fn login(&self, username: &str, password: &str) -> reqwest::Response {
        self.client
            .post(format!("{}/v1/session", self.base))
            .json(&json!({"username":username,"password":password}))
            .send()
            .await
            .unwrap()
    }
    async fn token(&self, username: &str) -> String {
        let response = self.login(username, PASSWORD).await;
        assert_eq!(response.status(), StatusCode::CREATED);
        assert_eq!(response.headers()["cache-control"], "no-store");
        let value: Value = response.json().await.unwrap();
        assert_eq!(value["expires_at"], NOW + 300);
        assert_eq!(
            value["user"]["role"],
            if username == "alice" {
                "dispatcher"
            } else {
                "driver"
            }
        );
        value["token"].as_str().unwrap().to_string()
    }
    async fn get(&self, path: &str, token: &str) -> reqwest::Response {
        self.client
            .get(format!("{}{}", self.base, path))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
    }
    async fn close(&mut self) {
        self.task.abort();
        let _ = (&mut self.task).await;
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
fn clock() -> Arc<TestClock> {
    Arc::new(TestClock(AtomicI64::new(NOW)))
}

#[tokio::test]
async fn production_identity_roles_and_no_fixture_tokens_or_seed_drivers() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("pilot.db"), clock(), config()).await;
    for token in [
        "demo-dispatcher",
        "demo-driver-1",
        "demo-driver-2",
        "demo-dual",
        "",
        &"0".repeat(64),
    ] {
        assert_eq!(
            server.get("/v1/me", token).await.status(),
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        server.login("unknown", PASSWORD).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.login("alice", "wrong").await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server
            .client
            .post(format!("{}/v1/session", server.base))
            .json(&json!({"username":"bob","password":PASSWORD,"role":"dispatcher"}))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::BAD_REQUEST
    );
    let alice = server.token("alice").await;
    let bob = server.token("bob").await;
    let me: Value = server.get("/v1/session", &bob).await.json().await.unwrap();
    assert_eq!(
        me,
        json!({"user":{"id":"driver-bob","name":"Bob fixture","role":"driver","roles":["driver"],"team_id":"test-fleet","team_name":"test-fleet"},"expires_at":NOW+300})
    );
    let drivers: Vec<Value> = server
        .get("/v1/drivers", &alice)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(drivers.len(), 2);
    assert_eq!(drivers[0]["id"], "driver-bob");
    assert_eq!(
        server.get("/v1/drivers", &bob).await.status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        server
            .get("/v1/drivers/driver-carol/route", &bob)
            .await
            .status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        server.get("/v1/route", &alice).await.status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        server
            .client
            .post(format!("{}/v1/shift", server.base))
            .bearer_auth(&bob)
            .json(&json!({"active":true,"capacity":2,"id":"driver-carol"}))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        server
            .client
            .post(format!("{}/v1/deliveries", server.base))
            .bearer_auth(&bob)
            .json(&json!({}))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn sessions_survive_restart_expire_and_revoke_without_storing_raw_tokens() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("pilot.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), config()).await;
    let first = server.token("bob").await;
    let second = server.token("bob").await;
    assert_ne!(first, second);
    assert_eq!(first.len(), 64);
    let db = rusqlite::Connection::open(&path).unwrap();
    let token_hash: String = db
        .query_row("SELECT token_hash FROM sessions LIMIT 1", [], |r| r.get(0))
        .unwrap();
    assert_ne!(first, token_hash);
    assert_ne!(second, token_hash);
    drop(db);
    server.close().await;
    let server = Server::start(&path, clock.clone(), config()).await;
    assert_eq!(server.get("/v1/me", &first).await.status(), StatusCode::OK);
    assert_eq!(
        server
            .client
            .delete(format!("{}/v1/session", server.base))
            .bearer_auth(&first)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        server.get("/v1/me", &first).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(server.get("/v1/me", &second).await.status(), StatusCode::OK);
    clock.0.store(NOW + 300, Ordering::SeqCst);
    assert_eq!(
        server.get("/v1/me", &second).await.status(),
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn account_changes_and_removal_revoke_sessions_on_restart() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("pilot.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), config()).await;
    let alice = server.token("alice").await;
    let bob = server.token("bob").await;
    let carol = server.token("carol").await;
    server.close().await;
    let mut changed = config();
    changed.accounts.remove(2);
    changed.accounts[1].password_hash = hash_password("different-test-fixture-password").unwrap();
    let server = Server::start(&path, clock, changed).await;
    assert_eq!(server.get("/v1/me", &alice).await.status(), StatusCode::OK);
    assert_eq!(
        server.get("/v1/me", &bob).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.get("/v1/me", &carol).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.login("bob", PASSWORD).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.login("carol", PASSWORD).await.status(),
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn login_limits_are_persistent_and_cover_unknown_accounts() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("pilot.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), config()).await;
    for _ in 0..10 {
        assert_eq!(
            server.login("nobody", "wrong").await.status(),
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        server.login("nobody", "wrong").await.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    server.close().await;
    let server = Server::start(&path, clock.clone(), config()).await;
    assert_eq!(
        server.login("nobody", "wrong").await.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    clock.0.store(NOW + 301, Ordering::SeqCst);
    assert_eq!(
        server.login("nobody", "wrong").await.status(),
        StatusCode::UNAUTHORIZED
    );
}

#[test]
fn production_configuration_and_database_modes_fail_closed() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("pilot.db");
    let mut invalid = config();
    invalid.accounts[0].password_hash = "REPLACE_ME".into();
    assert!(AppState::open_production(&path, invalid).is_err());
    assert!(!path.exists());
    let mut invalid = config();
    invalid.accounts[1].username = "alice".into();
    assert!(invalid.validate().is_err());
    let mut invalid = config();
    invalid.accounts[0].role = "admin".into();
    assert!(invalid.validate().is_err());
    let mut invalid = config();
    invalid.accounts[0].id = "..".into();
    assert!(invalid.validate().is_err());
    let mut invalid = config();
    invalid.fleet_id = ".".into();
    assert!(invalid.validate().is_err());
    let mut invalid = config();
    invalid.session_ttl_seconds = 999999;
    assert!(invalid.validate().is_err());
    assert!(AppState::open_production("relative.sqlite3", config()).is_err());
    AppState::open(&path, true).unwrap();
    assert!(AppState::open_production(&path, config()).is_err());
    let production = dir.path().join("separate.db");
    AppState::open_production(&production, config()).unwrap();
    assert!(AppState::open(&production, true).is_err());
    let mut other_fleet = config();
    other_fleet.fleet_id = "other-fleet".into();
    assert!(AppState::open_production(&production, other_fleet).is_err());
}

#[tokio::test]
async fn authenticated_pilot_completes_delivery_and_rejects_other_driver() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("pilot.db"), clock(), config()).await;
    let alice = server.token("alice").await;
    let bob = server.token("bob").await;
    let carol = server.token("carol").await;
    async fn post(
        server: &Server,
        path: &str,
        token: &str,
        body: Value,
        key: &str,
    ) -> reqwest::Response {
        server
            .client
            .post(format!("{}{}", server.base, path))
            .bearer_auth(token)
            .header("Idempotency-Key", key)
            .json(&body)
            .send()
            .await
            .unwrap()
    }
    assert_eq!(
        post(
            &server,
            "/v1/shift",
            &bob,
            json!({"active":true,"capacity":2}),
            "pilot-shift-1"
        )
        .await
        .status(),
        StatusCode::OK
    );
    let point = json!({"lat":36.7163,"lng":15.0908});
    assert_eq!(
        post(
            &server,
            "/v1/location",
            &bob,
            point.clone(),
            "pilot-location-1"
        )
        .await
        .status(),
        StatusCode::OK
    );
    let create = json!({"shop_name":"Pilot test fixture","pickup_address":"Fixture pickup","pickup":point,"dropoff_address":"Fixture dropoff","dropoff":{"lat":36.717,"lng":15.092},"ready_at":NOW,"deadline_at":NOW+3600,"load_units":1,"max_ride_seconds":1800});
    let response = post(
        &server,
        "/v1/deliveries",
        &alice,
        create.clone(),
        "pilot-create-1",
    )
    .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let delivery: Value = response.json().await.unwrap();
    let replay: Value = post(&server, "/v1/deliveries", &alice, create, "pilot-create-1")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(delivery, replay);
    let id = delivery["id"].as_str().unwrap();
    assert_eq!(
        post(
            &server,
            &format!("/v1/deliveries/{id}/assign"),
            &alice,
            json!({"driver_id":"driver-bob"}),
            "pilot-assign-1"
        )
        .await
        .status(),
        StatusCode::OK
    );
    let hidden: Vec<Value> = server
        .get("/v1/deliveries", &carol)
        .await
        .json()
        .await
        .unwrap();
    assert!(hidden.is_empty());
    let path = format!("/v1/deliveries/{id}/status");
    assert_eq!(
        post(
            &server,
            &path,
            &carol,
            json!({"status":"picked_up"}),
            "pilot-pickup-1"
        )
        .await
        .status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        post(
            &server,
            &path,
            &alice,
            json!({"status":"picked_up"}),
            "pilot-pickup-1"
        )
        .await
        .status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        post(
            &server,
            &path,
            &bob,
            json!({"status":"picked_up"}),
            "pilot-pickup-1"
        )
        .await
        .status(),
        StatusCode::OK
    );
    assert_eq!(
        post(
            &server,
            &path,
            &bob,
            json!({"status":"picked_up"}),
            "pilot-pickup-1"
        )
        .await
        .status(),
        StatusCode::OK
    );
    assert_eq!(
        post(
            &server,
            &path,
            &bob,
            json!({"status":"delivered"}),
            "pilot-delivered-1"
        )
        .await
        .status(),
        StatusCode::OK
    );
    let route: Value = server.get("/v1/route", &bob).await.json().await.unwrap();
    assert_eq!(route["stops"], json!([]));
    assert_eq!(
        post(
            &server,
            "/v1/shift",
            &bob,
            json!({"active":false,"capacity":2}),
            "pilot-shift-2"
        )
        .await
        .status(),
        StatusCode::OK
    );
}
