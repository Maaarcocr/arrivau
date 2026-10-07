//! End-to-end team/capability boundaries using ephemeral HTTP servers and SQLite.
//! Every password in this file is an explicit, test-only fixture.
use arrivau_api::{
    app,
    auth::{hash_password, ProductionConfig},
    AppState, Clock,
};
use reqwest::{Client, Method, Response, StatusCode};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Arc, OnceLock},
};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};

const NOW: i64 = 1_790_874_000;
const PASSWORD: &str = "team-boundary-test-only-password";
const RED: &str = "red-team";
const BLUE: &str = "blue-team";

struct TestClock;
impl Clock for TestClock {
    fn now(&self) -> i64 {
        NOW
    }
}

fn config_json() -> Value {
    static HASH: OnceLock<String> = OnceLock::new();
    let hash = HASH.get_or_init(|| hash_password(PASSWORD).unwrap());
    json!({
        "fleet_id": RED,
        "session_ttl_seconds": 3600,
        "teams": [
            {"id":RED,"name":"Red delivery team"},
            {"id":BLUE,"name":"Blue delivery team"}
        ],
        "accounts": [
            {"id":"red-dispatch","username":"red-dispatch","name":"Red dispatcher fixture","role":"dispatcher","password_hash":hash},
            {"id":"red-driver","username":"red-driver","name":"Red driver fixture","role":"driver","password_hash":hash},
            {"id":"red-peer","username":"red-peer","name":"Red peer fixture","role":"driver","team_id":RED,"password_hash":hash},
            {"id":"red-dual","username":"red-dual","name":"Red dual fixture","roles":["dispatcher","driver"],"team_id":RED,"password_hash":hash},
            {"id":"blue-dispatch","username":"blue-dispatch","name":"Blue dispatcher fixture","role":"dispatcher","team_id":BLUE,"password_hash":hash},
            {"id":"blue-driver","username":"blue-driver","name":"Blue driver fixture","role":"driver","team_id":BLUE,"password_hash":hash}
        ]
    })
}

fn config(value: Value) -> ProductionConfig {
    serde_json::from_value(value).expect("valid test configuration schema")
}

