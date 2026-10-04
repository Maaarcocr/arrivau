pub mod auth;
mod db;
mod error;
pub mod model;
pub mod planner;

use axum::{
    extract::{
        rejection::{JsonRejection, PathRejection},
        DefaultBodyLimit, Path, Request, State,
    },
    http::{HeaderMap, StatusCode},
    middleware::{self, Next},
    response::Response,
    routing::{get, post},
    Extension, Json, Router,
};
use error::{ApiError, ApiResult};
use model::*;
use rand_core::{OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    path::Path as FsPath,
    sync::{Arc, Mutex, MutexGuard},
    time::{SystemTime, UNIX_EPOCH},
};

pub trait Clock: Send + Sync {
    fn now(&self) -> i64;
}

struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }
}

#[derive(Clone)]
pub struct AppState {
    db: Arc<Mutex<Connection>>,
    clock: Arc<dyn Clock>,
    authentication: Arc<Authentication>,
    auth_workers: Arc<tokio::sync::Semaphore>,
}

enum Authentication {
    Demo,
    Production(auth::ProductionConfig),
}

impl AppState {
    pub fn open(path: impl AsRef<FsPath>, demo_enabled: bool) -> Result<Self, String> {
        Self::open_with_clock(path, demo_enabled, Arc::new(SystemClock))
    }

    pub fn open_with_clock(
        path: impl AsRef<FsPath>,
        demo_enabled: bool,
        clock: Arc<dyn Clock>,
    ) -> Result<Self, String> {
        if !demo_enabled {
            return Err("Explicit demo opt-in is required; use open_production for configured pilot authentication".into());
        }
        let db = db::open(path, "demo", "demo", &[]).map_err(|e| e.message)?;
        Ok(Self {
            db: Arc::new(Mutex::new(db)),
            clock,
            authentication: Arc::new(Authentication::Demo),
            auth_workers: Arc::new(tokio::sync::Semaphore::new(2)),
        })
    }

    pub fn open_production(
        path: impl AsRef<FsPath>,
        config: auth::ProductionConfig,
    ) -> Result<Self, String> {
        Self::open_production_with_clock(path, config, Arc::new(SystemClock))
    }

    pub fn open_production_with_clock(
        path: impl AsRef<FsPath>,
        config: auth::ProductionConfig,
        clock: Arc<dyn Clock>,
    ) -> Result<Self, String> {
        config.validate()?;
        if !path.as_ref().is_absolute() {
            return Err("Production requires an absolute persistent database path".into());
        }
        let mut db = db::open(
            path,
            &format!("production:{}", config.fleet_id),
            &config.fleet_id,
            &config
                .accounts
                .iter()
                .map(|a| (a.id.as_str(), a.team_id(&config)))
                .collect::<Vec<_>>(),
        )
        .map_err(|e| e.message)?;
        auth::initialize(&mut db, &config).map_err(|e| e.message)?;
        Ok(Self {
            db: Arc::new(Mutex::new(db)),
            clock,
            authentication: Arc::new(Authentication::Production(config)),
            auth_workers: Arc::new(tokio::sync::Semaphore::new(2)),
        })
    }

    fn db(&self) -> ApiResult<MutexGuard<'_, Connection>> {
        self.db
            .lock()
            .map_err(|_| ApiError::internal("Database lock poisoned"))
    }
}

#[derive(Debug, Clone, Serialize)]
struct Principal {
    id: String,
    name: String,
    role: String,
    roles: Vec<String>,
    team_id: String,
    team_name: String,
}
impl Principal {
    fn has_role(&self, role: &str) -> bool {
        self.roles.iter().any(|r| r == role)
    }
    fn require(&self, role: &str) -> ApiResult<()> {
        if self.has_role(role) {
            Ok(())
        } else {
            Err(ApiError::new(
                StatusCode::FORBIDDEN,
                format!("{role} role required"),
            ))
        }
    }
}

