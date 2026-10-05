//! Actual API HTTP + injected provider transport, with no paid external calls.
use arrivau_api::{
    app,
    model::Coordinate,
    places::{PlaceResolver, PlacesService, ResolveFuture, MAX_CACHE_SECONDS},
    AppState, Clock,
};
use reqwest::{Client, StatusCode};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering},
    Arc,
};

const NOW: i64 = 1_790_874_000;
struct TestClock(AtomicI64);
impl Clock for TestClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}
#[derive(Default)]
struct FakeProvider {
    calls: AtomicUsize,
    failed: AtomicBool,
}
impl PlaceResolver for FakeProvider {
    fn resolve<'a>(&'a self, _: &'a str) -> ResolveFuture<'a> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.failed.load(Ordering::SeqCst) {
                return Err("fake outage".into());
            }
            Ok(Coordinate {
                lat: 36.7163,
                lng: 15.0908,
            })
        })
    }
}

struct Server {
    base: String,
    client: Client,
    task: tokio::task::JoinHandle<()>,
}
impl Server {
    async fn new(state: AppState) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
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
    async fn post(
        &self,
        path: &str,
        token: &str,
        body: &Value,
        key: Option<&str>,
    ) -> reqwest::Response {
        let mut request = self
            .client
            .post(format!("{}{path}", self.base))
            .bearer_auth(token)
            .json(body);
        if let Some(key) = key {
            request = request.header("Idempotency-Key", key);
        }
        request.send().await.unwrap()
    }
    async fn get(&self, path: &str, token: &str) -> Value {
        let response = self
            .client
            .get(format!("{}{path}", self.base))
            .bearer_auth(token)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        response.json().await.unwrap()
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn new_delivery() -> Value {
    json!({"shop_name":"My restaurant","pickup_address":"My typed pickup","dropoff_address":"My typed dropoff",
        "pickup_google_place_id":"ChIJpickupFixture","dropoff_google_place_id":"ChIJdropoffFixture",
        "ready_at":NOW,"deadline_at":NOW+5000,"load_units":1,"max_ride_seconds":1800})
}

#[tokio::test]
async fn server_resolves_ids_and_never_persists_locations_in_deliveries_restaurants_or_retries() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("places.sqlite3");
    let clock = Arc::new(TestClock(AtomicI64::new(NOW)));
    let provider = Arc::new(FakeProvider::default());
    let state = AppState::open_with_clock(&path, true, clock.clone())
        .unwrap()
        .with_places(PlacesService::with_resolver(provider.clone()));
    let server = Server::new(state.clone()).await;
    let mut body = new_delivery();
    body["pickup"] = json!({"lat":1.0,"lng":2.0}); // Never trusted for Google.
    let response = server
        .post(
            "/v1/deliveries",
            "demo-dispatcher",
            &body,
            Some("google-create-key"),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let delivery: Value = response.json().await.unwrap();
    assert_eq!(delivery["pickup"], json!({"lat":36.7163,"lng":15.0908}));
    assert_eq!(delivery["pickup_coordinate_fetched_at"], NOW);
    assert_eq!(delivery["pickup_address"], "My typed pickup");
    assert_eq!(provider.calls.load(Ordering::SeqCst), 2);
    let restaurant = json!({"name":"User restaurant name","address":"User typed address","google_place_id":"ChIJpickupFixture"});
    assert_eq!(
        server
            .post(
                "/v1/restaurants",
                "demo-dispatcher",
                &restaurant,
                Some("restaurant-key")
            )
            .await
            .status(),
        StatusCode::CREATED
    );
    assert_eq!(
        provider.calls.load(Ordering::SeqCst),
        2,
        "same team/place reuses one memory cache entry"
    );
    let db = rusqlite::Connection::open(&path).unwrap();
    for (table, column) in [
        ("deliveries", "body"),
        ("restaurants", "body"),
        ("idempotency", "response"),
    ] {
        let mut statement = db
            .prepare(&format!("SELECT {column} FROM {table}"))
            .unwrap();
        for raw in statement
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
        {
            let raw = raw.unwrap();
            assert!(!raw.contains("36.7163"), "{table} leaked Google latitude");
            let record: Value = serde_json::from_str(&raw).unwrap();
            assert!(
                record["pickup"].is_null()
                    && record["dropoff"].is_null()
                    && record["coordinate"].is_null()
            );
        }
    }
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='google_place_cache'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    let calls = provider.calls.load(Ordering::SeqCst);
    let repeated: Value = server
        .post(
            "/v1/deliveries",
            "demo-dispatcher",
            &body,
            Some("google-create-key"),
        )
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(repeated, delivery);
    assert_eq!(provider.calls.load(Ordering::SeqCst), calls);
    // Same identifier in a different team must be independently resolved.
    assert_eq!(
        server
            .post("/v1/restaurants", "demo-dual", &restaurant, None)
            .await
            .status(),
        StatusCode::CREATED
    );
    assert_eq!(provider.calls.load(Ordering::SeqCst), calls + 1);
    // Replay after restart retains immutable outcome but cannot resurrect coords.
    drop(server);
    drop(state);
    let restarted = AppState::open_with_clock(&path, true, clock).unwrap();
    let server = Server::new(restarted).await;
    let replay = server
        .post(
            "/v1/deliveries",
            "demo-dispatcher",
            &body,
            Some("google-create-key"),
        )
        .await;
    assert_eq!(replay.status(), StatusCode::CREATED);
    let replay: Value = replay.json().await.unwrap();
    assert_eq!(replay["id"], delivery["id"]);
    assert_eq!(replay["pickup_google_place_id"], "ChIJpickupFixture");
    assert!(replay["pickup"].is_null() && replay["pickup_coordinate_fetched_at"].is_null());
}

#[tokio::test]
async fn expired_provider_outage_retains_ordered_stops_and_hides_all_timing() {
    let directory = tempfile::tempdir().unwrap();
    let clock = Arc::new(TestClock(AtomicI64::new(NOW)));
    let provider = Arc::new(FakeProvider::default());
    let state = AppState::open_with_clock(directory.path().join("route.db"), true, clock.clone())
        .unwrap()
        .with_places(PlacesService::with_resolver(provider.clone()));
    let server = Server::new(state.clone()).await;
    server
        .post(
            "/v1/shift",
            "demo-driver-1",
            &json!({"active":true,"capacity":2}),
            None,
        )
        .await
        .error_for_status()
        .unwrap();
    server
        .post(
            "/v1/location",
            "demo-driver-1",
            &json!({"lat":36.7163,"lng":15.0908}),
            None,
        )
        .await
        .error_for_status()
        .unwrap();
    let response = server
        .post("/v1/deliveries", "demo-dispatcher", &new_delivery(), None)
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let delivery: Value = response.json().await.unwrap();
    let id = delivery["id"].as_str().unwrap();
    assert_eq!(
        server
            .post(
                &format!("/v1/deliveries/{id}/assign"),
                "demo-dispatcher",
                &json!({"driver_id":"driver-1"}),
                None
            )
            .await
            .status(),
        StatusCode::OK
    );
    let before = server.get("/v1/route", "demo-driver-1").await;
    assert_eq!(before["estimates_available"], true);
    clock.0.store(NOW + MAX_CACHE_SECONDS, Ordering::SeqCst);
    provider.failed.store(true, Ordering::SeqCst);
    let expired = server.get("/v1/route", "demo-driver-1").await;
    assert_eq!(expired["estimates_available"], false);
    assert_eq!(expired["feasible"], false);
    assert_eq!(expired["stops"].as_array().unwrap().len(), 2);
    for (old, stop) in before["stops"]
        .as_array()
        .unwrap()
        .iter()
        .zip(expired["stops"].as_array().unwrap())
    {
        assert_eq!(old["delivery_id"], stop["delivery_id"]);
        assert_eq!(old["kind"], stop["kind"]);
        assert_eq!(old["google_place_id"], stop["google_place_id"]);
        assert!(stop["coordinate"].is_null() && stop["coordinate_fetched_at"].is_null());
    }
    provider.failed.store(false, Ordering::SeqCst);
    clock
        .0
        .store(NOW + MAX_CACHE_SECONDS + 31, Ordering::SeqCst);
    let refreshed = server.get("/v1/route", "demo-driver-1").await;
    assert_eq!(refreshed["estimates_available"], true);
    assert_eq!(
        refreshed["stops"][0]["coordinate_fetched_at"],
        NOW + MAX_CACHE_SECONDS + 31
    );
}

#[tokio::test]
async fn rejects_forged_freshness_and_fails_new_google_creation_without_provider() {
    let directory = tempfile::tempdir().unwrap();
    let state = AppState::open_with_clock(
        directory.path().join("disabled.db"),
        true,
        Arc::new(TestClock(AtomicI64::new(NOW))),
    )
    .unwrap();
    let server = Server::new(state).await;
    let mut body = new_delivery();
    body["pickup_coordinate_fetched_at"] = json!(NOW);
    assert_eq!(
        server
            .post("/v1/deliveries", "demo-dispatcher", &body, None)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    body.as_object_mut()
        .unwrap()
        .remove("pickup_coordinate_fetched_at");
    assert_eq!(
        server
            .post("/v1/deliveries", "demo-dispatcher", &body, None)
            .await
            .status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    // Legacy coordinate-only requests still work but can never enable Google nav.
    body.as_object_mut()
        .unwrap()
        .remove("pickup_google_place_id");
    body.as_object_mut()
        .unwrap()
        .remove("dropoff_google_place_id");
    body["pickup"] = json!({"lat":36.7,"lng":15.1});
    body["dropoff"] = json!({"lat":36.7,"lng":15.1});
    let response = server
        .post("/v1/deliveries", "demo-dispatcher", &body, None)
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let delivery: Value = response.json().await.unwrap();
    assert!(
        delivery["pickup_google_place_id"].is_null()
            && delivery["dropoff_google_place_id"].is_null()
    );
}

#[tokio::test]
async fn production_rejects_demo_place_identifiers_even_with_a_resolver_configured() {
    let directory = tempfile::tempdir().unwrap();
    let provider = Arc::new(FakeProvider::default());
    let password = "fixture-only-places-password";
    let hash = arrivau_api::auth::hash_password(password).unwrap();
    let config = serde_json::from_value(json!({
        "fleet_id":"places-test", "session_ttl_seconds":3600,
        "accounts":[{"id":"dispatch","username":"dispatch","name":"Test dispatcher","role":"dispatcher","password_hash":hash}]
    })).unwrap();
    let state = AppState::open_production_with_clock(
        directory.path().join("production.db"),
        config,
        Arc::new(TestClock(AtomicI64::new(NOW))),
    )
    .unwrap()
    .with_places(PlacesService::with_resolver(provider.clone()));
    let server = Server::new(state).await;
    let session: Value = server
        .post(
            "/v1/session",
            "",
            &json!({"username":"dispatch","password":password}),
            None,
        )
        .await
        .json()
        .await
        .unwrap();
    let token = session["token"].as_str().unwrap();
    let mut body = new_delivery();
    body["pickup_google_place_id"] = json!("arrivau-test-pachino-pickup");
    assert_eq!(
        server
            .post("/v1/deliveries", token, &body, None)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    assert_eq!(provider.calls.load(Ordering::SeqCst), 0);
}