struct Server {
    base: String,
    client: Client,
    task: JoinHandle<()>,
}
impl Server {
    async fn start(path: &Path, value: Value) -> Self {
        let state = AppState::open_production_with_clock(path, config(value), Arc::new(TestClock))
            .expect("valid test production server");
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

    async fn request(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
        key: Option<&str>,
    ) -> Response {
        let mut request = self
            .client
            .request(method, format!("{}{}", self.base, path));
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        if let Some(key) = key {
            request = request.header("Idempotency-Key", key);
        }
        request.send().await.unwrap()
    }

    async fn login(&self, username: &str) -> Response {
        self.request(
            Method::POST,
            "/v1/session",
            None,
            Some(json!({"username":username,"password":PASSWORD})),
            None,
        )
        .await
    }

    async fn token(&self, username: &str) -> String {
        let session = json_response(self.login(username).await, StatusCode::CREATED).await;
        assert_eq!(session["expires_at"], NOW + 3600);
        session["token"].as_str().unwrap().to_owned()
    }

    async fn get(&self, path: &str, token: &str) -> Response {
        self.request(Method::GET, path, Some(token), None, None)
            .await
    }

    async fn get_json(&self, path: &str, token: &str) -> Value {
        json_response(self.get(path, token).await, StatusCode::OK).await
    }

    async fn post(&self, path: &str, token: &str, body: Value, key: Option<&str>) -> Response {
        self.request(Method::POST, path, Some(token), Some(body), key)
            .await
    }

    async fn online(&self, token: &str, expected_id: &str) {
        let shift = json_response(
            self.post(
                "/v1/shift",
                token,
                json!({"active":true,"capacity":3}),
                None,
            )
            .await,
            StatusCode::OK,
        )
        .await;
        assert_eq!(shift["id"], expected_id);
        let location = json_response(
            self.post("/v1/location", token, point(), None).await,
            StatusCode::OK,
        )
        .await;
        assert_eq!(location["id"], expected_id);
        assert_eq!(location["location"], point());
        assert_eq!(location["location_updated_at"], NOW);
    }

    async fn create(&self, token: &str, body: Value, key: Option<&str>) -> Value {
        json_response(
            self.post("/v1/deliveries", token, body, key).await,
            StatusCode::CREATED,
        )
        .await
    }

    async fn assign(&self, token: &str, job: &Value, driver: &str, key: Option<&str>) -> Response {
        self.post(
            &job_path(job, "assign"),
            token,
            json!({"driver_id":driver}),
            key,
        )
        .await
    }

    async fn status(&self, token: &str, job: &Value, status: &str, key: Option<&str>) -> Response {
        self.post(
            &job_path(job, "status"),
            token,
            json!({"status":status}),
            key,
        )
        .await
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

fn point() -> Value {
    json!({"lat":36.7163,"lng":15.0908})
}
fn job_input(name: &str) -> Value {
    json!({
        "shop_name":name,"pickup_address":"Fixture pickup address","pickup":point(),
        "dropoff_address":"Fixture dropoff address","dropoff":{"lat":36.7170,"lng":15.0920},
        "ready_at":NOW,"deadline_at":NOW+3600,"load_units":1,"max_ride_seconds":1800
    })
}

#[tokio::test]
async fn restaurants_are_private_idempotent_and_resolve_immutable_pickup_snapshots() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("restaurants.db");
    let mut server = Server::start(&path, config_json()).await;
    let red = server.token("red-dispatch").await;
    let blue = server.token("blue-dispatch").await;
    let driver = server.token("red-driver").await;
    let input =
        json!({"name":"Pizzeria salvata","address":"Via del ristorante 5","coordinate":point()});
    error(
        server.get("/v1/restaurants", &driver).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server
            .post("/v1/restaurants", &driver, input.clone(), None)
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    let restaurant = json_response(
        server
            .post(
                "/v1/restaurants",
                &red,
                input.clone(),
                Some("restaurant-create-01"),
            )
            .await,
        StatusCode::CREATED,
    )
    .await;
    assert_eq!(server.get_json("/v1/restaurants", &blue).await, json!([]));
    assert_eq!(
        server.get_json("/v1/restaurants", &red).await,
        json!([restaurant.clone()])
    );
    let mut draft = job_input("Untrusted name");
    draft.as_object_mut().unwrap().remove("ready_at");
    draft["restaurant_id"] = restaurant["id"].clone();
    draft["pickup_address"] = json!("Untrusted address");
    draft["pickup"] = json!({"lat":0,"lng":0});
    error(
        server
            .post("/v1/deliveries", &blue, draft.clone(), None)
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    let created = server
        .create(&red, draft.clone(), Some("restaurant-order-01"))
        .await;
    assert_eq!(created["shop_name"], restaurant["name"]);
    assert_eq!(created["pickup_address"], restaurant["address"]);
    assert_eq!(created["pickup"], restaurant["coordinate"]);
    assert_eq!(created["restaurant_id"], restaurant["id"]);
    assert_eq!(created["readiness_state"], "unknown");
    let mut invalid = input.clone();
    invalid["coordinate"]["lat"] = json!(999);
    error(
        server.post("/v1/restaurants", &red, invalid, None).await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    let mut changed = input.clone();
    changed["name"] = json!("Different restaurant");
    error(
        server
            .post(
                "/v1/restaurants",
                &red,
                changed,
                Some("restaurant-create-01"),
            )
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    server.close().await;
    let server = Server::start(&path, config_json()).await;
    let replay = json_response(
        server
            .post("/v1/restaurants", &red, input, Some("restaurant-create-01"))
            .await,
        StatusCode::CREATED,
    )
    .await;
    assert_eq!(replay, restaurant);
    let repeated = server
        .create(&red, draft, Some("restaurant-order-01"))
        .await;
    assert_eq!(repeated, created);
    assert_eq!(
        server
            .get_json("/v1/restaurants", &red)
            .await
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn readiness_enforces_team_capability_schema_and_revocation_before_replay() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("readiness-auth.db");
    let mut server = Server::start(&path, config_json()).await;
    let red = server.token("red-dispatch").await;
    let blue = server.token("blue-dispatch").await;
    let driver = server.token("red-driver").await;
    let dual = server.token("red-dual").await;
    let mut input = job_input("Readiness fixture");
    input.as_object_mut().unwrap().remove("ready_at");
    let job = server.create(&red, input, None).await;
    let path_action = job_path(&job, "readiness");
    let ready = json!({"ready_in_minutes":0,"expected_revision":0});
    error(
        server
            .request(Method::POST, &path_action, None, Some(ready.clone()), None)
            .await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    error(
        server
            .post(&path_action, &driver, ready.clone(), None)
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server.post(&path_action, &blue, ready.clone(), None).await,
        StatusCode::NOT_FOUND,
    )
    .await;
    error(
        server
            .post(
                "/v1/deliveries/nonexistent/readiness",
                &red,
                ready.clone(),
                None,
            )
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    for invalid in [
        json!({"ready_in_minutes":-1,"expected_revision":0}),
        json!({"ready_in_minutes":121,"expected_revision":0}),
        json!({"ready_in_minutes":0}),
        json!({"ready_in_minutes":0,"expected_revision":0,"team_id":BLUE}),
    ] {
        error(
            server.post(&path_action, &red, invalid, None).await,
            StatusCode::BAD_REQUEST,
        )
        .await;
    }
    let saved = json_response(
        server
            .post(
                &path_action,
                &dual,
                ready.clone(),
                Some("readiness-auth-01"),
            )
            .await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(saved["readiness_state"], "ready");
    assert_eq!(saved["status"], "pending");
    error(
        server
            .post(
                &path_action,
                &blue,
                ready.clone(),
                Some("readiness-auth-01"),
            )
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    server.close().await;
    let mut reduced = config_json();
    for account in reduced["accounts"].as_array_mut().unwrap() {
        if account["id"] == "red-dual" {
            account["roles"] = json!(["driver"]);
        }
    }
    let server = Server::start(&path, reduced).await;
    error(
        server
            .post(
                &path_action,
                &dual,
                ready.clone(),
                Some("readiness-auth-01"),
            )
            .await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    let new_driver = server.token("red-dual").await;
    error(
        server
            .post(&path_action, &new_driver, ready, Some("readiness-auth-01"))
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
}
fn job_id(job: &Value) -> &str {
    job["id"].as_str().unwrap()
}
fn job_path(job: &Value, action: &str) -> String {
    format!("/v1/deliveries/{}/{action}", job_id(job))
}
async fn json_response(response: Response, expected: StatusCode) -> Value {
    let status = response.status();
    let no_store = response
        .headers()
        .get("cache-control")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let body = response.text().await.unwrap();
    assert_eq!(status, expected, "unexpected response body: {body}");
    assert_eq!(no_store.as_deref(), Some("no-store"));
    serde_json::from_str(&body).expect("JSON response")
}
async fn error(response: Response, expected: StatusCode) {
    let body = json_response(response, expected).await;
    assert!(body["error"].as_str().is_some_and(|text| !text.is_empty()));
}
fn assert_ids(list: &Value, expected: &[&str]) {
    let mut actual: Vec<&str> = list
        .as_array()
        .expect("array response")
        .iter()
        .map(job_id)
        .collect();
    let mut expected = expected.to_vec();
    actual.sort_unstable();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}
fn assert_role_set(user: &Value, expected: &[&str]) {
    let mut actual: Vec<&str> = user["roles"]
        .as_array()
        .expect("capability array")
        .iter()
        .map(|role| role.as_str().unwrap())
        .collect();
    let mut expected = expected.to_vec();
    actual.sort_unstable();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}
fn assert_route_jobs(route: &Value, driver: &str, expected: &[&str]) {
    assert_eq!(route["driver_id"], driver);
    let mut actual: Vec<&str> = route["stops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|stop| stop["delivery_id"].as_str().unwrap())
        .collect();
    let mut expected = expected.to_vec();
    actual.sort_unstable();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}

#[tokio::test]
async fn principals_expose_authoritative_team_and_capabilities_without_role_selection() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("teams.db"), config_json()).await;
    for (username, team, team_name, primary, roles) in [
        (
            "red-dispatch",
            RED,
            "Red delivery team",
            "dispatcher",
            vec!["dispatcher", "driver"],
        ),
        (
            "red-driver",
            RED,
            "Red delivery team",
            "driver",
            vec!["driver"],
        ),
        (
            "red-dual",
            RED,
            "Red delivery team",
            "dispatcher",
            vec!["dispatcher", "driver"],
        ),
        (
            "blue-driver",
            BLUE,
            "Blue delivery team",
            "driver",
            vec!["driver"],
        ),
    ] {
        let session = json_response(server.login(username).await, StatusCode::CREATED).await;
        let token = session["token"].as_str().unwrap();
        let user = &session["user"];
        assert_eq!(user["id"], username);
        assert_eq!(user["team_id"], team);
        assert_eq!(user["team_name"], team_name);
        assert_eq!(user["role"], primary);
        assert_role_set(user, &roles);
        assert_eq!(server.get_json("/v1/me", token).await, *user);
        let restored = server.get_json("/v1/session", token).await;
        assert_eq!(restored["user"], *user);
        assert_eq!(restored["expires_at"], NOW + 3600);
    }
    for extra in [
        json!({"team_id":BLUE}),
        json!({"roles":["dispatcher","driver"]}),
        json!({"role":"dispatcher"}),
    ] {
        let mut body = json!({"username":"red-driver","password":PASSWORD});
        body.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        error(
            server
                .request(Method::POST, "/v1/session", None, Some(body), None)
                .await,
            StatusCode::BAD_REQUEST,
        )
        .await;
    }
}

#[tokio::test]
async fn team_reads_and_foreign_id_mutations_are_isolated_in_both_directions() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(&dir.path().join("teams.db"), config_json()).await;
    let red_dispatch = server.token("red-dispatch").await;
    let red_driver = server.token("red-driver").await;
    let red_peer = server.token("red-peer").await;
    let red_dual = server.token("red-dual").await;
    let blue_dispatch = server.token("blue-dispatch").await;
    let blue_driver = server.token("blue-driver").await;
    for (token, id) in [
        (&red_driver, "red-driver"),
        (&red_dual, "red-dual"),
        (&blue_driver, "blue-driver"),
    ] {
        server.online(token, id).await;
    }
    let red_job = server
        .create(&red_dispatch, job_input("Red private shop"), None)
        .await;
    let red_pending = server
        .create(&red_dispatch, job_input("Red pending shop"), None)
        .await;
    let blue_job = server
        .create(&blue_dispatch, job_input("Blue private shop"), None)
        .await;
    let blue_pending = server
        .create(&blue_dispatch, job_input("Blue pending shop"), None)
        .await;
    json_response(
        server
            .assign(&red_dispatch, &red_job, "red-driver", None)
            .await,
        StatusCode::OK,
    )
    .await;
    json_response(
        server
            .assign(&blue_dispatch, &blue_job, "blue-driver", None)
            .await,
        StatusCode::OK,
    )
    .await;

    assert_ids(
        &server.get_json("/v1/drivers", &red_dispatch).await,
        &["red-dispatch", "red-driver", "red-peer", "red-dual"],
    );
    assert_ids(
        &server.get_json("/v1/drivers", &blue_dispatch).await,
        &["blue-dispatch", "blue-driver"],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &red_dispatch).await,
        &[job_id(&red_job), job_id(&red_pending)],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &red_dual).await,
        &[job_id(&red_job), job_id(&red_pending)],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &red_driver).await,
        &[job_id(&red_job)],
    );
    assert_ids(&server.get_json("/v1/deliveries", &red_peer).await, &[]);
    assert_ids(
        &server.get_json("/v1/deliveries", &blue_dispatch).await,
        &[job_id(&blue_job), job_id(&blue_pending)],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &blue_driver).await,
        &[job_id(&blue_job)],
    );
    // Unrecognized client team selectors cannot override the authenticated principal.
    assert_ids(
        &server
            .get_json("/v1/deliveries?team_id=blue-team", &red_dispatch)
            .await,
        &[job_id(&red_job), job_id(&red_pending)],
    );
    assert_ids(
        &server
            .get_json("/v1/drivers?team_id=red-team", &blue_dispatch)
            .await,
        &["blue-dispatch", "blue-driver"],
    );

    for (dispatch, driver, own_id, foreign_id, own, pending, foreign) in [
        (
            &red_dispatch,
            &red_driver,
            "red-driver",
            "blue-driver",
            &red_job,
            &red_pending,
            &blue_job,
        ),
        (
            &blue_dispatch,
            &blue_driver,
            "blue-driver",
            "red-driver",
            &blue_job,
            &blue_pending,
            &red_job,
        ),
    ] {
        let route = server.get_json("/v1/route", driver).await;
        assert_route_jobs(&route, own_id, &[job_id(own), job_id(own)]);
        assert_eq!(
            server
                .get_json(&format!("/v1/drivers/{own_id}/route"), dispatch)
                .await,
            route
        );
        error(
            server
                .get(&format!("/v1/drivers/{foreign_id}/route"), dispatch)
                .await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server
                .get(&job_path(foreign, "suggestions"), dispatch)
                .await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server.assign(dispatch, foreign, own_id, None).await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server.assign(dispatch, pending, foreign_id, None).await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server.status(driver, foreign, "picked_up", None).await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server.status(driver, foreign, "delivered", None).await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server
                .get("/v1/drivers/no-such-driver/route", dispatch)
                .await,
            StatusCode::NOT_FOUND,
        )
        .await;
        error(
            server
                .get("/v1/deliveries/no-such-delivery/suggestions", dispatch)
                .await,
            StatusCode::NOT_FOUND,
        )
        .await;
        assert_eq!(
            server.get_json("/v1/route", driver).await,
            route,
            "foreign mutations must be atomic failures"
        );
        let choices = server
            .get_json(&job_path(pending, "suggestions"), dispatch)
            .await;
        let allowed = if own_id == "red-driver" {
            vec!["red-driver", "red-dual"]
        } else {
            vec!["blue-driver"]
        };
        let mut actual = Vec::new();
        for choice in choices.as_array().unwrap() {
            let choice_id = choice["driver_id"].as_str().unwrap();
            actual.push(choice_id);
            assert_eq!(choice["route"]["driver_id"], choice_id);
            for stop in choice["route"]["stops"].as_array().unwrap() {
                let id = stop["delivery_id"].as_str().unwrap();
                assert!(
                    id == job_id(own) || id == job_id(pending),
                    "suggestion leaked another team's stop"
                );
            }
        }
        actual.sort_unstable();
        let mut allowed = allowed;
        allowed.sort_unstable();
        assert_eq!(actual, allowed);
    }
    error(
        server.status(&red_peer, &red_job, "picked_up", None).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server.status(&red_dual, &red_job, "picked_up", None).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server.get("/v1/drivers", &red_driver).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    assert_route_jobs(
        &server.get_json("/v1/route", &red_dispatch).await,
        "red-dispatch",
        &[],
    );
    error(
        server
            .post("/v1/deliveries", &red_driver, job_input("Forbidden"), None)
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    let pending = server.get_json("/v1/deliveries", &red_dispatch).await;
    assert_eq!(
        pending
            .as_array()
            .unwrap()
            .iter()
            .find(|job| job_id(job) == job_id(&red_pending))
            .unwrap()["status"],
        "pending"
    );
}

#[tokio::test]
async fn dual_account_can_dispatch_and_complete_only_its_own_driver_route() {
    let dir = TempDir::new().unwrap();
    let mut configuration = config_json();
    // Legacy primary presentation remains driver, but both capabilities apply.
    configuration["accounts"][3]["role"] = json!("driver");
    let server = Server::start(&dir.path().join("teams.db"), configuration).await;
    let dual = server.token("red-dual").await;
    let principal = server.get_json("/v1/me", &dual).await;
    assert_eq!(principal["role"], "driver");
    assert_role_set(&principal, &["dispatcher", "driver"]);
    let peer = server.token("red-driver").await;
    server.online(&dual, "red-dual").await;
    server.online(&peer, "red-driver").await;
    let own = server
        .create(
            &dual,
            job_input("Dual self delivery"),
            Some("dual-create-0001"),
        )
        .await;
    let other = server
        .create(&dual, job_input("Dual dispatched delivery"), None)
        .await;
    json_response(
        server
            .assign(&dual, &own, "red-dual", Some("dual-assign-0001"))
            .await,
        StatusCode::OK,
    )
    .await;
    json_response(
        server.assign(&dual, &other, "red-driver", None).await,
        StatusCode::OK,
    )
    .await;
    assert_ids(
        &server.get_json("/v1/deliveries", &dual).await,
        &[job_id(&own), job_id(&other)],
    );
    assert_route_jobs(
        &server.get_json("/v1/route", &dual).await,
        "red-dual",
        &[job_id(&own), job_id(&own)],
    );
    assert_route_jobs(
        &server.get_json("/v1/drivers/red-driver/route", &dual).await,
        "red-driver",
        &[job_id(&other), job_id(&other)],
    );
    error(
        server.status(&dual, &other, "picked_up", None).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server.status(&peer, &own, "picked_up", None).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server
            .post(
                "/v1/shift",
                &dual,
                json!({"active":false,"capacity":3}),
                None,
            )
            .await,
        StatusCode::CONFLICT,
    )
    .await;

    // Driver mutation bodies never accept selectors, even for a dual account.
    for (path, body) in [
        (
            "/v1/shift",
            json!({"active":false,"capacity":3,"driver_id":"red-driver"}),
        ),
        (
            "/v1/shift",
            json!({"active":false,"capacity":3,"team_id":BLUE}),
        ),
        (
            "/v1/location",
            json!({"lat":0,"lng":0,"driver_id":"blue-driver"}),
        ),
        ("/v1/location", json!({"lat":0,"lng":0,"team_id":BLUE})),
    ] {
        error(
            server.post(path, &dual, body, None).await,
            StatusCode::BAD_REQUEST,
        )
        .await;
    }
    let mut forged_create = job_input("Cannot choose target team");
    forged_create["team_id"] = json!(BLUE);
    error(
        server
            .post("/v1/deliveries", &dual, forged_create, None)
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error(
        server
            .post(
                &job_path(&own, "assign"),
                &dual,
                json!({"driver_id":"red-dual","team_id":BLUE}),
                None,
            )
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    error(
        server
            .post(
                &job_path(&own, "status"),
                &dual,
                json!({"status":"picked_up","team_id":BLUE}),
                None,
            )
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    let picked = json_response(
        server
            .status(&dual, &own, "picked_up", Some("dual-pickup-0001"))
            .await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(picked["status"], "picked_up");
    assert_eq!(picked["picked_up_at"], NOW);
    assert_route_jobs(
        &server.get_json("/v1/route", &dual).await,
        "red-dual",
        &[job_id(&own)],
    );
    let completed = json_response(
        server
            .status(&dual, &own, "delivered", Some("dual-deliver-0001"))
            .await,
        StatusCode::OK,
    )
    .await;
    assert_eq!(completed["status"], "delivered");
    assert_eq!(completed["delivered_at"], NOW);
    assert_route_jobs(&server.get_json("/v1/route", &dual).await, "red-dual", &[]);
    assert_eq!(
        json_response(
            server
                .status(&dual, &own, "picked_up", Some("dual-pickup-0001"))
                .await,
            StatusCode::OK
        )
        .await,
        picked
    );
    assert_eq!(
        json_response(
            server
                .status(&dual, &own, "delivered", Some("dual-deliver-0001"))
                .await,
            StatusCode::OK
        )
        .await,
        completed
    );
    json_response(
        server
            .post(
                "/v1/shift",
                &dual,
                json!({"active":false,"capacity":3}),
                None,
            )
            .await,
        StatusCode::OK,
    )
    .await;
    let own_shift = server.get_json("/v1/shift", &dual).await;
    assert_eq!(own_shift["id"], "red-dual");
    assert_eq!(own_shift["active"], false);
    let peer_shift = server.get_json("/v1/shift", &peer).await;
    assert_eq!(peer_shift["active"], true);
    assert_eq!(peer_shift["location"], point());
    assert_route_jobs(
        &server.get_json("/v1/route", &peer).await,
        "red-driver",
        &[job_id(&other), job_id(&other)],
    );
}

#[tokio::test]
async fn idempotency_is_team_and_account_scoped_and_durable_after_new_login() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("teams.db");
    let mut server = Server::start(&path, config_json()).await;
    let red = server.token("red-dispatch").await;
    let blue = server.token("blue-dispatch").await;
    let dual = server.token("red-dual").await;
    let red_driver = server.token("red-driver").await;
    let blue_driver = server.token("blue-driver").await;
    server.online(&red_driver, "red-driver").await;
    server.online(&blue_driver, "blue-driver").await;
    let body = job_input("Identical body in independent scopes");
    let red_job = server
        .create(&red, body.clone(), Some("shared-create-key"))
        .await;
    let blue_job = server
        .create(&blue, body.clone(), Some("shared-create-key"))
        .await;
    let dual_job = server
        .create(&dual, body.clone(), Some("shared-create-key"))
        .await;
    assert_ne!(red_job["id"], blue_job["id"]);
    assert_ne!(red_job["id"], dual_job["id"]);
    assert_ne!(blue_job["id"], dual_job["id"]);
    let red_assignment = json_response(
        server
            .assign(&red, &red_job, "red-driver", Some("shared-assign-key"))
            .await,
        StatusCode::OK,
    )
    .await;
    let blue_assignment = json_response(
        server
            .assign(&blue, &blue_job, "blue-driver", Some("shared-assign-key"))
            .await,
        StatusCode::OK,
    )
    .await;
    let red_pickup = json_response(
        server
            .status(
                &red_driver,
                &red_job,
                "picked_up",
                Some("shared-pickup-key"),
            )
            .await,
        StatusCode::OK,
    )
    .await;
    let blue_pickup = json_response(
        server
            .status(
                &blue_driver,
                &blue_job,
                "picked_up",
                Some("shared-pickup-key"),
            )
            .await,
        StatusCode::OK,
    )
    .await;
    let red_completed = json_response(
        server
            .status(
                &red_driver,
                &red_job,
                "delivered",
                Some("shared-deliver-key"),
            )
            .await,
        StatusCode::OK,
    )
    .await;
    let blue_completed = json_response(
        server
            .status(
                &blue_driver,
                &blue_job,
                "delivered",
                Some("shared-deliver-key"),
            )
            .await,
        StatusCode::OK,
    )
    .await;
    error(
        server
            .post(
                "/v1/deliveries",
                &red,
                job_input("Changed request"),
                Some("shared-create-key"),
            )
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    error(
        server
            .assign(&red, &dual_job, "red-driver", Some("shared-assign-key"))
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    error(
        server
            .assign(&red, &dual_job, "red-driver", Some("shared-create-key"))
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    error(
        server
            .status(
                &red_driver,
                &red_job,
                "delivered",
                Some("shared-pickup-key"),
            )
            .await,
        StatusCode::CONFLICT,
    )
    .await;
    // A key known to exist in the caller's own scope cannot reveal another team's payload.
    error(
        server
            .assign(&red, &blue_job, "red-driver", Some("shared-assign-key"))
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    error(
        server
            .assign(&blue, &red_job, "blue-driver", Some("shared-assign-key"))
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    error(
        server
            .assign(&red, &red_job, "blue-driver", Some("shared-assign-key"))
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    error(
        server
            .status(
                &red_driver,
                &blue_job,
                "picked_up",
                Some("shared-pickup-key"),
            )
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    error(
        server
            .status(
                &blue_driver,
                &red_job,
                "picked_up",
                Some("shared-pickup-key"),
            )
            .await,
        StatusCode::NOT_FOUND,
    )
    .await;
    error(
        server
            .post(
                "/v1/deliveries",
                &red_driver,
                body.clone(),
                Some("shared-create-key"),
            )
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server
            .post("/v1/deliveries", &red, body.clone(), Some("bad key!"))
            .await,
        StatusCode::BAD_REQUEST,
    )
    .await;
    server.close().await;

    let server = Server::start(&path, config_json()).await;
    for token in [&red, &blue, &dual, &red_driver, &blue_driver] {
        json_response(server.get("/v1/session", token).await, StatusCode::OK).await;
    }
    let red_new = server.token("red-dispatch").await;
    let blue_new = server.token("blue-dispatch").await;
    let dual_new = server.token("red-dual").await;
    let red_driver_new = server.token("red-driver").await;
    let blue_driver_new = server.token("blue-driver").await;
    for (token, original) in [
        (&red_new, &red_job),
        (&blue_new, &blue_job),
        (&dual_new, &dual_job),
    ] {
        assert_eq!(
            server
                .create(token, body.clone(), Some("shared-create-key"))
                .await,
            *original
        );
    }
    for (dispatch, driver, driver_id, job, assignment, pickup, completed) in [
        (
            &red_new,
            &red_driver_new,
            "red-driver",
            &red_job,
            &red_assignment,
            &red_pickup,
            &red_completed,
        ),
        (
            &blue_new,
            &blue_driver_new,
            "blue-driver",
            &blue_job,
            &blue_assignment,
            &blue_pickup,
            &blue_completed,
        ),
    ] {
        assert_eq!(
            json_response(
                server
                    .assign(dispatch, job, driver_id, Some("shared-assign-key"))
                    .await,
                StatusCode::OK
            )
            .await,
            *assignment
        );
        assert_eq!(
            json_response(
                server
                    .status(driver, job, "picked_up", Some("shared-pickup-key"))
                    .await,
                StatusCode::OK
            )
            .await,
            *pickup
        );
        assert_eq!(
            json_response(
                server
                    .status(driver, job, "delivered", Some("shared-deliver-key"))
                    .await,
                StatusCode::OK
            )
            .await,
            *completed
        );
        assert_route_jobs(&server.get_json("/v1/route", driver).await, driver_id, &[]);
        let jobs = server.get_json("/v1/deliveries", driver).await;
        assert_ids(&jobs, &[job_id(job)]);
        assert_eq!(
            jobs[0], *completed,
            "replays must not roll domain state back"
        );
    }
    assert_ids(
        &server.get_json("/v1/deliveries", &red_new).await,
        &[job_id(&red_job), job_id(&dual_job)],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &blue_new).await,
        &[job_id(&blue_job)],
    );
}

#[tokio::test]
async fn removing_accounts_revokes_sessions_and_preserves_work_for_reassignment() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("teams.db");
    let mut server = Server::start(&path, config_json()).await;
    let red = server.token("red-dispatch").await;
    let blue = server.token("blue-dispatch").await;
    let removed = server.token("red-driver").await;
    let dual = server.token("red-dual").await;
    server.online(&removed, "red-driver").await;
    server.online(&dual, "red-dual").await;
    let outstanding = server
        .create(&red, job_input("Removed driver recovery"), None)
        .await;
    let dual_work = server
        .create(&red, job_input("Capability change recovery"), None)
        .await;
    json_response(
        server.assign(&red, &outstanding, "red-driver", None).await,
        StatusCode::OK,
    )
    .await;
    json_response(
        server.assign(&red, &dual_work, "red-dual", None).await,
        StatusCode::OK,
    )
    .await;
    server.close().await;
    let mut changed = config_json();
    let accounts = changed["accounts"].as_array_mut().unwrap();
    accounts.retain(|account| account["id"] != "red-driver" && account["id"] != "red-dual");
    let server = Server::start(&path, changed).await;
    for token in [&red, &blue] {
        json_response(server.get("/v1/me", token).await, StatusCode::OK).await;
    }
    for token in [&removed, &dual] {
        error(server.get("/v1/me", token).await, StatusCode::UNAUTHORIZED).await;
        error(
            server.get("/v1/route", token).await,
            StatusCode::UNAUTHORIZED,
        )
        .await;
    }
    error(server.login("red-driver").await, StatusCode::UNAUTHORIZED).await;
    error(server.login("red-dual").await, StatusCode::UNAUTHORIZED).await;
    let pending = server
        .create(&red, job_input("Dispatcher capability retained"), None)
        .await;
    for driver_id in ["red-driver", "red-dual"] {
        let drivers = server.get_json("/v1/drivers", &red).await;
        let historical = drivers
            .as_array()
            .unwrap()
            .iter()
            .find(|driver| driver["id"] == driver_id)
            .unwrap();
        assert_eq!(historical["active"], false);
        error(
            server.assign(&red, &pending, driver_id, None).await,
            StatusCode::CONFLICT,
        )
        .await;
        error(
            server
                .get(&format!("/v1/drivers/{driver_id}/route"), &blue)
                .await,
            StatusCode::NOT_FOUND,
        )
        .await;
    }
    assert_route_jobs(
        &server.get_json("/v1/drivers/red-driver/route", &red).await,
        "red-driver",
        &[job_id(&outstanding), job_id(&outstanding)],
    );
    assert_route_jobs(
        &server.get_json("/v1/drivers/red-dual/route", &red).await,
        "red-dual",
        &[job_id(&dual_work), job_id(&dual_work)],
    );
    assert_eq!(
        server
            .get_json(&job_path(&pending, "suggestions"), &red)
            .await,
        json!([])
    );
    let peer = server.token("red-peer").await;
    server.online(&peer, "red-peer").await;
    json_response(
        server.assign(&red, &outstanding, "red-peer", None).await,
        StatusCode::OK,
    )
    .await;
    json_response(
        server.assign(&red, &dual_work, "red-peer", None).await,
        StatusCode::OK,
    )
    .await;
    assert_route_jobs(
        &server.get_json("/v1/drivers/red-driver/route", &red).await,
        "red-driver",
        &[],
    );
    assert_route_jobs(
        &server.get_json("/v1/drivers/red-dual/route", &red).await,
        "red-dual",
        &[],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &peer).await,
        &[job_id(&outstanding), job_id(&dual_work)],
    );
}

#[tokio::test]
async fn losing_dispatcher_capability_preserves_driving_but_blocks_old_write_replays() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("teams.db");
    let mut server = Server::start(&path, config_json()).await;
    let dispatcher = server.token("red-dispatch").await;
    let dual = server.token("red-dual").await;
    server.online(&dual, "red-dual").await;
    let body = job_input("Driver retains assigned work");
    let own = server
        .create(&dual, body.clone(), Some("downgrade-create"))
        .await;
    let other = server
        .create(&dispatcher, job_input("Team-only dispatch work"), None)
        .await;
    json_response(
        server
            .assign(&dual, &own, "red-dual", Some("downgrade-assign"))
            .await,
        StatusCode::OK,
    )
    .await;
    server.close().await;
    let mut changed = config_json();
    changed["accounts"][3]["roles"] = json!(["driver"]);
    let server = Server::start(&path, changed).await;
    error(server.get("/v1/me", &dual).await, StatusCode::UNAUTHORIZED).await;
    let driver = server.token("red-dual").await;
    let principal = server.get_json("/v1/me", &driver).await;
    assert_role_set(&principal, &["driver"]);
    assert_eq!(principal["role"], "driver");
    assert_eq!(server.get_json("/v1/shift", &driver).await["active"], true);
    assert_ids(
        &server.get_json("/v1/deliveries", &driver).await,
        &[job_id(&own)],
    );
    assert_ids(
        &server.get_json("/v1/deliveries", &dispatcher).await,
        &[job_id(&own), job_id(&other)],
    );
    assert_route_jobs(
        &server.get_json("/v1/route", &driver).await,
        "red-dual",
        &[job_id(&own), job_id(&own)],
    );
    error(
        server.get("/v1/drivers", &driver).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server.get(&job_path(&own, "suggestions"), &driver).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server.get("/v1/drivers/red-dual/route", &driver).await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server
            .post("/v1/deliveries", &driver, body, Some("downgrade-create"))
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    error(
        server
            .assign(&driver, &own, "red-dual", Some("downgrade-assign"))
            .await,
        StatusCode::FORBIDDEN,
    )
    .await;
    json_response(
        server.status(&driver, &own, "picked_up", None).await,
        StatusCode::OK,
    )
    .await;
    json_response(
        server.status(&driver, &own, "delivered", None).await,
        StatusCode::OK,
    )
    .await;
    assert_route_jobs(
        &server.get_json("/v1/route", &driver).await,
        "red-dual",
        &[],
    );
}

#[tokio::test]
async fn stable_account_ids_cannot_move_teams_even_after_removal() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("teams.db");
    let mut server = Server::start(&path, config_json()).await;
    let original = server.token("red-driver").await;
    server.close().await;
    let mut moved = config_json();
    moved["accounts"][1]["team_id"] = json!(BLUE);
    assert!(AppState::open_production_with_clock(
        &path,
        config(moved.clone()),
        Arc::new(TestClock)
    )
    .is_err());
    let mut server = Server::start(&path, config_json()).await;
    assert_eq!(server.get_json("/v1/me", &original).await["team_id"], RED);
    server.close().await;
    let mut removed = config_json();
    removed["accounts"]
        .as_array_mut()
        .unwrap()
        .retain(|account| account["id"] != "red-driver");
    let mut server = Server::start(&path, removed).await;
    error(
        server.get("/v1/me", &original).await,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    server.close().await;
    assert!(
        AppState::open_production_with_clock(&path, config(moved), Arc::new(TestClock)).is_err()
    );
    let server = Server::start(&path, config_json()).await;
    let restored = server.token("red-driver").await;
    assert_eq!(server.get_json("/v1/me", &restored).await["team_id"], RED);
}

#[tokio::test]
async fn legacy_single_team_config_defaults_and_sessions_survive_unchanged_restart() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("legacy-config.db");
    let mut legacy = config_json();
    legacy.as_object_mut().unwrap().remove("teams");
    legacy["accounts"].as_array_mut().unwrap().truncate(2);
    let mut server = Server::start(&path, legacy.clone()).await;
    let dispatcher = server.token("red-dispatch").await;
    let driver = server.token("red-driver").await;
    let before = server.get_json("/v1/me", &driver).await;
    assert_eq!(before["team_id"], RED);
    assert!(before["team_name"]
        .as_str()
        .is_some_and(|name| !name.is_empty()));
    assert_role_set(&before, &["driver"]);
    server.close().await;
    let server = Server::start(&path, legacy).await;
    assert_eq!(server.get_json("/v1/me", &driver).await, before);
    assert_ids(
        &server.get_json("/v1/drivers", &dispatcher).await,
        &["red-dispatch", "red-driver"],
    );
}

#[test]
fn invalid_team_references_and_capabilities_fail_closed() {
    let valid = config_json();
    config(valid.clone()).validate().unwrap();
    let mut invalid_cases = Vec::new();
    let mut unknown_team = valid.clone();
    unknown_team["accounts"][1]["team_id"] = json!("unconfigured-team");
    invalid_cases.push(unknown_team);
    let mut missing_default = valid.clone();
    missing_default["teams"].as_array_mut().unwrap().remove(0);
    invalid_cases.push(missing_default);
    let mut duplicate_team = valid.clone();
    duplicate_team["teams"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":RED,"name":"Duplicate"}));
    invalid_cases.push(duplicate_team);
    let mut unknown_role = valid.clone();
    unknown_role["accounts"][3]["roles"] = json!(["dispatcher", "admin"]);
    invalid_cases.push(unknown_role);
    let mut no_roles = valid.clone();
    no_roles["accounts"][3]["roles"] = json!([]);
    invalid_cases.push(no_roles);
    let mut blank_team = valid.clone();
    blank_team["teams"][0]["name"] = json!(" ");
    invalid_cases.push(blank_team);
    let mut duplicate_account = valid;
    duplicate_account["accounts"][5]["id"] = json!("red-driver");
    invalid_cases.push(duplicate_account);
    for (index, invalid) in invalid_cases.into_iter().enumerate() {
        match serde_json::from_value::<ProductionConfig>(invalid) {
            Ok(config) => assert!(
                config.validate().is_err(),
                "invalid configuration {index} was accepted"
            ),
            Err(_) => continue,
        }
    }
}