async fn authenticate(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> ApiResult<Response> {
    let token = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(auth::unauthorized)?;
    let session = match state.authentication.as_ref() {
        Authentication::Demo => {
            let (id, name, role, team_id, team_name, roles) = match token {
                "demo-dispatcher" => (
                    "dispatcher-1",
                    "Dispatcher",
                    "dispatcher",
                    "demo",
                    "Squadra demo",
                    vec!["dispatcher".into()],
                ),
                "demo-driver-1" => (
                    "driver-1",
                    "Driver 1",
                    "driver",
                    "demo",
                    "Squadra demo",
                    vec!["driver".into()],
                ),
                "demo-driver-2" => (
                    "driver-2",
                    "Driver 2",
                    "driver",
                    "demo",
                    "Squadra demo",
                    vec!["driver".into()],
                ),
                "demo-dual" => (
                    "dual-1",
                    "Revisione Apple",
                    "dispatcher",
                    "demo-review",
                    "Squadra revisione",
                    vec!["dispatcher".into(), "driver".into()],
                ),
                _ => return Err(auth::unauthorized()),
            };
            auth::Session {
                principal: Principal {
                    id: id.into(),
                    name: name.into(),
                    role: role.into(),
                    roles,
                    team_id: team_id.into(),
                    team_name: team_name.into(),
                },
                expires_at: None,
                token_hash: None,
            }
        }
        Authentication::Production(config) => {
            auth::session(&*state.db()?, config, token, state.clock.now())?
        }
    };
    request.extensions_mut().insert(session.principal.clone());
    request.extensions_mut().insert(session);
    Ok(next.run(request).await)
}

fn path_id(path: Result<Path<String>, PathRejection>) -> ApiResult<String> {
    path.map(|Path(id)| id)
        .map_err(|_| ApiError::bad_request("Path must contain a valid UTF-8 identifier"))
}

fn json_body<T>(body: Result<Json<T>, JsonRejection>) -> ApiResult<T> {
    body.map(|Json(value)| value).map_err(|rejection| {
        // Do not expose framework-specific plain-text errors or input values.
        let message = if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
            "JSON body exceeds the 16 KiB limit"
        } else {
            "Request must contain valid JSON matching the endpoint schema"
        };
        ApiError::bad_request(message)
    })
}

pub fn app(state: AppState) -> Router {
    let v1 = Router::new()
        .route("/me", get(me))
        .route("/session", get(session_identity).delete(logout))
        .route("/drivers", get(list_drivers))
        .route("/shift", get(get_shift).post(shift))
        .route("/location", post(location))
        .route("/deliveries", get(list_deliveries).post(create_delivery))
        .route("/deliveries/{id}/assign", post(assign))
        .route("/deliveries/{id}/status", post(status))
        .route("/deliveries/{id}/suggestions", get(suggestions))
        .route("/route", get(own_route))
        .route("/drivers/{id}/route", get(driver_route))
        .route_layer(middleware::from_fn_with_state(state.clone(), authenticate));
    Router::new()
        .route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "ok"})) }),
        )
        .route("/v1/session", post(login))
        .nest("/v1", v1)
        .fallback(|| async { ApiError::not_found("Endpoint not found") })
        .method_not_allowed_fallback(|| async {
            ApiError::new(StatusCode::METHOD_NOT_ALLOWED, "Method not allowed")
        })
        .layer(DefaultBodyLimit::max(16 * 1024))
        .layer(middleware::from_fn(
            |request: Request, next: Next| async move {
                let mut response = next.run(request).await;
                response
                    .headers_mut()
                    .insert("cache-control", "no-store".parse().unwrap());
                response
                    .headers_mut()
                    .insert("x-content-type-options", "nosniff".parse().unwrap());
                response
            },
        ))
        .with_state(state)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginInput {
    username: String,
    password: String,
}

