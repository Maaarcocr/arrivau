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
    db_path: std::path::PathBuf,
}
impl Server {
    async fn start(path: &Path, clock: Arc<dyn Clock>, config: ProductionConfig) -> Self {
        let state = AppState::open_production_with_clock(path, config, clock).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let db_path = path.to_path_buf();
        let task = tokio::spawn(async move {
            axum::serve(listener, app(state)).await.unwrap();
        });
        Self {
            base,
            client: Client::new(),
            task,
            db_path,
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
    assert_eq!(drivers.len(), 3); // dispatcher counts as driver
    let ids: Vec<&str> = drivers.iter().map(|d| d["id"].as_str().unwrap()).collect();
    assert!(ids.contains(&"driver-bob"));
    assert!(ids.contains(&"driver-carol"));
    assert!(ids.contains(&"dispatcher-alice"));
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
    // Dispatcher counts as driver, so /v1/route is now accessible (not forbidden)
    assert_ne!(
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

impl Server {
    async fn issue(&self, _dispatcher: &str, name: &str) -> Value {
        self.issue_for_team(_dispatcher, name, "test-fleet").await
    }
    async fn issue_for_team(&self, _dispatcher: &str, name: &str, team: &str) -> Value {
        let token: String = {
            use rand_core::RngCore;
            let mut bytes = [0u8; 32];
            rand_core::OsRng.fill_bytes(&mut bytes);
            bytes.iter().map(|b| format!("{:02x}", b)).collect()
        };
        let hash = format!("{:x}", <sha2::Sha256 as sha2::Digest>::digest(token.as_bytes()));
        let id = uuid::Uuid::new_v4().to_string();
        let db = rusqlite::Connection::open(&self.db_path).unwrap();
        db.execute(
            "INSERT INTO invites(id, token_hash, name, team_id, role, expires_at) VALUES (?1,?2,?3,?4,?5,?6)",
            rusqlite::params![id, hash, name.trim(), team, "driver", NOW + 86400],
        ).unwrap();
        serde_json::json!({"token": token, "role": "driver", "name": name.trim(), "expires_at": NOW + 86400})
    }
    async fn redeem(&self, token: &str, username: &str) -> reqwest::Response {
        self.client
            .post(format!("{}/v1/invites/redeem", self.base))
            .json(&json!({"token":token,"username":username,"password":PASSWORD}))
            .send()
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn invite_signup_is_driver_only_atomic_private_and_survives_restart() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("pilot.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), config()).await;
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "  Nuovo corriere  ").await;
    assert_eq!(invite["name"], "Nuovo corriere");
    assert_eq!(invite["expires_at"], NOW + 86400);
    let secret = invite["token"].as_str().unwrap();
    let db = rusqlite::Connection::open(&path).unwrap();
    let hash: String = db
        .query_row("SELECT token_hash FROM invites", [], |r| r.get(0))
        .unwrap();
    assert_ne!(hash, secret);
    assert_eq!(hash.len(), 64);
    let response = server.redeem(secret, "  new.driver  ").await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let session: Value = response.json().await.unwrap();
    assert_eq!(session["user"]["role"], "driver");
    assert_eq!(session["user"]["name"], "Nuovo corriere");
    let token = session["token"].as_str().unwrap();
    let id = session["user"]["id"].as_str().unwrap();
    assert_eq!(
        server.get("/v1/drivers", token).await.status(),
        StatusCode::FORBIDDEN
    );
    let response = server
        .client
        .post(format!("{}/v1/shift", server.base))
        .bearer_auth(token)
        .json(&json!({"active":true,"capacity":2}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let stored: String = db
        .query_row("SELECT password_hash FROM invited_accounts", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(stored.starts_with("$argon2id$v=19$"));
    assert!(!stored.contains(PASSWORD));
    assert_eq!(
        server.redeem(secret, "another").await.status(),
        StatusCode::BAD_REQUEST
    );
    let remaining: i64 = db
        .query_row("SELECT COUNT(*) FROM invites", [], |r| r.get(0))
        .unwrap();
    assert_eq!(remaining, 0);
    server.close().await;
    let server = Server::start(&path, clock, config()).await;
    assert_eq!(server.get("/v1/me", token).await.status(), StatusCode::OK);
    let drivers: Vec<Value> = server
        .get("/v1/drivers", &alice)
        .await
        .json()
        .await
        .unwrap();
    assert!(drivers.iter().any(|d| d["id"] == id && d["active"] == true));
    assert_eq!(
        server.login("NEW.DRIVER", PASSWORD).await.status(),
        StatusCode::CREATED
    );
    assert_eq!(
        server.login("new.driver", "wrong").await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.login("alice", PASSWORD).await.status(),
        StatusCode::CREATED
    );
}



#[tokio::test]
async fn concurrent_redemption_creates_exactly_one_identity_and_session() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let server = Server::start(&path, clock(), config()).await;
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "Concurrent").await;
    let secret = invite["token"].as_str().unwrap();
    let (a, b) = tokio::join!(
        server.redeem(secret, "first"),
        server.redeem(secret, "second")
    );
    let mut statuses = vec![a.status().as_u16(), b.status().as_u16()];
    statuses.sort();
    assert_eq!(statuses, [201, 400]);
    let db = rusqlite::Connection::open(&path).unwrap();
    let count: i64 = db
        .query_row("SELECT COUNT(*) FROM invited_accounts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 1);
    let session_count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM sessions WHERE account_id LIKE 'invited-%'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(session_count, 1);
    // A second distinct invitation cannot claim the already-created username, even after restart.
    let username: String = db
        .query_row("SELECT username FROM invited_accounts", [], |r| r.get(0))
        .unwrap();
    let second = server.issue(&alice, "Distinct").await;
    assert_eq!(
        server
            .redeem(second["token"].as_str().unwrap(), &username)
            .await
            .status(),
        StatusCode::CONFLICT
    );
}

#[tokio::test]
async fn invite_limits_persist_and_disabled_accounts_stay_disabled() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), config()).await;
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "Disabled").await;
    let created: Value = server
        .redeem(invite["token"].as_str().unwrap(), "disabled")
        .await
        .json()
        .await
        .unwrap();
    let token = created["token"].as_str().unwrap();
    arrivau_api::auth::disable_invited_account(&path, "disabled").unwrap();
    assert_eq!(
        server.get("/v1/me", token).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.login("disabled", PASSWORD).await.status(),
        StatusCode::UNAUTHORIZED
    );
    for _ in 0..10 {
        assert_eq!(
            server.redeem(&"1".repeat(64), "limited").await.status(),
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(
        server.redeem(&"1".repeat(64), "limited").await.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    server.close().await;
    let server = Server::start(&path, clock, config()).await;
    assert_eq!(
        server.redeem(&"1".repeat(64), "limited").await.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        server.login("disabled", PASSWORD).await.status(),
        StatusCode::UNAUTHORIZED
    );
    let second = server.issue(&alice, "New").await;
    assert_eq!(
        server
            .redeem(second["token"].as_str().unwrap(), "disabled")
            .await
            .status(),
        StatusCode::CONFLICT
    );
    let db = rusqlite::Connection::open(&path).unwrap();
    let count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM drivers WHERE id=?1",
            [created["user"]["id"].as_str().unwrap()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
    let mut conflicting = config();
    conflicting.accounts[1].username = "disabled".into();
    assert!(AppState::open_production(&path, conflicting)
        .err()
        .unwrap()
        .contains("collide"));
}

#[tokio::test]
async fn existing_pilot_database_additive_upgrade_preserves_driver_and_session() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), config()).await;
    let bob = server.token("bob").await;
    server.close().await;
    // Simulate the exact pre-invite schema, keeping existing pilot data in place.
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("DROP TABLE invites; DROP TABLE invited_accounts; DROP TABLE idempotency_retired; PRAGMA user_version=3;")
        .unwrap();
    drop(db);
    let server = Server::start(&path, clock, config()).await;
    assert_eq!(server.get("/v1/me", &bob).await.status(), StatusCode::OK);
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "Migrated").await;
    assert_eq!(
        server
            .redeem(invite["token"].as_str().unwrap(), "migrated")
            .await
            .status(),
        StatusCode::CREATED
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delayed_authenticated_shift_cannot_reactivate_disabled_invited_driver() {
    use std::io::{Read, Write};
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let server = Server::start(&path, clock(), config()).await;
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "Delayed").await;
    let created: Value = server
        .redeem(invite["token"].as_str().unwrap(), "delayed")
        .await
        .json()
        .await
        .unwrap();
    let token = created["token"].as_str().unwrap().to_owned();
    let address = server.base.trim_start_matches("http://").to_owned();
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let request = tokio::task::spawn_blocking(move || {
        let mut socket = std::net::TcpStream::connect(&address).unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let body = r#"{"active":true,"capacity":2}"#;
        write!(socket,"POST /v1/shift HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n",body.len()).unwrap();
        let mut interim = Vec::new();
        let mut byte = [0];
        while !interim.ends_with(b"\r\n\r\n") {
            socket.read_exact(&mut byte).unwrap();
            interim.push(byte[0]);
        }
        assert!(String::from_utf8(interim).unwrap().contains("100 Continue"));
        ready_tx.send(()).unwrap();
        release_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        socket.write_all(body.as_bytes()).unwrap();
        let mut response = String::new();
        socket.read_to_string(&mut response).unwrap();
        response
    });
    ready_rx.await.unwrap();
    arrivau_api::auth::disable_invited_account(&path, "delayed").unwrap();
    release_tx.send(()).unwrap();
    let response = request.await.unwrap();
    assert!(response.starts_with("HTTP/1.1 401"), "{response}");
    let db = rusqlite::Connection::open(&path).unwrap();
    let active: bool = db
        .query_row(
            "SELECT json_extract(body,'$.active') FROM drivers WHERE id=?1",
            [created["user"]["id"].as_str().unwrap()],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!active);
}

#[tokio::test]
async fn invite_creation_rolls_back_if_session_insert_fails() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let server = Server::start(&path, clock(), config()).await;
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "Rollback").await;
    let secret = invite["token"].as_str().unwrap();
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("CREATE TRIGGER fail_invited_session BEFORE INSERT ON sessions WHEN NEW.account_id LIKE 'invited-%' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
    assert_eq!(
        server.redeem(secret, "rollback").await.status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
    let count: i64 = db
        .query_row("SELECT COUNT(*) FROM invited_accounts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    let drivers: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM drivers WHERE id LIKE 'invited-%'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(drivers, 0);
    let invites: i64 = db
        .query_row("SELECT COUNT(*) FROM invites", [], |r| r.get(0))
        .unwrap();
    assert_eq!(invites, 1);
    db.execute_batch("DROP TRIGGER fail_invited_session;")
        .unwrap();
    assert_eq!(
        server.redeem(secret, "rollback").await.status(),
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn distinct_invites_racing_for_one_username_preserve_the_losing_invite() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let server = Server::start(&path, clock(), config()).await;
    let alice = server.token("alice").await;
    let a = server.issue(&alice, "First").await;
    let b = server.issue(&alice, "Second").await;
    let (first, second) = tokio::join!(
        server.redeem(a["token"].as_str().unwrap(), "unique"),
        server.redeem(b["token"].as_str().unwrap(), "unique")
    );
    let losing = if first.status() == StatusCode::CONFLICT {
        &a
    } else {
        &b
    };
    let mut statuses = vec![first.status().as_u16(), second.status().as_u16()];
    statuses.sort();
    assert_eq!(statuses, [201, 409]);
    assert_eq!(
        server
            .redeem(losing["token"].as_str().unwrap(), "different")
            .await
            .status(),
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn expiry_between_admission_and_hashed_redemption_creates_nothing() {
    struct AdmissionClock {
        now: AtomicI64,
        expire_next: std::sync::atomic::AtomicBool,
    }
    impl Clock for AdmissionClock {
        fn now(&self) -> i64 {
            if self.expire_next.swap(false, Ordering::SeqCst) {
                self.now.fetch_add(86400, Ordering::SeqCst)
            } else {
                self.now.load(Ordering::SeqCst)
            }
        }
    }
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let clock = Arc::new(AdmissionClock {
        now: AtomicI64::new(NOW),
        expire_next: std::sync::atomic::AtomicBool::new(false),
    });
    let server = Server::start(&path, clock.clone(), config()).await;
    let alice = server.token("alice").await;
    let invite = server.issue(&alice, "Expires during signup").await;
    clock.expire_next.store(true, Ordering::SeqCst);
    assert_eq!(
        server
            .redeem(invite["token"].as_str().unwrap(), "expired")
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let db = rusqlite::Connection::open(&path).unwrap();
    let accounts: i64 = db
        .query_row("SELECT COUNT(*) FROM invited_accounts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(accounts, 0);
    let sessions: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM sessions WHERE account_id LIKE 'invited-%'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(sessions, 0);
}


#[tokio::test]
async fn isolated_demo_cannot_issue_or_redeem_invites() {
    let dir = TempDir::new().unwrap();
    let state = AppState::open(dir.path().join("demo.db"), true).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        axum::serve(listener, app(state)).await.unwrap();
    });
    let server = Server {
        base,
        client: Client::new(),
        task,
        db_path: dir.path().join("p.db"),
    };
    let response = server
        .client
        .post(format!("{}/v1/invites", server.base))
        .bearer_auth("demo-dispatcher")
        .json(&json!({"name":"Fixture"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        server.redeem(&"0".repeat(64), "fixture").await.status(),
        StatusCode::NOT_FOUND
    );
}

fn team_config() -> ProductionConfig {
    let mut value = config();
    value.teams = vec![
        arrivau_api::auth::Team {
            id: "test-fleet".into(),
            name: "Squadra pilota".into(),
        },
        arrivau_api::auth::Team {
            id: "review".into(),
            name: "Squadra revisione".into(),
        },
    ];
    let mut reviewer = value.accounts[0].clone();
    reviewer.id = "review-dual".into();
    reviewer.username = "reviewer".into();
    reviewer.role = "driver".into();
    reviewer.roles = Some(vec!["driver".into(), "dispatcher".into()]);
    reviewer.team_id = Some("review".into());
    value.accounts.push(reviewer);
    value
}


#[tokio::test]
async fn configured_team_removal_disables_dynamic_membership_without_moving_history() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("p.db");
    let clock = clock();
    let mut server = Server::start(&path, clock.clone(), team_config()).await;
    let review: Value = server
        .login("reviewer", PASSWORD)
        .await
        .json()
        .await
        .unwrap();
    let invite = server
        .issue_for_team(review["token"].as_str().unwrap(), "Team removal", "review")
        .await;
    let created: Value = server
        .redeem(invite["token"].as_str().unwrap(), "retained-reviewer")
        .await
        .json()
        .await
        .unwrap();
    let token = created["token"].as_str().unwrap();
    let id = created["user"]["id"].as_str().unwrap();
    server.close().await;
    // Removing the issuer alone does not remove a previously claimed driver's membership.
    let mut no_issuer = team_config();
    no_issuer.accounts.pop();
    let mut server = Server::start(&path, clock.clone(), no_issuer.clone()).await;
    assert_eq!(server.get("/v1/me", token).await.status(), StatusCode::OK);
    server.close().await;
    no_issuer.teams.retain(|team| team.id != "review");
    let mut server = Server::start(&path, clock.clone(), no_issuer).await;
    assert_eq!(
        server.get("/v1/me", token).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        server.login("retained-reviewer", PASSWORD).await.status(),
        StatusCode::UNAUTHORIZED
    );
    let db = rusqlite::Connection::open(&path).unwrap();
    let team: String = db
        .query_row(
            "SELECT team_id FROM account_teams WHERE account_id=?1",
            [id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(team, "review");
    let mut collision = config();
    collision.accounts[1].id = id.into();
    assert!(AppState::open_production(&path, collision).is_err());
    server.close().await;
    let server = Server::start(&path, clock, team_config()).await;
    assert_eq!(
        server.get("/v1/me", token).await.status(),
        StatusCode::UNAUTHORIZED
    );
    let login: Value = server
        .login("retained-reviewer", PASSWORD)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(login["user"]["team_id"], "review");
}

