//! These tests use actual TCP listeners, HTTP JSON, and on-disk SQLite databases.
//! Time is injected so readiness, stale GPS, and expiry checks are deterministic.
use arrivau_api::{
    app,
    model::{Delivery, DeliveryStatus, Driver, ReadinessState, Route, Suggestion},
    AppState, Clock,
};
use reqwest::{Client, Method, Response, StatusCode};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc,
    },
};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};

const NOW: i64 = 1_790_874_000;
const DISPATCHER: &str = "demo-dispatcher";
const DRIVER_1: &str = "demo-driver-1";
const DRIVER_2: &str = "demo-driver-2";

struct TestClock(AtomicI64);
impl TestClock {
    fn new() -> Arc<Self> {
        Arc::new(Self(AtomicI64::new(NOW)))
    }
    fn advance(&self, seconds: i64) {
        self.0.fetch_add(seconds, Ordering::SeqCst);
    }
}
impl Clock for TestClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

struct Server {
    base: String,
    client: Client,
    task: JoinHandle<()>,
    dispatcher: JoinHandle<()>,
}
impl Server {
    async fn start(path: &Path, clock: Arc<TestClock>) -> Self {
        let state = AppState::open_with_clock(path, true, clock).unwrap();
        let dispatcher = state.spawn_dispatcher(std::time::Duration::from_millis(25));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app(state)).await.unwrap();
        });
        Self {
            base,
            client: Client::new(),
            task,
            dispatcher,
        }
    }
    async fn request(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> Response {
        let mut req = self
            .client
            .request(method, format!("{}{}", self.base, path));
        if let Some(token) = token {
            req = req.bearer_auth(token);
        }
        if let Some(body) = body {
            req = req.json(&body);
        }
        req.send().await.unwrap()
    }
    async fn get(&self, path: &str, token: &str) -> Response {
        self.request(Method::GET, path, Some(token), None).await
    }
    async fn post(&self, path: &str, token: &str, body: Value) -> Response {
        self.request(Method::POST, path, Some(token), Some(body))
            .await
    }
    async fn driver_online(&self, token: &str, capacity: i32) {
        assert_eq!(
            self.post(
                "/v1/shift",
                token,
                json!({"active":true,"capacity":capacity})
            )
            .await
            .status(),
            StatusCode::OK
        );
        assert_eq!(
            self.post("/v1/location", token, json!({"lat":36.7163,"lng":15.0908}))
                .await
                .status(),
            StatusCode::OK
        );
    }
    async fn create(&self, body: Value) -> Delivery {
        let response = self.post("/v1/deliveries", DISPATCHER, body).await;
        assert_eq!(response.status(), StatusCode::CREATED);
        response.json().await.unwrap()
    }
    async fn assign(&self, job: &Delivery, driver_id: &str) -> Response {
        self.post(
            &format!("/v1/deliveries/{}/assign", job.id),
            DISPATCHER,
            json!({"driver_id":driver_id}),
        )
        .await
    }
    async fn status(&self, job: &Delivery, token: &str, status: &str) -> Response {
        self.post(
            &format!("/v1/deliveries/{}/status", job.id),
            token,
            json!({"status":status}),
        )
        .await
    }
    async fn route(&self, token: &str) -> Route {
        self.get("/v1/route", token).await.json().await.unwrap()
    }
    async fn close(&mut self) {
        self.dispatcher.abort();
        self.task.abort();
        let _ = (&mut self.task).await;
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.dispatcher.abort();
        self.task.abort();
    }
}

fn new_job() -> Value {
    json!({
        "shop_name":"Pizzeria Pachino", "pickup_address":"Via Roma 1, Pachino",
        "pickup":{"lat":36.7163,"lng":15.0908},
        "dropoff_address":"Via Garibaldi 8, Pachino", "dropoff":{"lat":36.7170,"lng":15.0920},
        "ready_at":NOW, "deadline_at":NOW+3600, "load_units":1, "max_ride_seconds":1800
    })
}

fn unknown_job() -> Value {
    let mut input = new_job();
    input.as_object_mut().unwrap().remove("ready_at");
    input
}

impl Server {
    async fn readiness(&self, job: &Delivery, minutes: i64, revision: u64, key: &str) -> Response {
        self.client
            .post(format!("{}/v1/deliveries/{}/readiness", self.base, job.id))
            .bearer_auth(DISPATCHER)
            .header("Idempotency-Key", key)
            .json(&json!({"ready_in_minutes":minutes,"expected_revision":revision}))
            .send()
            .await
            .unwrap()
    }
    async fn listed_job(&self, id: &str) -> Delivery {
        self.get("/v1/deliveries", DISPATCHER)
            .await
            .json::<Vec<Delivery>>()
            .await
            .unwrap()
            .into_iter()
            .find(|job| job.id == id)
            .unwrap()
    }
}