async fn login(
    State(state): State<AppState>,
    body: Result<Json<LoginInput>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<serde_json::Value>)> {
    let Authentication::Production(config) = state.authentication.as_ref() else {
        return Err(ApiError::not_found(
            "Account login is unavailable in isolated demo mode",
        ));
    };
    let input = json_body(body)?;
    if input.username.len() > 64 || input.password.is_empty() || input.password.len() > 1024 {
        return Err(auth::unauthorized());
    }
    let username = input.username.trim().to_ascii_lowercase();
    auth::reserve_login(&*state.db()?, &username, state.clock.now())?;
    let account = config
        .accounts
        .iter()
        .find(|a| a.username == username)
        .cloned();
    // Unknown usernames still perform one Argon2 verification to avoid a cheap timing oracle.
    let hash = account
        .as_ref()
        .unwrap_or(&config.accounts[0])
        .password_hash
        .clone();
    let permit = state
        .auth_workers
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "Login is busy; try again shortly",
            )
        })?;
    let valid = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        auth::verify(&hash, &input.password)
    })
    .await
    .map_err(ApiError::internal)?;
    let account = account.filter(|_| valid).ok_or_else(auth::unauthorized)?;
    let mut bytes = [0u8; 32];
    OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(ApiError::internal)?;
    let token = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    let now = state.clock.now();
    let expires_at = now + config.session_ttl_seconds;
    let db = state.db()?;
    db.execute("DELETE FROM sessions WHERE expires_at<=?1", [now])?;
    db.execute("DELETE FROM sessions WHERE account_id=?1 AND token_hash NOT IN (SELECT token_hash FROM sessions WHERE account_id=?1 ORDER BY created_at DESC,rowid DESC LIMIT 9)", [&account.id])?;
    db.execute("INSERT INTO sessions(token_hash,account_id,account_fingerprint,expires_at,created_at,team_id) VALUES (?1,?2,?3,?4,?5,?6)",params![auth::digest(&token),account.id,account.fingerprint(config),expires_at,now,account.team_id(config)])?;
    Ok((
        StatusCode::CREATED,
        Json(
            serde_json::json!({"token":token,"expires_at":expires_at,"user":account.principal(config)}),
        ),
    ))
}

async fn session_identity(
    Extension(session): Extension<auth::Session>,
) -> Json<auth::SessionIdentity> {
    Json(auth::SessionIdentity {
        user: session.principal,
        expires_at: session.expires_at,
    })
}

