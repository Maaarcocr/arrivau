mod db;
mod error;
pub mod model;
pub mod planner;

use axum::{
    extract::{
        rejection::{JsonRejection, PathRejection},
        DefaultBodyLimit, Path, Request, State,
    },
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
    routing::{get, post},
    Extension, Json, Router,
};
use error::{ApiError, ApiResult};
use model::*;
use rusqlite::Connection;
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
            return Err("Production authentication is not implemented. Set ARRIVAU_DEMO=1 for local development only.".into());
        }
        let db = db::open(path).map_err(|e| e.message)?;
        Ok(Self {
            db: Arc::new(Mutex::new(db)),
            clock,
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
    role: &'static str,
}
impl Principal {
    fn require(&self, role: &str) -> ApiResult<()> {
        if self.role == role {
            Ok(())
        } else {
            Err(ApiError::new(
                StatusCode::FORBIDDEN,
                format!("{role} role required"),
            ))
        }
    }
}

async fn authenticate(mut request: Request, next: Next) -> ApiResult<Response> {
    let token = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    let (id, name, role) = match token {
        Some("demo-dispatcher") => ("dispatcher-1", "Dispatcher", "dispatcher"),
        Some("demo-driver-1") => ("driver-1", "Driver 1", "driver"),
        Some("demo-driver-2") => ("driver-2", "Driver 2", "driver"),
        _ => {
            return Err(ApiError::new(
                StatusCode::UNAUTHORIZED,
                "A valid bearer token is required",
            ))
        }
    };
    request.extensions_mut().insert(Principal {
        id: id.into(),
        name: name.into(),
        role,
    });
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
        .route("/drivers", get(list_drivers))
        .route("/shift", get(get_shift).post(shift))
        .route("/location", post(location))
        .route("/deliveries", get(list_deliveries).post(create_delivery))
        .route("/deliveries/{id}/assign", post(assign))
        .route("/deliveries/{id}/status", post(status))
        .route("/deliveries/{id}/suggestions", get(suggestions))
        .route("/route", get(own_route))
        .route("/drivers/{id}/route", get(driver_route))
        .route_layer(middleware::from_fn(authenticate));
    Router::new()
        .route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "ok"})) }),
        )
        .nest("/v1", v1)
        .fallback(|| async { ApiError::not_found("Endpoint not found") })
        .method_not_allowed_fallback(|| async {
            ApiError::new(StatusCode::METHOD_NOT_ALLOWED, "Method not allowed")
        })
        .layer(DefaultBodyLimit::max(16 * 1024))
        .with_state(state)
}

async fn me(Extension(principal): Extension<Principal>) -> Json<Principal> {
    Json(principal)
}

