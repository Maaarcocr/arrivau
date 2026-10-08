//! Black-box account deletion contracts. All accounts, credentials, addresses and
//! coordinates below belong to disposable test databases, never real users.
use arrivau_api::{
    app,
    auth::{hash_password, Account, ProductionConfig, Team},
    AppState, Clock,
};
use reqwest::{Client, Response, StatusCode};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc, OnceLock,
    },
};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};

const NOW: i64 = 1_790_874_000;
const PASSWORD: &str = "deletion-fixture-only-password";
const TEAM: &str = "test-fleet";
const OTHER_TEAM: &str = "other-fleet";

struct TestClock(AtomicI64);
impl Clock for TestClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}
fn clock() -> Arc<TestClock> {
    Arc::new(TestClock(AtomicI64::new(NOW)))
}
fn password_hash() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    HASH.get_or_init(|| hash_password(PASSWORD).unwrap())
}
fn config() -> ProductionConfig {
    ProductionConfig {
        fleet_id: TEAM.into(),
        teams: vec![
            Team {
                id: TEAM.into(),
                name: "Fixture team".into(),
            },
            Team {
                id: OTHER_TEAM.into(),
                name: "Other fixture team".into(),
            },
        ],
        session_ttl_seconds: 3600,
        accounts: [
            ("dispatcher", "dispatcher", TEAM),
            ("configured-driver", "driver", TEAM),
            ("foreign-driver", "driver", OTHER_TEAM),
        ]
        .into_iter()
        .map(|(id, role, team)| Account {
            id: id.into(),
            username: id.into(),
            name: format!("{id} fixture"),
            role: role.into(),
            roles: None,
            team_id: Some(team.into()),
            password_hash: password_hash().into(),
            deletable: false,
        })
        .collect(),
    }
}
struct Server {
    base: String,
    client: Client,
    task: JoinHandle<()>,
}
impl Server {
    async fn from_state(state: AppState) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app(state)).await.unwrap() });
        Self {
            base,
            client: Client::new(),
            task,
        }
    }
    async fn start(path: &Path, clock: Arc<dyn Clock>) -> Self {
        Self::from_state(AppState::open_production_with_clock(path, config(), clock).unwrap()).await
    }
    async fn get(&self, path: &str, token: &str) -> Response {
        self.client
            .get(format!("{}{}", self.base, path))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
    }
    async fn login(&self, username: &str) -> Response {
        self.client
            .post(format!("{}/v1/session", self.base))
            .json(&json!({"username":username,"password":PASSWORD}))
            .send()
            .await
            .unwrap()
    }
    async fn session(&self, username: &str) -> Value {
        let response = self.login(username).await;
        assert_eq!(response.status(), StatusCode::CREATED);
        response.json().await.unwrap()
    }
    async fn token(&self, username: &str) -> String {
        self.session(username).await["token"]
            .as_str()
            .unwrap()
            .to_owned()
    }
    async fn preview(&self, token: &str) -> Value {
        let response = self.get("/v1/account/deletion-preview", token).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["cache-control"], "no-store");
        let value: Value = response.json().await.unwrap();
        let confirmation = value["confirmation"].as_str().unwrap();
        assert_eq!(confirmation.len(), 64);
        assert!(confirmation
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)));
        assert_eq!(value.as_object().unwrap().len(), 3);
        value
    }
    async fn delete_body(&self, token: &str, body: Value) -> Response {
        self.client
            .delete(format!("{}/v1/account", self.base))
            .bearer_auth(token)
            .json(&body)
            .send()
            .await
            .unwrap()
    }
    async fn delete(&self, token: &str, password: &str, preview: &Value) -> Response {
        self.delete_body(
            token,
            json!({"password":password,"confirmation":preview["confirmation"]}),
        )
        .await
    }
    async fn create_delivery(&self, token: &str, key: &str, body: &Value) -> Response {
        self.client
            .post(format!("{}/v1/deliveries", self.base))
            .bearer_auth(token)
            .header("Idempotency-Key", key)
            .json(body)
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
struct Fixture {
    _dir: TempDir,
    path: PathBuf,
    clock: Arc<TestClock>,
    server: Server,
    db: Connection,
}
impl Fixture {
    async fn new() -> Self {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("deletion.db");
        let clock = clock();
        let server = Server::start(&path, clock.clone()).await;
        let db = Connection::open(&path).unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON;").unwrap();
        Self {
            _dir: dir,
            path,
            clock,
            server,
            db,
        }
    }
    async fn invited(&self, username: &str) -> Value {
        let token: String = {
            use rand_core::RngCore;
            let mut bytes = [0u8; 32];
            rand_core::OsRng.fill_bytes(&mut bytes);
            bytes.iter().map(|b| format!("{:02x}", b)).collect()
        };
        let hash = format!(
            "{:x}",
            <sha2::Sha256 as sha2::Digest>::digest(token.as_bytes())
        );
        let id = uuid::Uuid::new_v4().to_string();
        self.db.execute(
            "INSERT INTO invites(id, token_hash, name, team_id, role, expires_at) VALUES (?1,?2,?3,?4,?5,?6)",
            params![id, hash, format!("{username} fixture"), TEAM, "driver", 1790874000i64 + 86400],
        ).unwrap();
        let response = self
            .server
            .client
            .post(format!("{}/v1/invites/redeem", self.server.base))
            .json(&json!({"token":token,"username":username,"password":PASSWORD}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        response.json().await.unwrap()
    }
    // For throttle tests, avoid repeatedly running signup's independent limiter.
    // Authentication itself still runs through the real HTTP/password path.
    fn seed_invited(&self, id: &str, team: &str) {
        self.db
            .execute(
                "INSERT INTO account_teams(account_id,team_id) VALUES (?1,?2)",
                params![id, team],
            )
            .unwrap();
        self.db.execute("INSERT INTO accounts(id,username,name,password_hash,team_id) VALUES (?1,?1,?1,?2,?3)", params![id,password_hash(),team]).unwrap();
        let driver = json!({"id":id,"name":id,"active":true,"capacity":2,"location":{"lat":36.7,"lng":15.1},"location_updated_at":NOW});
        self.db
            .execute(
                "INSERT INTO drivers(id,team_id,body) VALUES (?1,?2,?3)",
                params![id, team, driver.to_string()],
            )
            .unwrap();
    }
    async fn restart(&mut self) {
        self.server.close().await;
        self.server = Server::start(&self.path, self.clock.clone()).await;
    }
}
fn new_delivery() -> Value {
    json!({"shop_name":"Fixture restaurant","pickup_address":"Fixture pickup","pickup":{"lat":36.7,"lng":15.1},"dropoff_address":"Fixture customer address","dropoff":{"lat":36.701,"lng":15.101},"ready_at":NOW,"deadline_at":NOW+3600,"load_units":1,"max_ride_seconds":3600})
}
fn delivery(db: &Connection, id: &str, driver: Option<&str>, team: &str, status: &str) {
    let mut body = new_delivery();
    let value = body.as_object_mut().unwrap();
    value.insert("id".into(), json!(id));
    value.insert("driver_id".into(), json!(driver));
    value.insert("status".into(), json!(status));
    value.insert("created_at".into(), json!(NOW));
    value.insert("readiness_state".into(), json!("estimated"));
    value.insert("readiness_revision".into(), json!(0));
    value.insert(
        "picked_up_at".into(),
        if matches!(status, "picked_up" | "delivered") {
            json!(NOW)
        } else {
            Value::Null
        },
    );
    value.insert(
        "delivered_at".into(),
        if status == "delivered" {
            json!(NOW + 1)
        } else {
            Value::Null
        },
    );
    db.execute(
        "INSERT INTO deliveries(id,driver_id,status,body,team_id) VALUES (?1,?2,?3,?4,?5)",
        params![id, driver, status, body.to_string(), team],
    )
    .unwrap();
}
fn route(db: &Connection, driver: &str, position: i64, delivery: &str, kind: &str, team: &str) {
    db.execute("INSERT INTO route_stops(driver_id,position,delivery_id,kind,team_id) VALUES (?1,?2,?3,?4,?5)", params![driver,position,delivery,kind,team]).unwrap();
}
fn cache(db: &Connection, principal: &str, key: &str, team: &str, response: Value) {
    db.execute("INSERT INTO idempotency(principal_id,key,request_hash,response,team_id) VALUES (?1,?2,'fixture-request-digest',?3,?4)",params![principal,key,response.to_string(),team]).unwrap();
}
fn count(db: &Connection, sql: &str, parameter: &str) -> i64 {
    db.query_row(sql, [parameter], |r| r.get(0)).unwrap()
}
async fn error(response: Response, status: StatusCode, message: &str) {
    assert_eq!(response.status(), status);
    assert_eq!(
        response.json::<Value>().await.unwrap(),
        json!({"error":message})
    );
}

#[tokio::test]
async fn only_durable_accounts_advertise_and_allow_account_deletion() {
    let fixture = Fixture::new().await;
    let created = fixture.invited("new-driver").await;
    let token = created["token"].as_str().unwrap();
    assert_eq!(created["user"]["can_delete_account"], true);
    for endpoint in ["/v1/me", "/v1/session"] {
        let me: Value = fixture
            .server
            .get(endpoint, token)
            .await
            .json()
            .await
            .unwrap();
        let principal = if endpoint == "/v1/session" {
            &me["user"]
        } else {
            &me
        };
        assert_eq!(principal["can_delete_account"], true);
    }
    let logged_in = fixture.server.session("new-driver").await;
    assert_eq!(logged_in["user"]["can_delete_account"], true);
    for username in ["dispatcher", "configured-driver", "foreign-driver"] {
        let session = fixture.server.session(username).await;
        assert!(session["user"].get("can_delete_account").is_none());
        let token = session["token"].as_str().unwrap();
        assert_eq!(
            fixture
                .server
                .get("/v1/account/deletion-preview", token)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            fixture
                .server
                .delete_body(
                    token,
                    json!({"password":PASSWORD,"confirmation":"0".repeat(64)})
                )
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
    }
    let demo_path = fixture._dir.path().join("demo.db");
    let demo = Server::from_state(
        AppState::open_with_clock(demo_path, true, fixture.clock.clone()).unwrap(),
    )
    .await;
    for token in ["demo-driver-1", "demo-dispatcher", "demo-dual"] {
        let me: Value = demo.get("/v1/me", token).await.json().await.unwrap();
        assert!(me.get("can_delete_account").is_none());
        assert_eq!(
            demo.get("/v1/account/deletion-preview", token)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            demo.delete_body(
                token,
                json!({"password":PASSWORD,"confirmation":"0".repeat(64)})
            )
            .await
            .status(),
            StatusCode::FORBIDDEN
        );
    }
}

#[tokio::test]
async fn hard_delete_cleans_all_linked_work_and_sessions_preserving_every_other_team_record() {
    let mut fixture = Fixture::new().await;
    let created = fixture.invited("delete-me").await;
    let token = created["token"].as_str().unwrap();
    let id = created["user"]["id"].as_str().unwrap();
    let second_token = fixture.server.token("delete-me").await;
    let dispatcher_token = fixture.server.token("dispatcher").await;
    fixture.seed_invited("keep-invited", TEAM);
    let other_token = fixture.server.token("keep-invited").await;
    for (delivery_id, status) in [
        ("own-assigned", "assigned"),
        ("own-picked", "picked_up"),
        ("own-complete", "delivered"),
    ] {
        delivery(&fixture.db, delivery_id, Some(id), TEAM, status);
    }
    delivery(
        &fixture.db,
        "keep-own-team",
        Some("configured-driver"),
        TEAM,
        "assigned",
    );
    delivery(&fixture.db, "keep-unassigned", None, TEAM, "pending");
    delivery(
        &fixture.db,
        "keep-other-team",
        Some("foreign-driver"),
        OTHER_TEAM,
        "assigned",
    );
    route(&fixture.db, id, 0, "own-assigned", "pickup", TEAM);
    route(&fixture.db, id, 1, "own-picked", "dropoff", TEAM);
    // Its stale route can also contain a delivery whose record must survive.
    route(&fixture.db, id, 2, "keep-unassigned", "pickup", TEAM);
    // Historical/reassigned plans can refer to this driver's work on another route.
    route(
        &fixture.db,
        "configured-driver",
        0,
        "own-assigned",
        "dropoff",
        TEAM,
    );
    route(
        &fixture.db,
        "configured-driver",
        1,
        "keep-own-team",
        "dropoff",
        TEAM,
    );
    route(
        &fixture.db,
        "foreign-driver",
        0,
        "keep-other-team",
        "dropoff",
        OTHER_TEAM,
    );
    fixture.db.execute("UPDATE drivers SET body=json_set(body,'$.active',json('true'),'$.location',json('{\"lat\":36.7,\"lng\":15.1}'),'$.location_updated_at',?1) WHERE id=?2",params![NOW,id]).unwrap();
    fixture.db.execute("INSERT INTO restaurants(id,team_id,body) VALUES ('shared-restaurant',?1,?2)",params![TEAM,json!({"id":"shared-restaurant","name":"Shared fixture","address":"Shared pickup","coordinate":{"lat":36.7,"lng":15.1},"created_at":NOW}).to_string()]).unwrap();
    let preview = fixture.server.preview(token).await;
    assert_eq!(preview["delivery_count"], 3);
    assert_eq!(preview["active_delivery_count"], 2);
    let response = fixture.server.delete(token, PASSWORD, &preview).await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(response.bytes().await.unwrap().is_empty());
    for table in ["accounts", "drivers"] {
        assert_eq!(
            count(
                &fixture.db,
                &format!("SELECT COUNT(*) FROM {table} WHERE id=?1"),
                id
            ),
            0
        );
    }
    for (table, column) in [
        ("sessions", "account_id"),
        ("account_teams", "account_id"),
        ("idempotency", "principal_id"),
        ("deliveries", "driver_id"),
        ("route_stops", "driver_id"),
    ] {
        assert_eq!(
            count(
                &fixture.db,
                &format!("SELECT COUNT(*) FROM {table} WHERE {column}=?1"),
                id
            ),
            0,
            "{table}"
        );
    }
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM deliveries WHERE id LIKE ?1",
            "own-%"
        ),
        0
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM route_stops WHERE delivery_id LIKE ?1",
            "own-%"
        ),
        0
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM deliveries WHERE id LIKE ?1",
            "keep-%"
        ),
        3
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM route_stops WHERE delivery_id LIKE ?1",
            "keep-%"
        ),
        2
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM restaurants WHERE id=?1",
            "shared-restaurant"
        ),
        1
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM accounts WHERE id=?1",
            "keep-invited"
        ),
        1
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM account_teams WHERE account_id=?1",
            "configured-driver"
        ),
        1
    );
    for session in [token, second_token.as_str()] {
        assert_eq!(
            fixture.server.get("/v1/me", session).await.status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            fixture
                .server
                .delete(session, PASSWORD, &preview)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
    for session in [&dispatcher_token, &other_token] {
        assert_eq!(
            fixture.server.get("/v1/me", session).await.status(),
            StatusCode::OK
        );
    }
    assert_eq!(
        fixture.server.login("delete-me").await.status(),
        StatusCode::UNAUTHORIZED
    );
    fixture.restart().await;
    assert_eq!(
        fixture.server.login("delete-me").await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        fixture.server.get("/v1/me", &other_token).await.status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn preview_ignores_unrelated_writes_but_rechecks_readiness_pickup_and_assignment() {
    let fixture = Fixture::new().await;
    fixture.seed_invited("preview-driver", TEAM);
    let token = fixture.server.token("preview-driver").await;
    delivery(
        &fixture.db,
        "linked-job",
        Some("preview-driver"),
        TEAM,
        "assigned",
    );
    let initial = fixture.server.preview(&token).await;
    delivery(
        &fixture.db,
        "unrelated-job",
        Some("foreign-driver"),
        OTHER_TEAM,
        "delivered",
    );
    fixture.db.execute("UPDATE drivers SET body=json_set(body,'$.location_updated_at',?1) WHERE id='preview-driver'",[NOW+10]).unwrap();
    assert_eq!(fixture.server.preview(&token).await, initial);
    for sql in [
        "UPDATE deliveries SET body=json_set(body,'$.readiness_revision',1,'$.readiness_state','ready') WHERE id='linked-job'",
        "UPDATE deliveries SET status='picked_up',body=json_set(body,'$.status','picked_up','$.picked_up_at',1790874001) WHERE id='linked-job'",
        "UPDATE deliveries SET driver_id='configured-driver',body=json_set(body,'$.driver_id','configured-driver') WHERE id='linked-job'",
    ] {
        let before = fixture.server.preview(&token).await;
        fixture.db.execute_batch(sql).unwrap();
        let after = fixture.server.preview(&token).await;
        assert_ne!(before["confirmation"],after["confirmation"]);
        error(fixture.server.delete(&token,PASSWORD,&before).await,StatusCode::CONFLICT,"Deletion preview changed; review again").await;
        assert_eq!(count(&fixture.db,"SELECT COUNT(*) FROM accounts WHERE id=?1","preview-driver"),1);
    }
    let final_preview = fixture.server.preview(&token).await;
    assert_eq!(final_preview["delivery_count"], 0);
    assert_eq!(final_preview["active_delivery_count"], 0);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &final_preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM deliveries WHERE id=?1",
            "linked-job"
        ),
        1
    );
}

#[tokio::test]
async fn missing_malformed_or_unknown_delete_fields_are_rejected_without_changes() {
    let fixture = Fixture::new().await;
    fixture.seed_invited("validation-driver", TEAM);
    let token = fixture.server.token("validation-driver").await;
    let preview = fixture.server.preview(&token).await;
    for body in [
        json!({"password":PASSWORD}),
        json!({"password":PASSWORD,"confirmation":"not-a-digest"}),
        json!({"password":PASSWORD,"confirmation":"A".repeat(64)}),
        json!({"confirmation":preview["confirmation"]}),
        json!({"password":PASSWORD,"confirmation":preview["confirmation"],"account_id":"configured-driver"}),
    ] {
        assert_eq!(
            fixture.server.delete_body(&token, body).await.status(),
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(fixture.server.preview(&token).await, preview);
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM accounts WHERE id=?1",
            "validation-driver"
        ),
        1
    );
}

#[tokio::test]
async fn wrong_password_and_foreign_confirmation_cannot_delete_an_account() {
    let fixture = Fixture::new().await;
    fixture.seed_invited("owner-driver", TEAM);
    fixture.seed_invited("foreign-invited", OTHER_TEAM);
    let owner = fixture.server.token("owner-driver").await;
    let foreign = fixture.server.token("foreign-invited").await;
    let preview = fixture.server.preview(&owner).await;
    let foreign_preview = fixture.server.preview(&foreign).await;
    assert_ne!(preview["confirmation"], foreign_preview["confirmation"]);
    error(
        fixture
            .server
            .delete(&owner, "wrong fixture password", &preview)
            .await,
        StatusCode::FORBIDDEN,
        "Password confirmation failed",
    )
    .await;
    error(
        fixture
            .server
            .delete(&owner, PASSWORD, &foreign_preview)
            .await,
        StatusCode::CONFLICT,
        "Deletion preview changed; review again",
    )
    .await;
    assert_eq!(
        fixture.server.get("/v1/me", &owner).await.status(),
        StatusCode::OK
    );
    assert_eq!(
        fixture
            .server
            .delete(&owner, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        fixture.server.get("/v1/me", &foreign).await.status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn deletion_requires_a_current_nonrevoked_session() {
    let fixture = Fixture::new().await;
    fixture.seed_invited("auth-driver", TEAM);
    let token = fixture.server.token("auth-driver").await;
    let preview = fixture.server.preview(&token).await;
    for unauthorized in ["", "not-a-session", &"0".repeat(64)] {
        assert_eq!(
            fixture
                .server
                .get("/v1/account/deletion-preview", unauthorized)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            fixture
                .server
                .delete(unauthorized, PASSWORD, &preview)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
    let response = fixture
        .server
        .client
        .delete(format!("{}/v1/session", fixture.server.base))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        fixture
            .server
            .get("/v1/account/deletion-preview", &token)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let token = fixture.server.token("auth-driver").await;
    fixture.clock.0.store(NOW + 3600, Ordering::SeqCst);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        fixture
            .server
            .get("/v1/account/deletion-preview", &token)
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM accounts WHERE id=?1",
            "auth-driver"
        ),
        1
    );
}

#[tokio::test]
async fn storage_failure_rolls_back_every_part_of_hard_deletion() {
    let fixture = Fixture::new().await;
    fixture.seed_invited("rollback-driver", TEAM);
    let token = fixture.server.token("rollback-driver").await;
    delivery(
        &fixture.db,
        "rollback-job",
        Some("rollback-driver"),
        TEAM,
        "assigned",
    );
    route(
        &fixture.db,
        "rollback-driver",
        0,
        "rollback-job",
        "pickup",
        TEAM,
    );
    cache(
        &fixture.db,
        "dispatcher",
        "rollback-create-key",
        TEAM,
        json!({"id":"rollback-job"}),
    );
    cache(
        &fixture.db,
        "rollback-driver",
        "rollback-own-key",
        TEAM,
        json!({"id":"rollback-driver"}),
    );
    let preview = fixture.server.preview(&token).await;
    fixture.db.execute_batch("CREATE TRIGGER fail_account_cleanup BEFORE DELETE ON drivers WHEN OLD.id='rollback-driver' BEGIN SELECT RAISE(ABORT,'fixture delete failure'); END;").unwrap();
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
    for (table, column, value) in [
        ("accounts", "id", "rollback-driver"),
        ("drivers", "id", "rollback-driver"),
        ("sessions", "account_id", "rollback-driver"),
        ("account_teams", "account_id", "rollback-driver"),
        ("deliveries", "id", "rollback-job"),
        ("route_stops", "delivery_id", "rollback-job"),
    ] {
        assert_eq!(
            count(
                &fixture.db,
                &format!("SELECT COUNT(*) FROM {table} WHERE {column}=?1"),
                value
            ),
            1,
            "{table}"
        );
    }
    assert_eq!(fixture.server.preview(&token).await, preview);
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM idempotency WHERE key LIKE ?1",
            "rollback-%"
        ),
        2
    );
    let retired: i64 = fixture
        .db
        .query_row("SELECT COUNT(*) FROM idempotency_retired", [], |r| r.get(0))
        .unwrap();
    assert_eq!(retired, 0);
    fixture
        .db
        .execute_batch("DROP TRIGGER fail_account_cleanup;")
        .unwrap();
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn deletion_password_attempt_limit_is_durable_and_resets_after_five_minutes() {
    let mut fixture = Fixture::new().await;
    fixture.seed_invited("limited-driver", TEAM);
    let token = fixture.server.token("limited-driver").await;
    let preview = fixture.server.preview(&token).await;
    for _ in 0..5 {
        error(
            fixture
                .server
                .delete(&token, "wrong fixture password", &preview)
                .await,
            StatusCode::FORBIDDEN,
            "Password confirmation failed",
        )
        .await;
    }
    fixture.restart().await;
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    fixture.clock.0.store(NOW + 299, Ordering::SeqCst);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    fixture.clock.0.store(NOW + 300, Ordering::SeqCst);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn deletion_global_limit_survives_restart_and_resets_after_one_minute() {
    let mut fixture = Fixture::new().await;
    for index in 0..7 {
        fixture.seed_invited(&format!("global-driver-{index}"), TEAM);
    }
    for index in 0..6 {
        let token = fixture
            .server
            .token(&format!("global-driver-{index}"))
            .await;
        let preview = fixture.server.preview(&token).await;
        for _ in 0..5 {
            error(
                fixture
                    .server
                    .delete(&token, "wrong fixture password", &preview)
                    .await,
                StatusCode::FORBIDDEN,
                "Password confirmation failed",
            )
            .await;
        }
    }
    let token = fixture.server.token("global-driver-6").await;
    let preview = fixture.server.preview(&token).await;
    fixture.restart().await;
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    fixture.clock.0.store(NOW + 59, Ordering::SeqCst);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    fixture.clock.0.store(NOW + 60, Ordering::SeqCst);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn deleted_delivery_creation_keys_cannot_replay_personal_data_or_recreate_the_job() {
    let mut fixture = Fixture::new().await;
    fixture.seed_invited("retry-driver", TEAM);
    let driver = fixture.server.token("retry-driver").await;
    let dispatcher = fixture.server.token("dispatcher").await;
    let body = new_delivery();
    let response = fixture
        .server
        .create_delivery(&dispatcher, "delete-create-key", &body)
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let created: Value = response.json().await.unwrap();
    let id = created["id"].as_str().unwrap();
    // Link the delivery after its immutable creation response was cached.
    fixture.db.execute("UPDATE deliveries SET driver_id='retry-driver',status='delivered',body=json_set(body,'$.driver_id','retry-driver','$.status','delivered','$.delivered_at',?1) WHERE id=?2",params![NOW+1,id]).unwrap();
    let preview = fixture.server.preview(&driver).await;
    assert_eq!(
        fixture
            .server
            .delete(&driver, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM idempotency WHERE json_extract(response,'$.id')=?1",
            id
        ),
        0
    );
    fixture.restart().await;
    let response = fixture
        .server
        .create_delivery(&dispatcher, "delete-create-key", &body)
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let returned = response.text().await.unwrap();
    assert!(!returned.contains("Fixture customer address"));
    assert!(!returned.contains(id));
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM deliveries WHERE id=?1",
            id
        ),
        0
    );
    let total: i64 = fixture
        .db
        .query_row("SELECT COUNT(*) FROM deliveries", [], |r| r.get(0))
        .unwrap();
    assert_eq!(total, 0);
    assert_eq!(
        fixture
            .server
            .create_delivery(&dispatcher, "fresh-create-key", &body)
            .await
            .status(),
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn cached_personal_snapshots_are_erased_even_after_reassignment_without_touching_other_retries(
) {
    let fixture = Fixture::new().await;
    fixture.seed_invited("cache-driver", TEAM);
    let token = fixture.server.token("cache-driver").await;
    delivery(
        &fixture.db,
        "removed-job",
        Some("cache-driver"),
        TEAM,
        "delivered",
    );
    delivery(
        &fixture.db,
        "reassigned-job",
        Some("configured-driver"),
        TEAM,
        "assigned",
    );
    cache(
        &fixture.db,
        "cache-driver",
        "driver-location-key",
        TEAM,
        json!({"id":"cache-driver","location":{"lat":36.7,"lng":15.1}}),
    );
    cache(
        &fixture.db,
        "dispatcher",
        "affected-create-key",
        TEAM,
        json!({"nested":{"id":"removed-job"},"dropoff_address":"Deleted fixture address"}),
    );
    cache(
        &fixture.db,
        "dispatcher",
        "affected-history-key",
        TEAM,
        json!({"id":"reassigned-job","driver_id":"cache-driver","name":"Deleted fixture driver"}),
    );
    let retained = json!({"id":"reassigned-job","driver_id":"configured-driver"});
    cache(
        &fixture.db,
        "dispatcher",
        "retained-own-team-key",
        TEAM,
        retained.clone(),
    );
    let same_team_other_principal = json!({"id":"configured-driver","active":true});
    cache(
        &fixture.db,
        "configured-driver",
        "affected-create-key",
        TEAM,
        same_team_other_principal.clone(),
    );
    // The raw retry key can exist in another account/team's independent scope.
    let foreign = json!({"id":"foreign-driver","active":true});
    cache(
        &fixture.db,
        "foreign-driver",
        "affected-create-key",
        OTHER_TEAM,
        foreign.clone(),
    );
    let preview = fixture.server.preview(&token).await;
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM idempotency WHERE principal_id=?1",
            "cache-driver"
        ),
        0
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM idempotency WHERE principal_id='dispatcher' AND key LIKE ?1",
            "affected-%"
        ),
        0
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM deliveries WHERE id=?1",
            "reassigned-job"
        ),
        1
    );
    for (principal, key, expected) in [
        ("dispatcher", "retained-own-team-key", retained),
        (
            "configured-driver",
            "affected-create-key",
            same_team_other_principal,
        ),
        ("foreign-driver", "affected-create-key", foreign),
    ] {
        let body: String = fixture
            .db
            .query_row(
                "SELECT response FROM idempotency WHERE principal_id=?1 AND key=?2",
                params![principal, key],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(serde_json::from_str::<Value>(&body).unwrap(), expected);
    }
    let retired: Vec<String> = fixture
        .db
        .prepare("SELECT scope_hash FROM idempotency_retired")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(retired.len(), 2);
    assert!(retired.iter().all(|hash| hash.len() == 64
        && hash
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))));
    let columns: Vec<String> = fixture
        .db
        .prepare("PRAGMA table_info(idempotency_retired)")
        .unwrap()
        .query_map([], |r| r.get(1))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(columns, vec!["scope_hash"]);
}