async fn logout(
    State(state): State<AppState>,
    Extension(session): Extension<auth::Session>,
) -> ApiResult<StatusCode> {
    if let Some(hash) = session.token_hash {
        state
            .db()?
            .execute("DELETE FROM sessions WHERE token_hash=?1", [hash])?;
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn me(Extension(principal): Extension<Principal>) -> Json<Principal> {
    Json(principal)
}

async fn list_drivers(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Vec<Driver>>> {
    principal.require("dispatcher")?;
    Ok(Json(db::drivers(&*state.db()?, &principal.team_id)?))
}

async fn get_shift(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Driver>> {
    principal.require("driver")?;
    let db = state.db()?;
    Ok(Json(db::driver(&db, &principal.team_id, &principal.id)?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ShiftInput {
    active: bool,
    capacity: i32,
}
async fn shift(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Result<Json<ShiftInput>, JsonRejection>,
) -> ApiResult<Json<Driver>> {
    principal.require("driver")?;
    let input = json_body(body)?;
    if !(1..=8).contains(&input.capacity) {
        return Err(ApiError::bad_request("Capacity must be between 1 and 8"));
    }
    let db = state.db()?;
    let mut driver = db::driver(&db, &principal.team_id, &principal.id)?;
    let jobs = db::deliveries(&db, &principal.team_id)?;
    let has_work = jobs.iter().any(|j| {
        j.driver_id.as_deref() == Some(&principal.id)
            && matches!(
                j.status,
                DeliveryStatus::Assigned | DeliveryStatus::PickedUp
            )
    });
    if !input.active && has_work {
        return Err(ApiError::conflict(
            "Complete or reassign outstanding work before ending the shift",
        ));
    }
    driver.active = input.active;
    driver.capacity = input.capacity;
    let route = planner::evaluate(
        &driver,
        &db::route_keys(&db, &principal.team_id, &driver.id)?,
        &jobs,
        state.clock.now(),
    );
    if route
        .warnings
        .iter()
        .any(|w| w.to_lowercase().contains("capacity"))
    {
        return Err(ApiError::unprocessable(
            "Capacity is too small for the committed route",
        ));
    }
    db::save_driver(&db, &principal.team_id, &driver)?;
    Ok(Json(driver))
}

async fn location(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Result<Json<Coordinate>, JsonRejection>,
) -> ApiResult<Json<Driver>> {
    principal.require("driver")?;
    let coordinate = json_body(body)?;
    if !coordinate.valid() {
        return Err(ApiError::bad_request(
            "Coordinates must be finite latitude/longitude values",
        ));
    }
    let db = state.db()?;
    let mut driver = db::driver(&db, &principal.team_id, &principal.id)?;
    if !driver.active {
        return Err(ApiError::conflict(
            "Start a shift before reporting location",
        ));
    }
    driver.location = Some(coordinate);
    driver.location_updated_at = Some(state.clock.now());
    db::save_driver(&db, &principal.team_id, &driver)?;
    Ok(Json(driver))
}

async fn list_deliveries(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Vec<Delivery>>> {
    let mut jobs = db::deliveries(&*state.db()?, &principal.team_id)?;
    if !principal.has_role("dispatcher") {
        jobs.retain(|j| j.driver_id.as_deref() == Some(principal.id.as_str()));
    }
    Ok(Json(jobs))
}

struct Idempotency {
    key: String,
    request_hash: String,
}
impl Idempotency {
    fn parse(headers: &HeaderMap, path: &str, body: &impl Serialize) -> ApiResult<Option<Self>> {
        let Some(value) = headers.get("idempotency-key") else {
            return Ok(None);
        };
        let key = value
            .to_str()
            .map_err(|_| ApiError::bad_request("Invalid Idempotency-Key"))?;
        if key.len() < 8
            || key.len() > 128
            || !key
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
        {
            return Err(ApiError::bad_request("Idempotency-Key must contain 8–128 ASCII letters, digits, dots, underscores or hyphens"));
        }
        Ok(Some(Self {
            key: key.into(),
            request_hash: auth::digest(&format!("{path}:{}", serde_json::to_string(body)?)),
        }))
    }
    fn replay(&self, db: &Connection, principal: &Principal) -> ApiResult<Option<Delivery>> {
        let row: Option<(String, String)> = db
            .query_row(
                "SELECT request_hash,response FROM idempotency WHERE principal_id=?1 AND key=?2 AND team_id=?3",
                params![principal.id, self.key, principal.team_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        match row {
            Some((hash, _)) if hash != self.request_hash => Err(ApiError::conflict(
                "Idempotency-Key was already used for a different request",
            )),
            Some((_, body)) => {
                let response: Delivery = serde_json::from_str(&body)?;
                db::delivery(db, &principal.team_id, &response.id)?;
                Ok(Some(response))
            }
            None => Ok(None),
        }
    }
    fn save(&self, db: &Connection, principal: &Principal, response: &Delivery) -> ApiResult<()> {
        db.execute(
            "INSERT INTO idempotency(principal_id,key,request_hash,response,team_id) VALUES (?1,?2,?3,?4,?5)",
            params![
                principal.id,
                self.key,
                self.request_hash,
                serde_json::to_string(response)?,
                principal.team_id
            ],
        )?;
        Ok(())
    }
}

async fn create_delivery(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    headers: HeaderMap,
    body: Result<Json<NewDelivery>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Delivery>)> {
    principal.require("dispatcher")?;
    let input = json_body(body)?;
    input.validate().map_err(ApiError::bad_request)?;
    let key = Idempotency::parse(&headers, "/deliveries", &input)?;
    let mut db = state.db()?;
    let tx = db.transaction()?;
    if let Some(saved) = key
        .as_ref()
        .map(|k| k.replay(&tx, &principal))
        .transpose()?
        .flatten()
    {
        return Ok((StatusCode::CREATED, Json(saved)));
    }
    let delivery = input.into_delivery(state.clock.now());
    db::save_delivery(&tx, &principal.team_id, &delivery)?;
    if let Some(key) = key {
        key.save(&tx, &principal, &delivery)?;
    }
    tx.commit()?;
    Ok((StatusCode::CREATED, Json(delivery)))
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AssignInput {
    driver_id: String,
}
async fn assign(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Result<Json<AssignInput>, JsonRejection>,
) -> ApiResult<Json<Delivery>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let input = json_body(body)?;
    let key = Idempotency::parse(&headers, &format!("/deliveries/{id}/assign"), &input)?;
    let mut db = state.db()?;
    let tx = db.transaction()?;
    let mut job = db::delivery(&tx, &principal.team_id, &id)?;
    let driver = db::driver(&tx, &principal.team_id, &input.driver_id)?;
    if let Some(saved) = key
        .as_ref()
        .map(|k| k.replay(&tx, &principal))
        .transpose()?
        .flatten()
    {
        return Ok(Json(saved));
    }
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict(
            "Picked-up and delivered jobs cannot be reassigned",
        ));
    }
    if !driver.active || driver.location.is_none() {
        return Err(ApiError::conflict(
            "Driver must be on shift with a reported location",
        ));
    }
    if !planner::location_is_fresh(&driver, state.clock.now()) {
        return Err(ApiError::conflict(
            "Driver location is older than 5 minutes; request an update",
        ));
    }
    let jobs = db::deliveries(&tx, &principal.team_id)?;
    let current = db::route_keys(&tx, &principal.team_id, &driver.id)?;
    if current
        .iter()
        .filter(|key| key.delivery_id != job.id)
        .count()
        + 2
        > planner::MAX_ROUTE_STOPS
    {
        return Err(ApiError::unprocessable(
            "Driver route limit reached (32 outstanding stops)",
        ));
    }
    let (keys, _) =
        planner::insert(&driver, &current, &jobs, &job, state.clock.now()).ok_or_else(|| {
            ApiError::unprocessable(
                "No feasible insertion: check capacity, readiness, deadline, and maximum ride time",
            )
        })?;
    if let Some(change) = route_after_removal(
        &tx,
        &principal.team_id,
        &job,
        &driver.id,
        &jobs,
        state.clock.now(),
    )? {
        if change.introduces_violation {
            return Err(ApiError::unprocessable("Reassignment introduces a new constraint violation in the previous driver's remaining route"));
        }
        db::save_route(&tx, &principal.team_id, &change.driver_id, &change.keys)?;
    }
    job.driver_id = Some(driver.id.clone());
    job.status = DeliveryStatus::Assigned;
    db::save_delivery(&tx, &principal.team_id, &job)?;
    db::save_route(&tx, &principal.team_id, &driver.id, &keys)?;
    if let Some(key) = key {
        key.save(&tx, &principal, &job)?;
    }
    tx.commit()?;
    Ok(Json(job))
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StatusInput {
    status: DeliveryStatus,
}
async fn status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Result<Json<StatusInput>, JsonRejection>,
) -> ApiResult<Json<Delivery>> {
    principal.require("driver")?;
    let id = path_id(path)?;
    let input = json_body(body)?;
    if !matches!(
        input.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::bad_request(
            "Status must be picked_up or delivered",
        ));
    }
    let key = Idempotency::parse(&headers, &format!("/deliveries/{id}/status"), &input)?;
    let mut db = state.db()?;
    let tx = db.transaction()?;
    let mut job = db::delivery(&tx, &principal.team_id, &id)?;
    if job.driver_id.as_deref() != Some(principal.id.as_str()) {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "Delivery is not assigned to this driver",
        ));
    }
    if let Some(saved) = key
        .as_ref()
        .map(|k| k.replay(&tx, &principal))
        .transpose()?
        .flatten()
    {
        return Ok(Json(saved));
    }
    let driver = db::driver(&tx, &principal.team_id, &principal.id)?;
    if !driver.active {
        return Err(ApiError::conflict("Driver must be on shift"));
    }
    let kind = match (job.status, input.status) {
        (DeliveryStatus::Assigned, DeliveryStatus::PickedUp) => StopKind::Pickup,
        (DeliveryStatus::PickedUp, DeliveryStatus::Delivered) => StopKind::Dropoff,
        _ => return Err(ApiError::conflict("Invalid delivery status transition")),
    };
    let mut keys = db::route_keys(&tx, &principal.team_id, &principal.id)?;
    if keys.first()
        != Some(&StopKey {
            delivery_id: job.id.clone(),
            kind,
        })
    {
        return Err(ApiError::conflict("Complete the suggested next stop first"));
    }
    let now = state.clock.now();
    match kind {
        StopKind::Pickup => {
            if now < job.ready_at {
                return Err(ApiError::conflict("Delivery is not ready for pickup"));
            }
            let onboard: i32 = db::deliveries(&tx, &principal.team_id)?
                .iter()
                .filter(|j| j.driver_id == job.driver_id && j.status == DeliveryStatus::PickedUp)
                .map(|j| j.load_units)
                .sum();
            if onboard + job.load_units > driver.capacity {
                return Err(ApiError::conflict("Pickup would exceed driver capacity"));
            }
            job.picked_up_at = Some(now);
        }
        StopKind::Dropoff => {
            job.delivered_at = Some(now);
        }
    }
    job.status = input.status;
    keys.remove(0);
    db::save_delivery(&tx, &principal.team_id, &job)?;
    db::save_route(&tx, &principal.team_id, &principal.id, &keys)?;
    if let Some(key) = key {
        key.save(&tx, &principal, &job)?;
    }
    tx.commit()?;
    Ok(Json(job))
}

// Removing stops can make a different pickup happen earlier, increasing the
// food's time on board while waiting for another shop. Validate BOTH drivers.
// Already-present violations may remain, permitting dispatch recovery (for
// example moving work away from a driver whose GPS has gone stale).
struct SourceRouteChange {
    driver_id: String,
    keys: Vec<StopKey>,
    introduces_violation: bool,
}
fn route_after_removal(
    db: &Connection,
    team_id: &str,
    candidate: &Delivery,
    target_driver: &str,
    jobs: &[Delivery],
    now: i64,
) -> ApiResult<Option<SourceRouteChange>> {
    let Some(source_id) = candidate.driver_id.as_deref() else {
        return Ok(None);
    };
    if source_id == target_driver {
        return Ok(None);
    }
    let source = db::driver(db, team_id, source_id)?;
    let mut keys = db::route_keys(db, team_id, source_id)?;
    let before = planner::evaluate(&source, &keys, jobs, now);
    keys.retain(|key| key.delivery_id != candidate.id);
    let remaining: Vec<Delivery> = jobs
        .iter()
        .filter(|job| job.id != candidate.id)
        .cloned()
        .collect();
    let route = planner::evaluate(&source, &keys, &remaining, now);
    let introduces_violation = route
        .warnings
        .iter()
        .any(|warning| !before.warnings.contains(warning));
    Ok(Some(SourceRouteChange {
        driver_id: source_id.to_owned(),
        keys,
        introduces_violation,
    }))
}

fn get_route(state: &AppState, team_id: &str, driver_id: &str) -> ApiResult<Route> {
    let db = state.db()?;
    let driver = db::driver(&db, team_id, driver_id)?;
    Ok(planner::evaluate(
        &driver,
        &db::route_keys(&db, team_id, driver_id)?,
        &db::deliveries(&db, team_id)?,
        state.clock.now(),
    ))
}
async fn own_route(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Route>> {
    principal.require("driver")?;
    Ok(Json(get_route(&state, &principal.team_id, &principal.id)?))
}
async fn driver_route(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<Json<Route>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    Ok(Json(get_route(&state, &principal.team_id, &id)?))
}
async fn suggestions(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<Json<Vec<Suggestion>>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let db = state.db()?;
    let job = db::delivery(&db, &principal.team_id, &id)?;
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict(
            "Suggestions are only available before pickup",
        ));
    }
    let jobs = db::deliveries(&db, &principal.team_id)?;
    let now = state.clock.now();
    let mut result = Vec::new();
    for driver in db::drivers(&db, &principal.team_id)? {
        let current = db::route_keys(&db, &principal.team_id, &driver.id)?;
        if current
            .iter()
            .filter(|key| key.delivery_id != job.id)
            .count()
            + 2
            > planner::MAX_ROUTE_STOPS
        {
            continue;
        }
        if route_after_removal(&db, &principal.team_id, &job, &driver.id, &jobs, now)?
            .is_some_and(|change| change.introduces_violation)
        {
            continue;
        }
        if let Some((_, route)) = planner::insert(&driver, &current, &jobs, &job, now) {
            let baseline = planner::evaluate(&driver, &current, &jobs, now);
            result.push(Suggestion {
                driver_id: driver.id,
                incremental_travel_seconds: route.travel_seconds - baseline.travel_seconds,
                route,
            });
        }
    }
    result.sort_by(|a, b| {
        (a.incremental_travel_seconds, &a.driver_id)
            .cmp(&(b.incremental_travel_seconds, &b.driver_id))
    });
    Ok(Json(result))
}