async fn list_drivers(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Vec<Driver>>> {
    principal.require("dispatcher")?;
    Ok(Json(db::drivers(&*state.db()?)?))
}

async fn get_shift(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Driver>> {
    principal.require("driver")?;
    let db = state.db()?;
    Ok(Json(db::driver(&db, &principal.id)?))
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
    let mut driver = db::driver(&db, &principal.id)?;
    let jobs = db::deliveries(&db)?;
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
        &db::route_keys(&db, &driver.id)?,
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
    db::save_driver(&db, &driver)?;
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
    let mut driver = db::driver(&db, &principal.id)?;
    if !driver.active {
        return Err(ApiError::conflict(
            "Start a shift before reporting location",
        ));
    }
    driver.location = Some(coordinate);
    driver.location_updated_at = Some(state.clock.now());
    db::save_driver(&db, &driver)?;
    Ok(Json(driver))
}

async fn list_deliveries(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Vec<Delivery>>> {
    let mut jobs = db::deliveries(&*state.db()?)?;
    if principal.role == "driver" {
        jobs.retain(|j| j.driver_id.as_deref() == Some(principal.id.as_str()));
    }
    Ok(Json(jobs))
}

async fn create_delivery(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Result<Json<NewDelivery>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Delivery>)> {
    principal.require("dispatcher")?;
    let input = json_body(body)?;
    input.validate().map_err(ApiError::bad_request)?;
    let delivery = input.into_delivery(state.clock.now());
    db::save_delivery(&*state.db()?, &delivery)?;
    Ok((StatusCode::CREATED, Json(delivery)))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AssignInput {
    driver_id: String,
}
async fn assign(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
    body: Result<Json<AssignInput>, JsonRejection>,
) -> ApiResult<Json<Delivery>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let input = json_body(body)?;
    let mut db = state.db()?;
    let tx = db.transaction()?;
    let mut job = db::delivery(&tx, &id)?;
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict(
            "Picked-up and delivered jobs cannot be reassigned",
        ));
    }
    let driver = db::driver(&tx, &input.driver_id)?;
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
    let jobs = db::deliveries(&tx)?;
    let current = db::route_keys(&tx, &driver.id)?;
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
    if let Some(change) = route_after_removal(&tx, &job, &driver.id, &jobs, state.clock.now())? {
        if change.introduces_violation {
            return Err(ApiError::unprocessable("Reassignment introduces a new constraint violation in the previous driver's remaining route"));
        }
        db::save_route(&tx, &change.driver_id, &change.keys)?;
    }
    job.driver_id = Some(driver.id.clone());
    job.status = DeliveryStatus::Assigned;
    db::save_delivery(&tx, &job)?;
    db::save_route(&tx, &driver.id, &keys)?;
    tx.commit()?;
    Ok(Json(job))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StatusInput {
    status: DeliveryStatus,
}
async fn status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
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
    let mut db = state.db()?;
    let tx = db.transaction()?;
    let mut job = db::delivery(&tx, &id)?;
    if job.driver_id.as_deref() != Some(principal.id.as_str()) {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "Delivery is not assigned to this driver",
        ));
    }
    let driver = db::driver(&tx, &principal.id)?;
    if !driver.active {
        return Err(ApiError::conflict("Driver must be on shift"));
    }
    let kind = match (job.status, input.status) {
        (DeliveryStatus::Assigned, DeliveryStatus::PickedUp) => StopKind::Pickup,
        (DeliveryStatus::PickedUp, DeliveryStatus::Delivered) => StopKind::Dropoff,
        _ => return Err(ApiError::conflict("Invalid delivery status transition")),
    };
    let mut keys = db::route_keys(&tx, &principal.id)?;
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
            let onboard: i32 = db::deliveries(&tx)?
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
    db::save_delivery(&tx, &job)?;
    db::save_route(&tx, &principal.id, &keys)?;
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
    let source = db::driver(db, source_id)?;
    let mut keys = db::route_keys(db, source_id)?;
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

fn get_route(state: &AppState, driver_id: &str) -> ApiResult<Route> {
    let db = state.db()?;
    let driver = db::driver(&db, driver_id)?;
    Ok(planner::evaluate(
        &driver,
        &db::route_keys(&db, driver_id)?,
        &db::deliveries(&db)?,
        state.clock.now(),
    ))
}
async fn own_route(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Route>> {
    principal.require("driver")?;
    Ok(Json(get_route(&state, &principal.id)?))
}
async fn driver_route(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<Json<Route>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    Ok(Json(get_route(&state, &id)?))
}
async fn suggestions(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<Json<Vec<Suggestion>>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let db = state.db()?;
    let job = db::delivery(&db, &id)?;
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict(
            "Suggestions are only available before pickup",
        ));
    }
    let jobs = db::deliveries(&db)?;
    let now = state.clock.now();
    let mut result = Vec::new();
    for driver in db::drivers(&db)? {
        let current = db::route_keys(&db, &driver.id)?;
        if current
            .iter()
            .filter(|key| key.delivery_id != job.id)
            .count()
            + 2
            > planner::MAX_ROUTE_STOPS
        {
            continue;
        }
        if route_after_removal(&db, &job, &driver.id, &jobs, now)?
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