#[tokio::test]
async fn unknown_creation_waits_for_readiness_then_assigns_without_driver_selection() {
    let dir = TempDir::new().unwrap();
    let clock = TestClock::new();
    let server = Server::start(&dir.path().join("ready.db"), clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    let job = server.create(unknown_job()).await;
    assert_eq!(job.readiness_state, ReadinessState::Unknown);
    assert!(job.readiness_at().is_none());
    clock.advance(120);
    tokio::time::sleep(std::time::Duration::from_millis(60)).await;
    assert_eq!(
        server.listed_job(&job.id).await.status,
        DeliveryStatus::Pending
    );
    assert!(server.route(DRIVER_1).await.stops.is_empty());
    error_is_json(server.assign(&job, "driver-1").await, StatusCode::CONFLICT).await;
    error_is_json(
        server
            .get(
                &format!("/v1/deliveries/{}/suggestions", job.id),
                DISPATCHER,
            )
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    let response = server.readiness(&job, 0, 0, "mark-ready-0001").await;
    assert_eq!(response.status(), StatusCode::OK);
    let ready: Delivery = response.json().await.unwrap();
    assert_eq!(ready.ready_at, NOW + 120);
    assert_eq!(ready.created_at, NOW);
    assert_eq!(ready.readiness_state, ReadinessState::Ready);
    assert_eq!(ready.status, DeliveryStatus::Assigned);
    assert_eq!(ready.driver_id.as_deref(), Some("driver-1"));
    assert_eq!(server.route(DRIVER_1).await.stops.len(), 2);
}

#[tokio::test]
async fn readiness_retries_keep_original_eta_and_reject_stale_edits() {
    let dir = TempDir::new().unwrap();
    let clock = TestClock::new();
    let server = Server::start(&dir.path().join("ready.db"), clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    let job = server.create(unknown_job()).await;
    let estimated: Delivery = server
        .readiness(&job, 2, 0, "estimate-0001")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(estimated.ready_at, NOW + 120);
    assert_eq!(estimated.status, DeliveryStatus::Pending);
    clock.advance(30);
    let replay: Delivery = server
        .readiness(&job, 2, 0, "estimate-0001")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(replay.ready_at, estimated.ready_at);
    assert_eq!(replay.readiness_revision, 1);
    error_is_json(
        server.readiness(&job, 0, 0, "stale-edit-0001").await,
        StatusCode::CONFLICT,
    )
    .await;
    error_is_json(
        server.readiness(&job, 3, 1, "estimate-0001").await,
        StatusCode::CONFLICT,
    )
    .await;
    let ready: Delivery = server
        .readiness(&job, 0, 1, "ready-now-0001")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(ready.ready_at, NOW + 30);
    assert_eq!(ready.status, DeliveryStatus::Assigned);
    clock.advance(10);
    let again: Delivery = server
        .readiness(&job, 0, 2, "ready-again-0001")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(again.ready_at, ready.ready_at);
    assert_eq!(again.readiness_revision, 2);
    assert_eq!(
        server.status(&job, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    error_is_json(
        server.readiness(&job, 5, 2, "after-pickup-0001").await,
        StatusCode::CONFLICT,
    )
    .await;
}

#[tokio::test]
async fn server_timer_assigns_future_readiness_without_foreground_client() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("ready.db");
    let clock = TestClock::new();
    let mut server = Server::start(&path, clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    let job = server.create(unknown_job()).await;
    let estimated: Delivery = server
        .readiness(&job, 1, 0, "future-ready-0001")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(estimated.status, DeliveryStatus::Pending);
    server.close().await;
    let server = Server::start(&path, clock.clone()).await;
    clock.advance(60);
    // No HTTP activity or app poll causes assignment: the server timer runs it.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let assigned = server.listed_job(&job.id).await;
    assert_eq!(assigned.status, DeliveryStatus::Assigned);
    assert_eq!(assigned.readiness_state, ReadinessState::Estimated);
    assert_eq!(assigned.ready_at, NOW + 60);
    assert_eq!(server.route(DRIVER_1).await.stops.len(), 2);
    assert_eq!(
        server.status(&job, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn ready_without_shift_waits_visibly_then_shift_start_assigns_even_without_gps() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("ready.db"), TestClock::new()).await;
    let job = server.create(unknown_job()).await;
    let waiting: Delivery = server
        .readiness(&job, 0, 0, "waiting-ready-01")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(waiting.status, DeliveryStatus::Pending);
    assert_eq!(
        waiting.dispatch_waiting_reason.as_deref(),
        Some("no_active_driver")
    );
    assert_eq!(
        server
            .post("/v1/shift", DRIVER_1, json!({"active":true,"capacity":1}))
            .await
            .status(),
        StatusCode::OK
    );
    let assigned = server.listed_job(&job.id).await;
    assert_eq!(assigned.status, DeliveryStatus::Assigned);
    assert!(assigned.dispatch_waiting_reason.is_none());
    let route = server.route(DRIVER_1).await;
    assert!(!route.estimates_available);
    assert!(!route.feasible);
    assert!(route
        .warnings
        .iter()
        .any(|warning| warning.contains("location is unavailable")));
    assert_eq!(route.stops.len(), 2);
    let picked: Delivery = server
        .status(&job, DRIVER_1, "picked_up")
        .await
        .json()
        .await
        .unwrap();
    assert!(
        picked.onboard_deadline_at.is_some(),
        "the explicitly confirmed pickup supplies a planning anchor without GPS"
    );
}

#[tokio::test]
async fn automatic_dispatch_assigns_late_work_and_queues_after_full_car_dropoff() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("ready.db"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 1).await;
    let onboard = server.create(new_job()).await;
    assert_eq!(
        server.assign(&onboard, "driver-1").await.status(),
        StatusCode::OK
    );
    let picked: Delivery = server
        .status(&onboard, DRIVER_1, "picked_up")
        .await
        .json()
        .await
        .unwrap();
    assert!(picked.onboard_deadline_at.is_some());
    let mut input = unknown_job();
    input["deadline_at"] = json!(NOW + 1);
    let job = server.create(input).await;
    let assigned: Delivery = server
        .readiness(&job, 0, 0, "late-ready-0001")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(assigned.status, DeliveryStatus::Assigned);
    let route = server.route(DRIVER_1).await;
    assert_eq!(route.stops[0].delivery_id, onboard.id);
    assert_eq!(route.stops[0].kind, arrivau_api::model::StopKind::Dropoff);
    assert!(!route.feasible);
    assert!(route
        .warnings
        .iter()
        .any(|warning| warning.contains("Deadline missed")));
    assert_eq!(
        server.listed_job(&onboard.id).await.onboard_deadline_at,
        picked.onboard_deadline_at
    );
}

#[tokio::test]
async fn concurrent_readiness_reports_have_one_winner_and_one_assignment() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("ready.db"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 2).await;
    let job = server.create(unknown_job()).await;
    let (a, b) = tokio::join!(
        server.readiness(&job, 0, 0, "race-ready-0001"),
        server.readiness(&job, 1, 0, "race-ready-0002")
    );
    assert!(
        (a.status() == StatusCode::OK && b.status() == StatusCode::CONFLICT)
            || (b.status() == StatusCode::OK && a.status() == StatusCode::CONFLICT)
    );
    let current = server.listed_job(&job.id).await;
    assert_eq!(current.readiness_revision, 1);
    let count = server.route(DRIVER_1).await.stops.len();
    assert_eq!(
        count,
        if current.status == DeliveryStatus::Assigned {
            2
        } else {
            0
        }
    );
}

#[tokio::test]
async fn pickup_guard_uses_acknowledged_stop_instead_of_the_old_gps_approach() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("anchor.db"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 2).await;
    let mut input = unknown_job();
    input["pickup"] = json!({"lat":36.8,"lng":15.0908});
    input["dropoff"] = input["pickup"].clone();
    let job = server.create(input).await;
    let assigned: Delivery = server
        .readiness(&job, 0, 0, "anchor-ready-01")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(assigned.status, DeliveryStatus::Assigned);
    let picked: Delivery = server
        .status(&job, DRIVER_1, "picked_up")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(picked.onboard_deadline_at, Some(NOW + 300));
    let driver: Driver = server
        .get("/v1/shift", DRIVER_1)
        .await
        .json()
        .await
        .unwrap();
    assert_ne!(
        driver.location, job.pickup,
        "pickup anchor is not a synthetic GPS upload"
    );
}
async fn error_is_json(response: Response, expected: StatusCode) {
    assert_eq!(response.status(), expected);
    assert!(response
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .starts_with("application/json"));
    let body: Value = response.json().await.unwrap();
    assert!(body["error"].as_str().is_some_and(|s| !s.is_empty()));
}

#[tokio::test]
async fn demo_gate_auth_roles_and_json_validation() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("fleet.sqlite3");
    assert!(AppState::open(&path, false).is_err());
    assert!(!path.exists(), "disabled demo must not create a database");
    let server = Server::start(&path, TestClock::new()).await;
    let health: Value = server
        .request(Method::GET, "/health", None, None)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(health, json!({"status":"ok"}));
    error_is_json(
        server.request(Method::GET, "/v1/me", None, None).await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    error_is_json(
        server.get("/v1/me", "wrong").await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    let me: Value = server.get("/v1/me", DISPATCHER).await.json().await.unwrap();
    assert_eq!(
        me,
        json!({"id":"dispatcher-1","name":"Dispatcher","role":"dispatcher","roles":["dispatcher"],"team_id":"demo","team_name":"Squadra demo"})
    );
    let me: Value = server.get("/v1/me", DRIVER_1).await.json().await.unwrap();
    assert_eq!(
        me,
        json!({"id":"driver-1","name":"Driver 1","role":"driver","roles":["driver"],"team_id":"demo","team_name":"Squadra demo"})
    );
    error_is_json(
        server.get("/v1/drivers", DRIVER_1).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error_is_json(
        server.get("/v1/shift", DISPATCHER).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error_is_json(
        server.get("/v1/drivers/driver-2/route", DRIVER_1).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error_is_json(
        server.post("/v1/deliveries", DRIVER_1, new_job()).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error_is_json(
        server
            .post("/v1/shift", DRIVER_1, json!({"active":true,"capacity":0}))
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error_is_json(
        server
            .post("/v1/location", DRIVER_1, json!({"lat":36.7,"lng":15.0}))
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    let malformed = server
        .client
        .post(format!("{}/v1/deliveries", server.base))
        .bearer_auth(DISPATCHER)
        .header("content-type", "application/json")
        .body("{")
        .send()
        .await
        .unwrap();
    error_is_json(malformed, StatusCode::BAD_REQUEST).await;
    let mut invalid = new_job();
    invalid["deadline_at"] = json!(NOW - 1);
    error_is_json(
        server.post("/v1/deliveries", DISPATCHER, invalid).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    let mut invalid = new_job();
    invalid["shop_name"] = json!("   ");
    error_is_json(
        server.post("/v1/deliveries", DISPATCHER, invalid).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    let mut invalid = new_job();
    invalid["pickup"]["lat"] = json!(91.0);
    error_is_json(
        server.post("/v1/deliveries", DISPATCHER, invalid).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    let mut invalid = new_job();
    invalid["max_ride_seconds"] = json!(59);
    error_is_json(
        server.post("/v1/deliveries", DISPATCHER, invalid).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error_is_json(
        server.get("/missing", DISPATCHER).await,
        StatusCode::NOT_FOUND,
    )
    .await;
}

#[tokio::test]
async fn full_dispatch_pickup_delivery_flow_survives_restart() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("fleet.sqlite3");
    let clock = TestClock::new();
    let mut server = Server::start(&path, clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    let job = server.create(new_job()).await;
    assert_eq!(
        server.assign(&job, "driver-1").await.status(),
        StatusCode::OK
    );
    let route = server.route(DRIVER_1).await;
    assert_eq!(route.stops.len(), 2);
    assert!(route.feasible);
    assert_eq!(
        server.status(&job, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    server.close().await;
    let mut server = Server::start(&path, clock.clone()).await;
    let shift: Driver = server
        .get("/v1/shift", DRIVER_1)
        .await
        .json()
        .await
        .unwrap();
    assert!(shift.active);
    assert_eq!(shift.capacity, 2);
    assert!(shift.location.is_some());
    assert_eq!(shift.location_updated_at, Some(NOW));
    let route = server.route(DRIVER_1).await;
    assert_eq!(route.stops.len(), 1);
    assert_eq!(route.stops[0].delivery_id, job.id);
    assert_eq!(
        serde_json::to_value(route.stops[0].kind).unwrap(),
        "dropoff"
    );
    clock.advance(30);
    let completed: Delivery = server
        .status(&job, DRIVER_1, "delivered")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(completed.picked_up_at, Some(NOW));
    assert_eq!(completed.delivered_at, Some(NOW + 30));
    assert!(server.route(DRIVER_1).await.stops.is_empty());
    assert_eq!(
        server
            .post("/v1/shift", DRIVER_1, json!({"active":false,"capacity":2}))
            .await
            .status(),
        StatusCode::OK
    );
    server.close().await;
    let server = Server::start(&path, clock).await;
    let shift: Driver = server
        .get("/v1/shift", DRIVER_1)
        .await
        .json()
        .await
        .unwrap();
    assert!(!shift.active);
    let jobs: Vec<Delivery> = server
        .get("/v1/deliveries", DISPATCHER)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(serde_json::to_value(jobs[0].status).unwrap(), "delivered");
}

#[tokio::test]
async fn ownership_and_state_transitions_are_enforced() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 2).await;
    server.driver_online(DRIVER_2, 2).await;
    let job = server.create(new_job()).await;
    assert_eq!(
        server.assign(&job, "driver-1").await.status(),
        StatusCode::OK
    );
    let other: Vec<Delivery> = server
        .get("/v1/deliveries", DRIVER_2)
        .await
        .json()
        .await
        .unwrap();
    assert!(other.is_empty());
    error_is_json(
        server.status(&job, DRIVER_2, "picked_up").await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error_is_json(
        server.status(&job, DISPATCHER, "picked_up").await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error_is_json(
        server.status(&job, DRIVER_1, "delivered").await,
        StatusCode::CONFLICT,
    )
    .await;
    error_is_json(
        server
            .post("/v1/shift", DRIVER_1, json!({"active":false,"capacity":2}))
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(
        server.status(&job, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    error_is_json(
        server.status(&job, DRIVER_1, "picked_up").await,
        StatusCode::CONFLICT,
    )
    .await;
    error_is_json(server.assign(&job, "driver-2").await, StatusCode::CONFLICT).await;
    assert_eq!(
        server.status(&job, DRIVER_1, "delivered").await.status(),
        StatusCode::OK
    );
    error_is_json(server.assign(&job, "driver-2").await, StatusCode::CONFLICT).await;
    error_is_json(
        server.status(&job, DRIVER_1, "delivered").await,
        StatusCode::CONFLICT,
    )
    .await;
}

#[tokio::test]
async fn readiness_and_suggested_next_stop_are_enforced() {
    let dir = TempDir::new().unwrap();
    let clock = TestClock::new();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), clock.clone()).await;
    server.driver_online(DRIVER_1, 1).await;
    let mut input = new_job();
    input["ready_at"] = json!(NOW + 60);
    let a = server.create(input.clone()).await;
    let b = server.create(input).await;
    assert_eq!(server.assign(&a, "driver-1").await.status(), StatusCode::OK);
    error_is_json(
        server.status(&a, DRIVER_1, "picked_up").await,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(server.assign(&b, "driver-1").await.status(), StatusCode::OK);
    let route = server.route(DRIVER_1).await;
    assert_eq!(route.stops.len(), 4);
    let (first, other) = if route.stops[0].delivery_id == a.id {
        (&a, &b)
    } else {
        (&b, &a)
    };
    clock.advance(60);
    error_is_json(
        server.status(other, DRIVER_1, "picked_up").await,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(
        server.status(first, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    error_is_json(
        server.status(other, DRIVER_1, "picked_up").await,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(
        server.status(first, DRIVER_1, "delivered").await.status(),
        StatusCode::OK
    );
    assert_eq!(
        server.status(other, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn suggestions_filter_infeasible_drivers_and_failed_assignment_is_atomic() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 2).await;
    server.driver_online(DRIVER_2, 1).await;
    let mut input = new_job();
    input["load_units"] = json!(2);
    let job = server.create(input).await;
    let suggestions: Vec<Suggestion> = server
        .get(
            &format!("/v1/deliveries/{}/suggestions", job.id),
            DISPATCHER,
        )
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(suggestions.len(), 1);
    assert_eq!(suggestions[0].driver_id, "driver-1");
    assert!(suggestions[0].route.feasible);
    error_is_json(
        server.assign(&job, "driver-2").await,
        StatusCode::UNPROCESSABLE_ENTITY,
    )
    .await;
    assert!(server.route(DRIVER_2).await.stops.is_empty());
    let jobs: Vec<Delivery> = server
        .get("/v1/deliveries", DISPATCHER)
        .await
        .json()
        .await
        .unwrap();
    assert!(jobs[0].driver_id.is_none());
    assert_eq!(
        server.assign(&job, "driver-1").await.status(),
        StatusCode::OK
    );
    let before = server.route(DRIVER_1).await;
    let mut impossible = new_job();
    impossible["deadline_at"] = json!(NOW + 30);
    let impossible = server.create(impossible).await;
    error_is_json(
        server.assign(&impossible, "driver-1").await,
        StatusCode::UNPROCESSABLE_ENTITY,
    )
    .await;
    let after = server.route(DRIVER_1).await;
    assert_eq!(
        serde_json::to_value(before).unwrap(),
        serde_json::to_value(after).unwrap()
    );
    error_is_json(
        server
            .post("/v1/shift", DRIVER_1, json!({"active":true,"capacity":1}))
            .await,
        StatusCode::UNPROCESSABLE_ENTITY,
    )
    .await;
    let shift: Driver = server
        .get("/v1/shift", DRIVER_1)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(shift.capacity, 2);
}

#[tokio::test]
async fn reassignment_moves_both_stops_atomically() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 2).await;
    server.driver_online(DRIVER_2, 2).await;
    let job = server.create(new_job()).await;
    assert_eq!(
        server.assign(&job, "driver-1").await.status(),
        StatusCode::OK
    );
    assert_eq!(
        server.assign(&job, "driver-2").await.status(),
        StatusCode::OK
    );
    assert!(server.route(DRIVER_1).await.stops.is_empty());
    assert_eq!(server.route(DRIVER_2).await.stops.len(), 2);
    let own: Vec<Delivery> = server
        .get("/v1/deliveries", DRIVER_1)
        .await
        .json()
        .await
        .unwrap();
    assert!(own.is_empty());
    let own: Vec<Delivery> = server
        .get("/v1/deliveries", DRIVER_2)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(own[0].id, job.id);
}

#[tokio::test]
async fn stale_location_and_elapsed_freshness_warn_without_hiding_work() {
    let dir = TempDir::new().unwrap();
    let clock = TestClock::new();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    let mut input = new_job();
    input["max_ride_seconds"] = json!(120);
    let job = server.create(input).await;
    assert_eq!(
        server.assign(&job, "driver-1").await.status(),
        StatusCode::OK
    );
    assert_eq!(
        server.status(&job, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    clock.advance(301);
    let route = server.route(DRIVER_1).await;
    assert!(!route.feasible);
    assert_eq!(route.stops.len(), 1);
    assert!(route
        .warnings
        .iter()
        .any(|s| s.contains("older than 5 minutes")));
    assert!(route.warnings.iter().any(|s| s.contains("ride time")));
    let pending = server.create(new_job()).await;
    let suggestions: Vec<Suggestion> = server
        .get(
            &format!("/v1/deliveries/{}/suggestions", pending.id),
            DISPATCHER,
        )
        .await
        .json()
        .await
        .unwrap();
    assert!(suggestions.is_empty());
    error_is_json(
        server.assign(&pending, "driver-1").await,
        StatusCode::CONFLICT,
    )
    .await;
    // Late real-world completion must still be recordable, even if an estimate is infeasible.
    assert_eq!(
        server.status(&job, DRIVER_1, "delivered").await.status(),
        StatusCode::OK
    );
    assert!(server.route(DRIVER_1).await.feasible);
}

#[tokio::test]
async fn concurrent_dispatches_keep_every_stop_and_assignment() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 2).await;
    let a = server.create(new_job()).await;
    let b = server.create(new_job()).await;
    let (a_result, b_result) =
        tokio::join!(server.assign(&a, "driver-1"), server.assign(&b, "driver-1"));
    assert_eq!(a_result.status(), StatusCode::OK);
    assert_eq!(b_result.status(), StatusCode::OK);
    let route = server.route(DRIVER_1).await;
    assert!(route.feasible);
    assert_eq!(route.stops.len(), 4);
    for id in [&a.id, &b.id] {
        assert_eq!(
            route.stops.iter().filter(|s| &s.delivery_id == id).count(),
            2
        );
    }
}

#[tokio::test]
async fn malformed_path_ids_have_uniform_json_errors() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), TestClock::new()).await;
    error_is_json(
        server.get("/v1/drivers/%FF/route", DISPATCHER).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error_is_json(
        server
            .get("/v1/deliveries/%FF/suggestions", DISPATCHER)
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error_is_json(
        server
            .post(
                "/v1/deliveries/%FF/assign",
                DISPATCHER,
                json!({"driver_id":"driver-1"}),
            )
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error_is_json(
        server
            .post(
                "/v1/deliveries/%FF/status",
                DRIVER_1,
                json!({"status":"picked_up"}),
            )
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
}

#[tokio::test]
async fn reassignment_cannot_introduce_a_freshness_violation_in_the_source_route() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("fleet.sqlite3");
    let server = Server::start(&path, TestClock::new()).await;
    server.driver_online(DRIVER_1, 3).await;
    server.driver_online(DRIVER_2, 3).await;
    let mut input = new_job();
    input["dropoff"] = input["pickup"].clone();
    let candidate = server.create(input.clone()).await;
    input["max_ride_seconds"] = json!(520);
    let x = server.create(input.clone()).await;
    input["max_ride_seconds"] = json!(1800);
    input["ready_at"] = json!(NOW + 500);
    let y = server.create(input).await;
    for job in [&candidate, &x, &y] {
        assert_eq!(
            server.assign(job, "driver-1").await.status(),
            StatusCode::OK
        );
    }
    // Install a valid but carefully ordered committed route to exercise the
    // removal counterexample independently of the insertion heuristic's choices.
    let mut db = rusqlite::Connection::open(&path).unwrap();
    let tx = db.transaction().unwrap();
    tx.execute("DELETE FROM route_stops WHERE driver_id = 'driver-1'", [])
        .unwrap();
    let keys = [
        (&candidate.id, "pickup"),
        (&x.id, "pickup"),
        (&candidate.id, "dropoff"),
        (&y.id, "pickup"),
        (&x.id, "dropoff"),
        (&y.id, "dropoff"),
    ];
    for (position, (id, kind)) in keys.iter().enumerate() {
        tx.execute("INSERT INTO route_stops(driver_id, position, delivery_id, kind) VALUES ('driver-1',?1,?2,?3)", rusqlite::params![position as i64,id,kind]).unwrap();
    }
    tx.commit().unwrap();
    drop(db);
    let before = server.route(DRIVER_1).await;
    assert!(before.feasible);
    assert_eq!(before.stops[1].arrival_at, NOW + 60);
    assert_eq!(before.stops[4].arrival_at, NOW + 560);
    error_is_json(
        server.assign(&candidate, "driver-2").await,
        StatusCode::UNPROCESSABLE_ENTITY,
    )
    .await;
    assert_eq!(
        serde_json::to_value(before).unwrap(),
        serde_json::to_value(server.route(DRIVER_1).await).unwrap()
    );
    assert!(server.route(DRIVER_2).await.stops.is_empty());
    let suggestions: Vec<Suggestion> = server
        .get(
            &format!("/v1/deliveries/{}/suggestions", candidate.id),
            DISPATCHER,
        )
        .await
        .json()
        .await
        .unwrap();
    assert!(suggestions
        .iter()
        .all(|suggestion| suggestion.driver_id != "driver-2"));
}

#[tokio::test]
async fn reassignment_can_recover_work_from_a_stale_driver() {
    let dir = TempDir::new().unwrap();
    let clock = TestClock::new();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    server.driver_online(DRIVER_2, 2).await;
    let a = server.create(new_job()).await;
    let b = server.create(new_job()).await;
    assert_eq!(server.assign(&a, "driver-1").await.status(), StatusCode::OK);
    assert_eq!(server.assign(&b, "driver-1").await.status(), StatusCode::OK);
    clock.advance(301);
    server.driver_online(DRIVER_2, 2).await;
    assert!(!server.route(DRIVER_1).await.feasible);
    let suggestions: Vec<Suggestion> = server
        .get(&format!("/v1/deliveries/{}/suggestions", a.id), DISPATCHER)
        .await
        .json()
        .await
        .unwrap();
    assert!(suggestions.iter().any(|s| s.driver_id == "driver-2"));
    assert_eq!(server.assign(&a, "driver-2").await.status(), StatusCode::OK);
    assert_eq!(server.route(DRIVER_1).await.stops.len(), 2);
    assert_eq!(server.assign(&b, "driver-2").await.status(), StatusCode::OK);
    assert!(server.route(DRIVER_1).await.stops.is_empty());
    assert_eq!(server.route(DRIVER_2).await.stops.len(), 4);
}

#[tokio::test]
async fn route_stop_limit_counts_the_resulting_pair_even_with_odd_stop_counts() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("fleet.sqlite3"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 1).await;
    let mut jobs = Vec::new();
    for _ in 0..16 {
        let mut input = new_job();
        input["dropoff"] = input["pickup"].clone();
        let job = server.create(input).await;
        assert_eq!(
            server.assign(&job, "driver-1").await.status(),
            StatusCode::OK
        );
        jobs.push(job);
    }
    let full = server.route(DRIVER_1).await;
    assert_eq!(full.stops.len(), 32);
    let first = jobs
        .iter()
        .find(|job| job.id == full.stops[0].delivery_id)
        .unwrap();
    assert_eq!(
        server.status(first, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    let before = server.route(DRIVER_1).await;
    assert_eq!(before.stops.len(), 31);
    let extra = server.create(new_job()).await;
    error_is_json(
        server.assign(&extra, "driver-1").await,
        StatusCode::UNPROCESSABLE_ENTITY,
    )
    .await;
    let choices: Vec<Suggestion> = server
        .get(
            &format!("/v1/deliveries/{}/suggestions", extra.id),
            DISPATCHER,
        )
        .await
        .json()
        .await
        .unwrap();
    assert!(choices.is_empty());
    assert_eq!(
        serde_json::to_value(before).unwrap(),
        serde_json::to_value(server.route(DRIVER_1).await).unwrap()
    );
}

#[tokio::test]
async fn idempotent_mutations_survive_restart_and_cannot_change_request_or_owner() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("retry.sqlite3");
    let clock = TestClock::new();
    let mut server = Server::start(&path, clock.clone()).await;
    server.driver_online(DRIVER_1, 2).await;
    async fn keyed(server: &Server, path: &str, token: &str, key: &str, body: Value) -> Response {
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
    let first: Value = keyed(
        &server,
        "/v1/deliveries",
        DISPATCHER,
        "create-test-1234",
        new_job(),
    )
    .await
    .json()
    .await
    .unwrap();
    let replay: Value = keyed(
        &server,
        "/v1/deliveries",
        DISPATCHER,
        "create-test-1234",
        new_job(),
    )
    .await
    .json()
    .await
    .unwrap();
    assert_eq!(first, replay);
    let job: Delivery = serde_json::from_value(first.clone()).unwrap();
    let mut changed = new_job();
    changed["shop_name"] = json!("different body");
    error_is_json(
        keyed(
            &server,
            "/v1/deliveries",
            DISPATCHER,
            "create-test-1234",
            changed,
        )
        .await,
        StatusCode::CONFLICT,
    )
    .await;
    error_is_json(
        keyed(
            &server,
            "/v1/deliveries",
            DRIVER_1,
            "create-test-1234",
            new_job(),
        )
        .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    let assign_path = format!("/v1/deliveries/{}/assign", job.id);
    let body = json!({"driver_id":"driver-1"});
    error_is_json(
        keyed(
            &server,
            &assign_path,
            DISPATCHER,
            "create-test-1234",
            body.clone(),
        )
        .await,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(
        keyed(
            &server,
            &assign_path,
            DISPATCHER,
            "assign-test-1234",
            body.clone()
        )
        .await
        .status(),
        StatusCode::OK
    );
    assert_eq!(
        keyed(&server, &assign_path, DISPATCHER, "assign-test-1234", body)
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(server.route(DRIVER_1).await.stops.len(), 2);
    let status_path = format!("/v1/deliveries/{}/status", job.id);
    let pickup = json!({"status":"picked_up"});
    let picked: Value = keyed(
        &server,
        &status_path,
        DRIVER_1,
        "pickup-test-1234",
        pickup.clone(),
    )
    .await
    .json()
    .await
    .unwrap();
    server.close().await;
    let server = Server::start(&path, clock).await;
    let retry: Value = keyed(
        &server,
        &status_path,
        DRIVER_1,
        "pickup-test-1234",
        pickup.clone(),
    )
    .await
    .json()
    .await
    .unwrap();
    assert_eq!(picked, retry);
    assert_eq!(server.route(DRIVER_1).await.stops.len(), 1);
    error_is_json(
        keyed(
            &server,
            &status_path,
            DRIVER_2,
            "pickup-test-1234",
            pickup.clone(),
        )
        .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    assert_eq!(
        keyed(
            &server,
            &status_path,
            DRIVER_1,
            "dropoff-test-1234",
            json!({"status":"delivered"})
        )
        .await
        .status(),
        StatusCode::OK
    );
    let late: Value = keyed(&server, &status_path, DRIVER_1, "pickup-test-1234", pickup)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(
        late, picked,
        "replay returns original response, without rolling back delivery"
    );
    assert!(server.route(DRIVER_1).await.stops.is_empty());
    let replay: Value = keyed(
        &server,
        "/v1/deliveries",
        DISPATCHER,
        "create-test-1234",
        new_job(),
    )
    .await
    .json()
    .await
    .unwrap();
    assert_eq!(replay, first);
    let jobs: Vec<Delivery> = server
        .get("/v1/deliveries", DISPATCHER)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(serde_json::to_value(jobs[0].status).unwrap(), "delivered");
    error_is_json(
        keyed(&server, "/v1/deliveries", DISPATCHER, "bad", new_job()).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
}

#[tokio::test]
async fn dispatcher_can_delete_every_delivery_state_and_retry_without_resurrection() {
    for target in ["pending", "assigned", "picked_up", "delivered"] {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("delete.db");
        let clock = TestClock::new();
        let mut server = Server::start(&path, clock.clone()).await;
        let input = new_job();
        let response = server
            .client
            .post(format!("{}/v1/deliveries", server.base))
            .bearer_auth(DISPATCHER)
            .header("Idempotency-Key", "delete-create-fixture")
            .json(&input)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        let job: Delivery = response.json().await.unwrap();
        if target != "pending" {
            server.driver_online(DRIVER_1, 3).await;
            assert_eq!(server.assign(&job, "driver-1").await.status(), StatusCode::OK);
        }
        if target == "picked_up" || target == "delivered" {
            assert_eq!(
                server.status(&job, DRIVER_1, "picked_up").await.status(),
                StatusCode::OK
            );
        }
        if target == "delivered" {
            assert_eq!(
                server.status(&job, DRIVER_1, "delivered").await.status(),
                StatusCode::OK
            );
        }
        let endpoint = format!("/v1/deliveries/{}", job.id);
        assert_eq!(
            server
                .request(Method::DELETE, &endpoint, None, None)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            server
                .request(Method::DELETE, &endpoint, Some(DRIVER_1), None)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
        for _ in 0..2 {
            assert_eq!(
                server
                    .request(Method::DELETE, &endpoint, Some(DISPATCHER), None)
                    .await
                    .status(),
                StatusCode::NO_CONTENT
            );
        }
        let jobs: Vec<Delivery> = server
            .get("/v1/deliveries", DISPATCHER)
            .await
            .json()
            .await
            .unwrap();
        assert!(jobs.is_empty());
        assert!(server.route(DRIVER_1).await.stops.is_empty());
        let retry = server
            .client
            .post(format!("{}/v1/deliveries", server.base))
            .bearer_auth(DISPATCHER)
            .header("Idempotency-Key", "delete-create-fixture")
            .json(&input)
            .send()
            .await
            .unwrap();
        assert_eq!(retry.status(), StatusCode::CONFLICT);
        // Hard deletion and the retired key must survive process restart.
        server.close().await;
        let restarted = Server::start(&path, clock).await;
        let jobs: Vec<Delivery> = restarted
            .get("/v1/deliveries", DISPATCHER)
            .await
            .json()
            .await
            .unwrap();
        assert!(jobs.is_empty());
        let db = rusqlite::Connection::open(&path).unwrap();
        let saved: i64 = db
            .query_row("SELECT COUNT(*) FROM idempotency", [], |r| r.get(0))
            .unwrap();
        assert_eq!(saved, 0);
        let retired: i64 = db
            .query_row("SELECT COUNT(*) FROM idempotency_retired", [], |r| r.get(0))
            .unwrap();
        assert_eq!(retired, 1);
    }
}

#[tokio::test]
async fn deleting_assigned_work_keeps_remaining_route_order_and_execution() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("delete-route.db"), TestClock::new()).await;
    server.driver_online(DRIVER_1, 3).await;
    let removed = server.create(new_job()).await;
    assert_eq!(
        server.assign(&removed, "driver-1").await.status(),
        StatusCode::OK
    );
    let kept = server.create(new_job()).await;
    assert_eq!(server.assign(&kept, "driver-1").await.status(), StatusCode::OK);
    let before = server.route(DRIVER_1).await;
    assert_eq!(
        server
            .request(
                Method::DELETE,
                &format!("/v1/deliveries/{}", removed.id),
                Some(DISPATCHER),
                None,
            )
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    let after = server.route(DRIVER_1).await;
    let expected: Vec<_> = before
        .stops
        .iter()
        .filter(|s| s.delivery_id != removed.id)
        .map(|s| (&s.delivery_id, s.kind))
        .collect();
    let actual: Vec<_> = after
        .stops
        .iter()
        .map(|s| (&s.delivery_id, s.kind))
        .collect();
    assert_eq!(actual, expected);
    assert_eq!(after.stops.len(), 2);
    assert_eq!(
        server.status(&kept, DRIVER_1, "picked_up").await.status(),
        StatusCode::OK
    );
    assert_eq!(
        server.status(&kept, DRIVER_1, "delivered").await.status(),
        StatusCode::OK
    );
}