#[tokio::test]
async fn invite_only_v4_upgrade_preserves_membership_and_sessions_before_hard_deletion() {
    let mut fixture = Fixture::new().await;
    fixture.seed_invited("upgrade-driver", TEAM);
    let token = fixture.server.token("upgrade-driver").await;
    delivery(
        &fixture.db,
        "upgrade-job",
        Some("upgrade-driver"),
        TEAM,
        "delivered",
    );
    fixture.server.close().await;
    // Reproduce the prior invite-only schema, which had no retired-key semantics.
    fixture
        .db
        .execute_batch("DROP TABLE idempotency_retired; PRAGMA user_version=4;")
        .unwrap();
    fixture.server = Server::start(&fixture.path, fixture.clock.clone()).await;
    let version: i64 = fixture
        .db
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        version, 8,
        "older invite-only binaries must fail their >4 startup guard"
    );
    assert_eq!(
        fixture.server.get("/v1/me", &token).await.status(),
        StatusCode::OK
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM accounts WHERE id=?1",
            "upgrade-driver"
        ),
        1
    );
    let preview = fixture.server.preview(&token).await;
    assert_eq!(preview["delivery_count"], 1);
    assert_eq!(
        fixture
            .server
            .delete(&token, PASSWORD, &preview)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM deliveries WHERE id=?1",
            "upgrade-job"
        ),
        0
    );
}

#[tokio::test]
async fn deletion_schema_missing_retry_metadata_fails_closed_without_recreating_it() {
    let mut fixture = Fixture::new().await;
    fixture.seed_invited("guard-driver", TEAM);
    fixture.server.close().await;
    fixture
        .db
        .execute_batch("DROP TABLE idempotency_retired;")
        .unwrap();
    let error =
        AppState::open_production_with_clock(&fixture.path, config(), fixture.clock.clone())
            .err()
            .expect("missing anti-replay metadata must prevent startup");
    assert_eq!(
        error,
        "Deletion retry metadata is missing; restore a verified backup"
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
            "idempotency_retired"
        ),
        0
    );
    assert_eq!(
        count(
            &fixture.db,
            "SELECT COUNT(*) FROM accounts WHERE id=?1",
            "guard-driver"
        ),
        1
    );
}
