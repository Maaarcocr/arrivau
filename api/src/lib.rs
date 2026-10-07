mod account_deletion;
pub mod auth;
mod db;
mod error;
mod invites;
pub mod model;
pub mod places;
pub mod planner;
pub mod privacy;
pub mod routing;

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
use routing::{Approximate, RoutingService, TravelMatrix, TravelTimes};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
    privacy_notice: privacy::PrivacyNotice,
    routing: RoutingService,
    places: places::PlacesService,
    db: Arc<Mutex<Connection>>,
    clock: Arc<dyn Clock>,
    authentication: Arc<Authentication>,
    auth_workers: Arc<tokio::sync::Semaphore>,
    dispatch_cursor: Arc<Mutex<DispatchCursor>>,
    dispatch_workers: Arc<tokio::sync::Semaphore>,
}

#[derive(Default)]
struct DispatchCursor {
    after: Option<(i64, String)>,
    high_water: Option<(i64, String)>,
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
            privacy_notice: privacy::PrivacyNotice::default(),
            routing: RoutingService::default(),
            places: places::PlacesService::default(),
            db: Arc::new(Mutex::new(db)),
            clock,
            authentication: Arc::new(Authentication::Demo),
            auth_workers: Arc::new(tokio::sync::Semaphore::new(2)),
            dispatch_cursor: Arc::new(Mutex::new(DispatchCursor::default())),
            dispatch_workers: Arc::new(tokio::sync::Semaphore::new(1)),
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
            privacy_notice: privacy::PrivacyNotice::default(),
            routing: RoutingService::default(),
            places: places::PlacesService::default(),
            db: Arc::new(Mutex::new(db)),
            clock,
            authentication: Arc::new(Authentication::Production(config)),
            auth_workers: Arc::new(tokio::sync::Semaphore::new(2)),
            dispatch_cursor: Arc::new(Mutex::new(DispatchCursor::default())),
            dispatch_workers: Arc::new(tokio::sync::Semaphore::new(1)),
        })
    }

    pub fn with_routing(mut self, routing: RoutingService) -> Self {
        self.routing = routing;
        self
    }

    pub fn with_privacy_notice(mut self, notice: privacy::PrivacyNotice) -> Self {
        self.privacy_notice = notice;
        self
    }

    pub fn with_places(mut self, places: places::PlacesService) -> Self {
        self.places = places;
        self
    }

    async fn resolve_place(&self, team: &str, id: &str) -> ApiResult<(Coordinate, i64)> {
        let generation = places::generation(&*self.db()?, team)?;
        self.resolve_place_in_generation(team, id, generation).await
    }

    async fn resolve_place_in_generation(
        &self,
        team: &str,
        id: &str,
        generation: i64,
    ) -> ApiResult<(Coordinate, i64)> {
        if !places::valid_place_id(id) {
            return Err(ApiError::bad_request("Invalid Google Place ID"));
        }
        if !matches!(self.authentication.as_ref(), Authentication::Demo)
            && id.starts_with("arrivau-test-")
        {
            return Err(ApiError::bad_request(
                "Test Place IDs are unavailable in production",
            ));
        }
        {
            let db = self.db()?;
            if places::generation(&db, team)? != generation {
                return Err(places::unavailable());
            }
            if let Some(cached) = places::cached(&db, team, id)? {
                return Ok(cached);
            }
            if places::retry_blocked(&db, team, id)? {
                return Err(places::unavailable());
            }
        }
        let result = if matches!(self.authentication.as_ref(), Authentication::Demo) {
            match places::demo_coordinate(id) {
                Some(coordinate) => Ok(coordinate),
                None => self.places.resolve(id).await,
            }
        } else {
            self.places.resolve(id).await
        };
        let db = self.db()?;
        if places::generation(&db, team)? != generation {
            return Err(places::unavailable());
        }
        let coordinate = match result {
            Ok(coordinate) => coordinate,
            Err(error) => {
                places::failed(&db, team, id, self.clock.now())?;
                return Err(error);
            }
        };
        let now = self.clock.now();
        places::save(&db, team, id, coordinate, now)?;
        Ok((coordinate, now))
    }

    /// Refresh only destinations involved in this planning operation. Provider
    /// failure leaves null coordinates and the planner retains structural stops
    /// with estimates unavailable, so neither assignment mode can use stale data.
    async fn refresh_places(
        &self,
        team: &str,
        candidate: Option<&str>,
        driver: Option<&str>,
    ) -> ApiResult<()> {
        self.refresh_places_with_budget(team, candidate, driver, std::time::Duration::from_secs(9))
            .await
    }

    async fn refresh_places_with_budget(
        &self,
        team: &str,
        candidate: Option<&str>,
        driver: Option<&str>,
        budget: std::time::Duration,
    ) -> ApiResult<()> {
        let (ids, generation) = {
            let db = self.db()?;
            let mut ids = std::collections::BTreeSet::new();
            for job in db::planning_deliveries(&db, team)? {
                if job.status == DeliveryStatus::Pending && candidate != Some(job.id.as_str()) {
                    continue;
                }
                if driver.is_some_and(|id| job.driver_id.as_deref() != Some(id))
                    && candidate != Some(job.id.as_str())
                {
                    continue;
                }
                if job.status != DeliveryStatus::PickedUp {
                    if let Some(id) = job.pickup_google_place_id {
                        ids.insert(id);
                    }
                }
                if let Some(id) = job.dropoff_google_place_id {
                    ids.insert(id);
                }
            }
            (ids, places::generation(&db, team)?)
        };
        let mut ids = ids.into_iter();
        let mut tasks = tokio::task::JoinSet::new();
        let spawn = |tasks: &mut tokio::task::JoinSet<()>, id: String| {
            let state = self.clone();
            let team = team.to_owned();
            tasks.spawn(async move {
                // Never log provider bodies, key-bearing URLs or IDs.
                let _ = state
                    .resolve_place_in_generation(&team, &id, generation)
                    .await;
            });
        };
        for id in ids.by_ref().take(4) {
            spawn(&mut tasks, id);
        }
        let _ = tokio::time::timeout(budget, async {
            while tasks.join_next().await.is_some() {
                if let Some(id) = ids.next() {
                    spawn(&mut tasks, id);
                }
            }
        })
        .await;
        // A dropped JoinSet cancels every unresolved lookup. Missing locations
        // remain null; no worker can keep modifying snapshots after this returns.
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        Ok(())
    }

    /// Snapshot only this team's outstanding work. All native calls happen
    /// after releasing SQLite. Recheck SQLite's write counter before use; no
    /// database revision table or schema migration is required for one process.
    async fn prepare_travel(
        &self,
        team: &str,
        candidate_id: Option<&str>,
        driver_id: Option<&str>,
        pickup_anchor: bool,
    ) -> ApiResult<PreparedTravel> {
        self.refresh_places(team, candidate_id, driver_id).await?;
        for _ in 0..3 {
            let (revision, inputs) = {
                let db = self.db()?;
                if let Some(id) = driver_id {
                    db::driver(&db, team, id)?;
                }
                let candidate = candidate_id
                    .map(|id| db::delivery(&db, team, id))
                    .transpose()?;
                let revision = db.total_changes();
                if !self.routing.is_embedded() {
                    return Ok(PreparedTravel {
                        revision,
                        approximate: true,
                        matrices: HashMap::new(),
                    });
                }
                let jobs = db::planning_deliveries(&db, team)?;
                let inputs = db::drivers(&db, team)?
                    .into_iter()
                    .filter(|driver| driver_id.is_none_or(|id| id == driver.id))
                    .filter(|driver| {
                        driver_id.is_some()
                            || driver.active
                            || jobs
                                .iter()
                                .any(|job| job.driver_id.as_deref() == Some(driver.id.as_str()))
                    })
                    .map(|mut driver| {
                        // Pickup is acknowledged at the restaurant. Exclude old
                        // GPS from the native point set too: OSRM snapping can
                        // depend on every point in a table, not just each leg.
                        if pickup_anchor && driver_id == Some(driver.id.as_str()) {
                            driver.location = candidate.as_ref().and_then(|job| job.pickup);
                        }
                        let points = routing::plan_points(&driver, &jobs, candidate.as_ref());
                        let allow_cache = !jobs
                            .iter()
                            .filter(|job| job.driver_id.as_deref() == Some(driver.id.as_str()))
                            .chain(candidate.iter())
                            .any(|job| {
                                job.pickup_google_place_id.is_some()
                                    || job.dropoff_google_place_id.is_some()
                            });
                        (driver.id, driver.location, points, allow_cache)
                    })
                    .collect::<Vec<_>>();
                (revision, inputs)
            };
            let mut matrices = HashMap::new();
            for (id, location, points, allow_cache) in inputs {
                let matrix = self
                    .routing
                    .matrix_with_cache(location, points, allow_cache)
                    .await
                    .map_err(ApiError::unprocessable)?;
                matrices.insert(id, matrix);
            }
            if self.db()?.total_changes() == revision {
                return Ok(PreparedTravel {
                    revision,
                    approximate: false,
                    matrices,
                });
            }
        }
        Err(planning_changed())
    }

    // Recheck durable membership after reading the body and under the mutation transaction.
    fn require_current_driver(&self, db: &Connection, principal: &Principal) -> ApiResult<()> {
        if let Authentication::Production(config) = self.authentication.as_ref() {
            let account =
                auth::account_by_id(db, config, &principal.id)?.ok_or_else(auth::unauthorized)?;
            if account.team_id(config) != principal.team_id {
                return Err(auth::unauthorized());
            }
            account.principal(config).require("driver")?;
        }
        Ok(())
    }

    fn db(&self) -> ApiResult<MutexGuard<'_, Connection>> {
        let db = self
            .db
            .lock()
            .map_err(|_| ApiError::internal("Database lock poisoned"))?;
        places::purge(&db, self.clock.now())?;
        Ok(db)
    }

    /// A bounded server-side sweep, independent of foreground clients. The cursor
    /// rotates past attempted jobs so blocked older work cannot starve the queue.
    pub async fn dispatch_ready(&self) -> Result<usize, String> {
        self.dispatch_ready_inner()
            .await
            .map_err(|error| error.message)
    }

    async fn dispatch_ready_inner(&self) -> ApiResult<usize> {
        self.dispatch_ready_with_budget(std::time::Duration::from_secs(9))
            .await
    }

    async fn dispatch_ready_with_budget(&self, budget: std::time::Duration) -> ApiResult<usize> {
        // GPS updates, shift changes and the timer share one bounded sweep.
        let Ok(_permit) = self.dispatch_workers.clone().try_acquire_owned() else {
            return Ok(0);
        };
        const MAX_DISPATCH_PER_TICK: usize = 32;
        let candidates = {
            let now = self.clock.now();
            let db = self.db()?;
            let mut candidates = Vec::new();
            for team in db::delivery_teams(&db)? {
                for job in db::planning_deliveries(&db, &team)? {
                    if auto_dispatch_due(&job, now) {
                        candidates.push((job.ready_at, job.id, team.clone()));
                    }
                }
            }
            candidates.sort();
            let mut cursor = self
                .dispatch_cursor
                .lock()
                .map_err(|_| ApiError::internal("Dispatcher lock poisoned"))?;
            let within_cohort = |candidate: &(i64, String, String), cursor: &DispatchCursor| {
                let key = (candidate.0, candidate.1.clone());
                cursor.after.as_ref().is_none_or(|after| &key > after)
                    && cursor.high_water.as_ref().is_some_and(|end| &key <= end)
            };
            if !candidates
                .iter()
                .any(|candidate| within_cohort(candidate, &cursor))
            {
                cursor.after = None;
                cursor.high_water = candidates.last().map(|(at, id, _)| (*at, id.clone()));
            }
            candidates.retain(|candidate| within_cohort(candidate, &cursor));
            candidates.truncate(MAX_DISPATCH_PER_TICK);
            candidates
        };
        let mut assigned = 0;
        let sweep_started = tokio::time::Instant::now();
        for (ready_at, id, team) in candidates {
            let Some(remaining) = budget.checked_sub(sweep_started.elapsed()) else {
                break;
            };
            let outcome: ApiResult<bool> = tokio::time::timeout(remaining, async {
                let travel = self.prepare_travel(&team, Some(&id), None, false).await?;
                let mut db = self.db()?;
                travel.verify(&db)?;
                let tx = db.transaction()?;
                let mut job = db::delivery(&tx, &team, &id)?;
                let now = self.clock.now();
                let assigned = auto_dispatch_due(&job, now)
                    && auto_assign(&tx, &team, &mut job, now, &travel)?;
                tx.commit()?;
                Ok(assigned)
            })
            .await
            .unwrap_or_else(|_| {
                Err(ApiError::unprocessable(
                    "Dispatch refresh deadline reached; retrying remaining work next tick",
                ))
            });
            self.dispatch_cursor
                .lock()
                .map_err(|_| ApiError::internal("Dispatcher lock poisoned"))?
                .after = Some((ready_at, id));
            match outcome {
                Ok(true) => assigned += 1,
                Ok(false) => {}
                Err(error) => {
                    tracing::warn!(reason = %error.message, "One automatic dispatch deferred; continuing the bounded batch")
                }
            }
        }
        Ok(assigned)
    }

    pub fn spawn_dispatcher(&self, interval: std::time::Duration) -> tokio::task::JoinHandle<()> {
        let state = self.clone();
        tokio::spawn(async move {
            let mut ticks =
                tokio::time::interval(interval.max(std::time::Duration::from_millis(25)));
            ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                ticks.tick().await;
                if let Err(error) = state.dispatch_ready().await {
                    tracing::error!(%error, "Automatic dispatch will retry on the next tick");
                }
            }
        })
    }
}

struct PreparedTravel {
    revision: u64,
    approximate: bool,
    matrices: HashMap<String, TravelMatrix>,
}
struct MissingTravel;
impl TravelTimes for MissingTravel {
    fn seconds(&self, _from: Coordinate, _to: Coordinate) -> Option<i64> {
        None
    }
    fn estimate(&self) -> routing::TravelEstimate {
        routing::TravelEstimate {
            mode: routing::TravelMode::ApproximateFallback,
            notice: Some("Stima stradale non disponibile: aggiorna il percorso.".into()),
            ..Default::default()
        }
    }
}
impl PreparedTravel {
    fn times(&self, driver: &str) -> &dyn TravelTimes {
        if self.approximate {
            &Approximate
        } else {
            self.matrices
                .get(driver)
                .map(|matrix| matrix as &dyn TravelTimes)
                .unwrap_or(&MissingTravel)
        }
    }
    fn verify(&self, db: &Connection) -> ApiResult<()> {
        if db.total_changes() == self.revision {
            Ok(())
        } else {
            Err(planning_changed())
        }
    }
}
fn planning_changed() -> ApiError {
    ApiError::conflict("Planning state changed while calculating road times; refresh and retry")
}

#[derive(Debug, Clone, Serialize)]
struct Principal {
    id: String,
    name: String,
    role: String,
    roles: Vec<String>,
    team_id: String,
    team_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    can_delete_account: Option<bool>,
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
                    can_delete_account: None,
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
        .route("/account/deletion-preview", get(account_deletion::preview))
        .route("/account", axum::routing::delete(account_deletion::delete))
        .route("/drivers", get(list_drivers))
        .route(
            "/restaurants",
            get(list_restaurants).post(create_restaurant),
        )
        .route("/shift", get(get_shift).post(shift))
        .route("/location", post(location))
        .route("/deliveries", get(list_deliveries).post(create_delivery))
        .route("/deliveries/{id}/assign", post(assign))
        .route("/deliveries/{id}/readiness", post(readiness))
        .route("/deliveries/{id}/status", post(status))
        .route("/deliveries/{id}/suggestions", get(suggestions))
        .route("/route", get(own_route))
        .route("/drivers/{id}/route", get(driver_route))
        .route_layer(middleware::from_fn_with_state(state.clone(), authenticate));
    Router::new()
        .route("/privacy", get(privacy::show))
        .route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "ok"})) }),
        )
        .route("/v1/session", post(login))
        .route("/v1/invites/redeem", post(invites::redeem))
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
    let account = auth::account_by_username(&*state.db()?, config, &username)?;
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
    let token = auth::random_token()?;
    let now = state.clock.now();
    let expires_at = now + config.session_ttl_seconds;
    let mut db = state.db()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let current = auth::account_by_id(&tx, config, &account.id)?.ok_or_else(auth::unauthorized)?;
    if current.fingerprint(config) != account.fingerprint(config) {
        return Err(auth::unauthorized());
    }
    auth::save_session(&tx, &account, config, &token, now, expires_at)?;
    tx.commit()?;
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
    let driver = {
        let mut connection = state.db()?;
        let db = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        state.require_current_driver(&db, &principal)?;
        let mut driver = db::driver(&db, &principal.team_id, &principal.id)?;
        let jobs = db::planning_deliveries(&db, &principal.team_id)?;
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
        db.commit()?;
        driver
    };
    if let Err(error) = state.dispatch_ready().await {
        tracing::warn!(%error, "Shift saved; automatic dispatch will retry");
    }
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
    let driver = {
        let mut connection = state.db()?;
        let db = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        state.require_current_driver(&db, &principal)?;
        let mut driver = db::driver(&db, &principal.team_id, &principal.id)?;
        if !driver.active {
            return Err(ApiError::conflict(
                "Start a shift before reporting location",
            ));
        }
        driver.location = Some(coordinate);
        driver.location_updated_at = Some(state.clock.now());
        db::save_driver(&db, &principal.team_id, &driver)?;
        db.commit()?;
        driver
    };
    if let Err(error) = state.dispatch_ready().await {
        tracing::warn!(%error, "Location saved; automatic dispatch will retry");
    }
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
    fn scope_hash(team: &str, principal: &str, key: &str) -> String {
        auth::digest(&serde_json::to_string(&(team, principal, key)).expect("strings serialize"))
    }
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
        let response: Option<Delivery> = self.replay_body(db, principal)?;
        if let Some(response) = &response {
            db::delivery(db, &principal.team_id, &response.id)?;
        }
        Ok(response)
    }
    fn replay_body<T: serde::de::DeserializeOwned>(
        &self,
        db: &Connection,
        principal: &Principal,
    ) -> ApiResult<Option<T>> {
        let retired: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM idempotency_retired WHERE scope_hash=?1)",
            [Self::scope_hash(
                &principal.team_id,
                &principal.id,
                &self.key,
            )],
            |r| r.get(0),
        )?;
        if retired {
            return Err(ApiError::conflict(
                "Idempotency-Key refers to deleted data; discard this saved request",
            ));
        }
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
            Some((_, body)) => Ok(Some(places::decode(db, &principal.team_id, &body)?)),
            None => Ok(None),
        }
    }
    fn save(
        &self,
        db: &Connection,
        principal: &Principal,
        response: &impl Serialize,
    ) -> ApiResult<()> {
        db.execute(
            "INSERT INTO idempotency(principal_id,key,request_hash,response,team_id) VALUES (?1,?2,?3,?4,?5)",
            params![
                principal.id,
                self.key,
                self.request_hash,
                places::durable_json(response)?,
                principal.team_id
            ],
        )?;
        Ok(())
    }
}

// A previously committed retry must remain replayable even if native planning is
// busy or unrelated GPS writes make a new snapshot unstable. Preserve each
// endpoint's existing target/ownership authorization before replaying.
fn planning_replay(
    state: &AppState,
    principal: &Principal,
    key: Option<&Idempotency>,
    id: &str,
    target_driver: Option<&str>,
    require_ownership: bool,
) -> ApiResult<Option<Delivery>> {
    let Some(key) = key else {
        return Ok(None);
    };
    let db = state.db()?;
    let job = db::delivery(&db, &principal.team_id, id)?;
    if let Some(driver) = target_driver {
        db::driver(&db, &principal.team_id, driver)?;
    }
    if require_ownership && job.driver_id.as_deref() != Some(principal.id.as_str()) {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "Delivery is not assigned to this driver",
        ));
    }
    key.replay(&db, principal)
}

async fn create_delivery(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    headers: HeaderMap,
    body: Result<Json<NewDelivery>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Delivery>)> {
    principal.require("dispatcher")?;
    let mut input = json_body(body)?;
    let key = Idempotency::parse(&headers, "/deliveries", &input)?;
    {
        let db = state.db()?;
        if let Some(id) = &input.restaurant_id {
            let restaurant = db::restaurant(&db, &principal.team_id, id)?;
            input.shop_name = restaurant.name;
            input.pickup_address = restaurant.address;
            input.pickup = restaurant.coordinate;
            input.pickup_google_place_id = restaurant.google_place_id;
        }
        input.validate().map_err(ApiError::bad_request)?;
        if let Some(saved) = key
            .as_ref()
            .map(|k| k.replay(&db, &principal))
            .transpose()?
            .flatten()
        {
            return Ok((StatusCode::CREATED, Json(saved)));
        }
    }

    if let Some(id) = &input.pickup_google_place_id {
        state.resolve_place(&principal.team_id, id).await?;
    }
    if let Some(id) = &input.dropoff_google_place_id {
        state.resolve_place(&principal.team_id, id).await?;
    }
    let mut db = state.db()?;
    let tx = db.transaction()?;
    // Another request may have committed while provider I/O was in flight.
    if let Some(saved) = key
        .as_ref()
        .map(|k| k.replay(&tx, &principal))
        .transpose()?
        .flatten()
    {
        return Ok((StatusCode::CREATED, Json(saved)));
    }
    let mut delivery = input.into_delivery(state.clock.now());
    if let Some(id) = &delivery.pickup_google_place_id {
        let (coordinate, at) =
            places::cached(&tx, &principal.team_id, id)?.ok_or_else(places::unavailable)?;
        delivery.pickup = Some(coordinate);
        delivery.pickup_coordinate_fetched_at = Some(at);
    }
    if let Some(id) = &delivery.dropoff_google_place_id {
        let (coordinate, at) =
            places::cached(&tx, &principal.team_id, id)?.ok_or_else(places::unavailable)?;
        delivery.dropoff = Some(coordinate);
        delivery.dropoff_coordinate_fetched_at = Some(at);
    }
    db::save_delivery(&tx, &principal.team_id, &delivery)?;
    if let Some(key) = key {
        key.save(&tx, &principal, &delivery)?;
    }
    tx.commit()?;
    Ok((StatusCode::CREATED, Json(delivery)))
}

async fn list_restaurants(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Vec<Restaurant>>> {
    principal.require("dispatcher")?;
    Ok(Json(db::restaurants(&*state.db()?, &principal.team_id)?))
}

async fn create_restaurant(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    headers: HeaderMap,
    body: Result<Json<NewRestaurant>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Restaurant>)> {
    principal.require("dispatcher")?;
    let mut input = json_body(body)?;
    input.validate().map_err(ApiError::bad_request)?;
    let key = Idempotency::parse(&headers, "/restaurants", &input)?;
    {
        let db = state.db()?;
        if let Some(saved) = key
            .as_ref()
            .map(|key| key.replay_body::<Restaurant>(&db, &principal))
            .transpose()?
            .flatten()
        {
            db::restaurant(&db, &principal.team_id, &saved.id)?;
            return Ok((StatusCode::CREATED, Json(saved)));
        }
    }
    if let Some(id) = &input.google_place_id {
        state.resolve_place(&principal.team_id, id).await?;
    }
    let mut db = state.db()?;
    let tx = db.transaction()?;
    if let Some(saved) = key
        .as_ref()
        .map(|key| key.replay_body::<Restaurant>(&tx, &principal))
        .transpose()?
        .flatten()
    {
        db::restaurant(&tx, &principal.team_id, &saved.id)?;
        return Ok((StatusCode::CREATED, Json(saved)));
    }
    let mut coordinate_fetched_at = None;
    if let Some(id) = &input.google_place_id {
        let (coordinate, at) =
            places::cached(&tx, &principal.team_id, id)?.ok_or_else(places::unavailable)?;
        input.coordinate = Some(coordinate);
        coordinate_fetched_at = Some(at);
    }
    let restaurant = Restaurant {
        id: uuid::Uuid::new_v4().to_string(),
        name: input.name.trim().into(),
        address: input.address.trim().into(),
        coordinate: input.coordinate,
        created_at: state.clock.now(),
        google_place_id: input.google_place_id,
        coordinate_fetched_at,
    };
    db::save_restaurant(&tx, &principal.team_id, &restaurant)?;
    if let Some(key) = key {
        key.save(&tx, &principal, &restaurant)?;
    }
    tx.commit()?;
    Ok((StatusCode::CREATED, Json(restaurant)))
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadinessInput {
    ready_in_minutes: i64,
    expected_revision: u64,
}

async fn readiness(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Result<Json<ReadinessInput>, JsonRejection>,
) -> ApiResult<Json<Delivery>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let input = json_body(body)?;
    if !(0..=120).contains(&input.ready_in_minutes) {
        return Err(ApiError::bad_request(
            "Ready-in minutes must be between 0 and 120",
        ));
    }
    let key = Idempotency::parse(&headers, &format!("/deliveries/{id}/readiness"), &input)?;
    if let Some(saved) = planning_replay(&state, &principal, key.as_ref(), &id, None, false)? {
        return Ok(Json(saved));
    }
    let travel = match state
        .prepare_travel(&principal.team_id, Some(&id), None, false)
        .await
    {
        Ok(travel) => travel,
        Err(error) => {
            if let Some(saved) =
                planning_replay(&state, &principal, key.as_ref(), &id, None, false)?
            {
                return Ok(Json(saved));
            }
            return Err(error);
        }
    };
    let mut db = state.db()?;
    let tx = db.transaction()?;
    // Team ownership and capability always precede idempotency replay.
    let mut job = db::delivery(&tx, &principal.team_id, &id)?;
    if let Some(saved) = key
        .as_ref()
        .map(|key| key.replay(&tx, &principal))
        .transpose()?
        .flatten()
    {
        return Ok(Json(saved));
    }
    travel.verify(&tx)?;
    let now = state.clock.now();
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict("Readiness cannot change after pickup"));
    }
    if input.expected_revision != job.readiness_revision {
        return Err(ApiError::conflict(
            "Readiness changed; refresh the delivery and try again",
        ));
    }
    // Confirming an already-confirmed order is a no-op, even with a new key:
    // repeated taps must not extend its original pickup target.
    if !(input.ready_in_minutes == 0 && job.readiness_state == ReadinessState::Ready) {
        let mut jobs = ensure_onboard_guards(&tx, &principal.team_id, now, &travel)?;
        job.ready_at = now.saturating_add(input.ready_in_minutes * 60);
        job.readiness_state = if input.ready_in_minutes == 0 {
            ReadinessState::Ready
        } else {
            ReadinessState::Estimated
        };
        job.readiness_updated_at = Some(now);
        job.dispatch_waiting_reason = None;
        job.readiness_revision = job
            .readiness_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::conflict("Readiness revision limit reached"))?;
        if let Some(existing) = jobs.iter_mut().find(|existing| existing.id == job.id) {
            *existing = job.clone();
        }
        if let Some(driver_id) = &job.driver_id {
            let driver = db::driver(&tx, &principal.team_id, driver_id)?;
            let current = db::route_keys(&tx, &principal.team_id, driver_id)?;
            let (keys, _) = planner::replan_readiness_with_travel(
                &driver,
                &current,
                &jobs,
                &job,
                now,
                travel.times(&driver.id),
            );
            db::save_route(&tx, &principal.team_id, driver_id, &keys)?;
        }
        // Record the fact even if the updated plan is late. GET route exposes
        // hard violations; no work is removed or silently reassigned.
        db::save_delivery(&tx, &principal.team_id, &job)?;
    }
    if auto_dispatch_due(&job, now) {
        auto_assign(&tx, &principal.team_id, &mut job, now, &travel)?;
    }
    if let Some(key) = key {
        key.save(&tx, &principal, &job)?;
    }
    tx.commit()?;
    Ok(Json(job))
}

fn auto_dispatch_due(job: &Delivery, now: i64) -> bool {
    job.status == DeliveryStatus::Pending
        && job.driver_id.is_none()
        && job.readiness_revision > 0
        && job.readiness_at().is_some_and(|ready| ready <= now)
}

fn auto_assign(
    db: &Connection,
    team_id: &str,
    job: &mut Delivery,
    now: i64,
    travel: &PreparedTravel,
) -> ApiResult<bool> {
    let jobs = ensure_onboard_guards(db, team_id, now, travel)?;
    let mut choices = Vec::new();
    let mut active_drivers = 0;
    for driver in db::drivers(db, team_id)? {
        if driver.active {
            active_drivers += 1;
        }
        let current = db::route_keys(db, team_id, &driver.id)?;
        if let Some((keys, route)) = planner::insert_for_dispatch_with_travel(
            &driver,
            &current,
            &jobs,
            job,
            now,
            travel.times(&driver.id),
        ) {
            let baseline = planner::evaluate_with_travel(
                &driver,
                &current,
                &jobs,
                now,
                travel.times(&driver.id),
            );
            let position_quality = if planner::location_is_fresh(&driver, now) {
                0
            } else if driver.location.is_some() {
                1
            } else {
                2
            };
            let rank = planner::route_rank(&route, &baseline, &jobs);
            // Prefer fully feasible plans. Fallbacks prioritize known positions;
            // no-GPS queues are compared by committed load, never invented ETAs.
            let rank = if driver.location.is_none() {
                (0, 0, current.len() as i64, 0, 0)
            } else {
                rank
            };
            choices.push((
                driver.location.is_none(),
                !route.feasible,
                rank,
                position_quality,
                driver.id,
                keys,
            ));
        }
    }
    choices.sort_by(|a, b| (&a.0, &a.1, &a.2, &a.3, &a.4).cmp(&(&b.0, &b.1, &b.2, &b.3, &b.4)));
    let Some((_, _, _, _, driver_id, keys)) = choices.into_iter().next() else {
        let reason = if active_drivers == 0 {
            "no_active_driver"
        } else {
            "capacity_or_route_limit"
        };
        if job.dispatch_waiting_reason.as_deref() != Some(reason) {
            job.dispatch_waiting_reason = Some(reason.into());
            db::save_delivery(db, team_id, job)?;
        }
        return Ok(false);
    };
    job.driver_id = Some(driver_id.clone());
    job.status = DeliveryStatus::Assigned;
    job.dispatch_waiting_reason = None;
    db::save_delivery(db, team_id, job)?;
    db::save_route(db, team_id, &driver_id, &keys)?;
    Ok(true)
}

/// Older serialized jobs lack the cumulative guard. Capture it once, within the
/// first successful planning transaction, preserving their existing commitments.
fn ensure_onboard_guards(
    db: &Connection,
    team_id: &str,
    now: i64,
    travel: &PreparedTravel,
) -> ApiResult<Vec<Delivery>> {
    let mut jobs = db::planning_deliveries(db, team_id)?;
    let pending: Vec<_> = jobs
        .iter()
        .filter(|job| job.status == DeliveryStatus::PickedUp && job.onboard_deadline_at.is_none())
        .filter_map(|job| {
            job.driver_id
                .as_ref()
                .map(|driver_id| (job.id.clone(), driver_id.clone()))
        })
        .collect();
    for (id, driver_id) in pending {
        let driver = db::driver(db, team_id, &driver_id)?;
        let route = planner::evaluate_with_travel(
            &driver,
            &db::route_keys(db, team_id, &driver_id)?,
            &jobs,
            now,
            travel.times(&driver.id),
        );
        if let Some(job) = jobs.iter_mut().find(|job| job.id == id) {
            job.onboard_deadline_at = planner::onboard_deadline(job, &route, now);
            db::save_delivery(db, team_id, job)?;
        }
    }
    Ok(jobs)
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
    if let Some(saved) = planning_replay(
        &state,
        &principal,
        key.as_ref(),
        &id,
        Some(&input.driver_id),
        false,
    )? {
        return Ok(Json(saved));
    }
    let travel = match state
        .prepare_travel(&principal.team_id, Some(&id), None, false)
        .await
    {
        Ok(travel) => travel,
        Err(error) => {
            if let Some(saved) = planning_replay(
                &state,
                &principal,
                key.as_ref(),
                &id,
                Some(&input.driver_id),
                false,
            )? {
                return Ok(Json(saved));
            }
            return Err(error);
        }
    };
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
    travel.verify(&tx)?;
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict(
            "Picked-up and delivered jobs cannot be reassigned",
        ));
    }
    if job.readiness_at().is_none() {
        return Err(ApiError::conflict("Set readiness before choosing a driver"));
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
    let jobs = ensure_onboard_guards(&tx, &principal.team_id, state.clock.now(), &travel)?;
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
    let (keys, _) = planner::insert_with_travel(
        &driver,
        &current,
        &jobs,
        &job,
        state.clock.now(),
        travel.times(&driver.id),
    )
    .ok_or_else(|| {
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
        &travel,
    )? {
        if change.introduces_violation {
            return Err(ApiError::unprocessable("Reassignment introduces a new constraint violation in the previous driver's remaining route"));
        }
        db::save_route(&tx, &principal.team_id, &change.driver_id, &change.keys)?;
    }
    job.driver_id = Some(driver.id.clone());
    job.status = DeliveryStatus::Assigned;
    job.dispatch_waiting_reason = None;
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
    if let Some(saved) = planning_replay(&state, &principal, key.as_ref(), &id, None, true)? {
        return Ok(Json(saved));
    }
    let travel = if input.status == DeliveryStatus::PickedUp {
        Some(
            match state
                .prepare_travel(&principal.team_id, Some(&id), Some(&principal.id), true)
                .await
            {
                Ok(travel) => travel,
                Err(error) => {
                    if let Some(saved) =
                        planning_replay(&state, &principal, key.as_ref(), &id, None, true)?
                    {
                        return Ok(Json(saved));
                    }
                    return Err(error);
                }
            },
        )
    } else {
        None
    };
    let mut db = state.db()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    state.require_current_driver(&tx, &principal)?;
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
    if let Some(travel) = &travel {
        travel.verify(&tx)?;
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
            if job.readiness_at().is_none_or(|ready_at| now < ready_at) {
                return Err(ApiError::conflict("Delivery is not ready for pickup"));
            }
            let onboard: i32 = db::planning_deliveries(&tx, &principal.team_id)?
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
    if kind == StopKind::Pickup {
        let mut jobs = db::planning_deliveries(&tx, &principal.team_id)?;
        if let Some(existing) = jobs.iter_mut().find(|existing| existing.id == job.id) {
            *existing = job.clone();
        }
        // A confirmed pickup is an execution fact at this restaurant. Capture
        // the commitment from that stop, not a possibly stale pre-trip GPS fix.
        // This planning-only anchor never overwrites the reported GPS location.
        let mut pickup_anchor = driver.clone();
        pickup_anchor.location = job.pickup;
        pickup_anchor.location_updated_at = Some(now);
        let committed = planner::evaluate_with_travel(
            &pickup_anchor,
            &keys,
            &jobs,
            now,
            travel
                .as_ref()
                .expect("pickup has a prepared matrix")
                .times(&driver.id),
        );
        job.onboard_deadline_at = planner::onboard_deadline(&job, &committed, now);
    }
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
    travel: &PreparedTravel,
) -> ApiResult<Option<SourceRouteChange>> {
    let Some(source_id) = candidate.driver_id.as_deref() else {
        return Ok(None);
    };
    if source_id == target_driver {
        return Ok(None);
    }
    let source = db::driver(db, team_id, source_id)?;
    let mut keys = db::route_keys(db, team_id, source_id)?;
    let before = planner::evaluate_with_travel(&source, &keys, jobs, now, travel.times(&source.id));
    keys.retain(|key| key.delivery_id != candidate.id);
    let remaining: Vec<Delivery> = jobs
        .iter()
        .filter(|job| job.id != candidate.id)
        .cloned()
        .collect();
    let route =
        planner::evaluate_with_travel(&source, &keys, &remaining, now, travel.times(&source.id));
    let introduces_violation = route
        .warnings
        .iter()
        .any(|warning| !before.warnings.contains(warning))
        || planner::timing_overruns(&route, &remaining)
            .iter()
            .any(|(id, after)| {
                let before = planner::timing_overruns(&before, jobs);
                let previous = before.get(id).copied().unwrap_or([0; 3]);
                after
                    .iter()
                    .zip(previous)
                    .any(|(after, before)| *after > before)
            });
    Ok(Some(SourceRouteChange {
        driver_id: source_id.to_owned(),
        keys,
        introduces_violation,
    }))
}

async fn get_route(state: &AppState, team_id: &str, driver_id: &str) -> ApiResult<Route> {
    let travel = state
        .prepare_travel(team_id, None, Some(driver_id), false)
        .await?;
    let db = state.db()?;
    travel.verify(&db)?;
    let driver = db::driver(&db, team_id, driver_id)?;
    Ok(planner::evaluate_with_travel(
        &driver,
        &db::route_keys(&db, team_id, driver_id)?,
        &db::planning_deliveries(&db, team_id)?,
        state.clock.now(),
        travel.times(driver_id),
    ))
}
async fn own_route(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Route>> {
    principal.require("driver")?;
    Ok(Json(
        get_route(&state, &principal.team_id, &principal.id).await?,
    ))
}
async fn driver_route(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<Json<Route>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    Ok(Json(get_route(&state, &principal.team_id, &id).await?))
}
async fn suggestions(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<Json<Vec<Suggestion>>> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let travel = state
        .prepare_travel(&principal.team_id, Some(&id), None, false)
        .await?;
    let db = state.db()?;
    travel.verify(&db)?;
    let job = db::delivery(&db, &principal.team_id, &id)?;
    if matches!(
        job.status,
        DeliveryStatus::PickedUp | DeliveryStatus::Delivered
    ) {
        return Err(ApiError::conflict(
            "Suggestions are only available before pickup",
        ));
    }
    if job.readiness_at().is_none() {
        return Err(ApiError::conflict("Set readiness before choosing a driver"));
    }
    let jobs = db::planning_deliveries(&db, &principal.team_id)?;
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
        if route_after_removal(
            &db,
            &principal.team_id,
            &job,
            &driver.id,
            &jobs,
            now,
            &travel,
        )?
        .is_some_and(|change| change.introduces_violation)
        {
            continue;
        }
        if let Some((_, route)) = planner::insert_with_travel(
            &driver,
            &current,
            &jobs,
            &job,
            now,
            travel.times(&driver.id),
        ) {
            let baseline = planner::evaluate_with_travel(
                &driver,
                &current,
                &jobs,
                now,
                travel.times(&driver.id),
            );
            let priority = planner::incremental_priority_cost(&route, &baseline, &jobs);
            result.push((
                priority,
                Suggestion {
                    driver_id: driver.id,
                    incremental_travel_seconds: route.travel_seconds - baseline.travel_seconds,
                    route,
                },
            ));
        }
    }
    result.sort_by(|a, b| {
        (a.0, a.1.incremental_travel_seconds, &a.1.driver_id).cmp(&(
            b.0,
            b.1.incremental_travel_seconds,
            &b.1.driver_id,
        ))
    });
    Ok(Json(
        result
            .into_iter()
            .map(|(_, suggestion)| suggestion)
            .collect(),
    ))
}

#[cfg(test)]
mod dispatch_tests {
    use super::*;
    struct FixedClock;
    impl Clock for FixedClock {
        fn now(&self) -> i64 {
            1000
        }
    }

    #[tokio::test]
    async fn bounded_sweeps_rotate_past_blocked_work_and_never_assign_twice() {
        let dir = tempfile::tempdir().unwrap();
        let state =
            AppState::open_with_clock(dir.path().join("dispatch.db"), true, Arc::new(FixedClock))
                .unwrap();
        let mut good_id = String::new();
        {
            let db = state.db().unwrap();
            let mut driver = db::driver(&db, "demo", "driver-1").unwrap();
            driver.active = true;
            driver.capacity = 1;
            driver.location = Some(Coordinate { lat: 0.0, lng: 0.0 });
            driver.location_updated_at = Some(1000);
            db::save_driver(&db, "demo", &driver).unwrap();
            for index in 0..35 {
                let mut job = NewDelivery {
                    shop_name: format!("Fixture {index}"),
                    pickup_address: "A".into(),
                    pickup: driver.location,
                    dropoff_address: "B".into(),
                    dropoff: driver.location,
                    ready_at: Some(100 + index),
                    deadline_at: 10_000,
                    load_units: if index == 34 { 1 } else { 8 },
                    max_ride_seconds: 1800,
                    restaurant_id: None,
                    pickup_google_place_id: None,
                    dropoff_google_place_id: None,
                }
                .into_delivery(0);
                job.readiness_revision = 1;
                if index == 34 {
                    good_id = job.id.clone();
                }
                db::save_delivery(&db, "demo", &job).unwrap();
            }
        }
        assert_eq!(
            state.dispatch_ready().await.unwrap(),
            0,
            "first batch contains 32 physically oversized jobs"
        );
        assert_eq!(
            state.dispatch_ready().await.unwrap(),
            1,
            "later feasible job must not starve behind oversized work"
        );
        assert_eq!(state.dispatch_ready().await.unwrap(), 0);
        let db = state.db().unwrap();
        assert_eq!(
            db::delivery(&db, "demo", &good_id).unwrap().status,
            DeliveryStatus::Assigned
        );
        assert_eq!(db::route_keys(&db, "demo", "driver-1").unwrap().len(), 2);
        assert_eq!(
            db::deliveries(&db, "demo")
                .unwrap()
                .iter()
                .filter(|job| job.status == DeliveryStatus::Pending)
                .count(),
            34
        );
    }

    #[tokio::test]
    async fn a_fixed_cohort_retries_old_work_despite_continuous_new_arrivals() {
        let dir = tempfile::tempdir().unwrap();
        let state =
            AppState::open_with_clock(dir.path().join("fair.db"), true, Arc::new(FixedClock))
                .unwrap();
        let make_job = |index: i64, load: i32| {
            let mut job = NewDelivery {
                shop_name: format!("Fixture {index}"),
                pickup_address: "A".into(),
                pickup: Some(Coordinate { lat: 0.0, lng: 0.0 }),
                dropoff_address: "B".into(),
                dropoff: Some(Coordinate { lat: 0.0, lng: 0.0 }),
                ready_at: Some(index),
                deadline_at: 10_000,
                load_units: load,
                max_ride_seconds: 1800,
                restaurant_id: None,
                pickup_google_place_id: None,
                dropoff_google_place_id: None,
            }
            .into_delivery(0);
            job.readiness_revision = 1;
            job
        };
        let old = make_job(1, 2);
        {
            let db = state.db().unwrap();
            let mut driver = db::driver(&db, "demo", "driver-1").unwrap();
            driver.active = true;
            driver.capacity = 1;
            driver.location = Some(Coordinate { lat: 0.0, lng: 0.0 });
            driver.location_updated_at = Some(1000);
            db::save_driver(&db, "demo", &driver).unwrap();
            db::save_delivery(&db, "demo", &old).unwrap();
            for index in 2..=40 {
                db::save_delivery(&db, "demo", &make_job(index, 8)).unwrap();
            }
        }
        assert_eq!(state.dispatch_ready().await.unwrap(), 0);
        {
            let db = state.db().unwrap();
            let mut driver = db::driver(&db, "demo", "driver-1").unwrap();
            driver.capacity = 2;
            db::save_driver(&db, "demo", &driver).unwrap();
        }
        for round in 0..3 {
            {
                let db = state.db().unwrap();
                for index in 41 + round * 64..105 + round * 64 {
                    db::save_delivery(&db, "demo", &make_job(index, 8)).unwrap();
                }
            }
            state.dispatch_ready().await.unwrap();
        }
        let db = state.db().unwrap();
        assert_eq!(
            db::delivery(&db, "demo", &old.id).unwrap().status,
            DeliveryStatus::Assigned
        );
    }
}

#[cfg(test)]
mod routing_snapshot_tests {
    use super::*;
    use std::sync::atomic::Ordering;
    struct FixedClock;
    impl Clock for FixedClock {
        fn now(&self) -> i64 {
            1000
        }
    }
    fn setup() -> (AppState, Arc<routing::TestControl>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let (routing, control) = RoutingService::controlled();
        let state =
            AppState::open_with_clock(dir.path().join("routing.db"), true, Arc::new(FixedClock))
                .unwrap()
                .with_routing(routing);
        {
            let db = state.db().unwrap();
            let mut driver = db::driver(&db, "demo", "driver-1").unwrap();
            driver.active = true;
            driver.capacity = 2;
            driver.location = Some(Coordinate {
                lat: 36.715,
                lng: 15.09,
            });
            driver.location_updated_at = Some(1000);
            db::save_driver(&db, "demo", &driver).unwrap();
        }
        (state, control, dir)
    }
    fn job(state: &AppState, id: &str, due: bool) -> Delivery {
        let mut job = NewDelivery {
            shop_name: "Synthetic".into(),
            pickup_address: "A".into(),
            dropoff_address: "B".into(),
            pickup: Some(Coordinate {
                lat: 36.716,
                lng: 15.09,
            }),
            dropoff: Some(Coordinate {
                lat: 36.717,
                lng: 15.091,
            }),
            ready_at: Some(1000),
            deadline_at: 5000,
            load_units: 1,
            max_ride_seconds: 1800,
            restaurant_id: None,
            pickup_google_place_id: None,
            dropoff_google_place_id: None,
        }
        .into_delivery(1000);
        job.id = id.into();
        if due {
            job.readiness_revision = 1;
        }
        db::save_delivery(&state.db().unwrap(), "demo", &job).unwrap();
        job
    }
    fn principal(driver: bool) -> Principal {
        let role = if driver { "driver" } else { "dispatcher" };
        Principal {
            id: if driver { "driver-1" } else { "dispatcher-1" }.into(),
            name: "Fixture".into(),
            role: role.into(),
            roles: vec![role.into()],
            team_id: "demo".into(),
            team_name: "Demo".into(),
            can_delete_account: None,
        }
    }
    fn headers(key: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("idempotency-key", key.parse().unwrap());
        headers
    }
    #[tokio::test]
    async fn matrix_await_releases_sql_and_retries_changed_gps() {
        let (state, control, _dir) = setup();
        let candidate = job(&state, "a", false);
        control.block_next.store(true, Ordering::SeqCst);
        let planned = {
            let state = state.clone();
            tokio::spawn(async move { state.prepare_travel("demo", Some("a"), None, false).await })
        };
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            control.started.notified(),
        )
        .await
        .unwrap();
        let new_location = Coordinate {
            lat: 36.714,
            lng: 15.09,
        };
        {
            let db = state
                .db
                .try_lock()
                .expect("SQL must be unlocked during native work");
            let mut driver = db::driver(&db, "demo", "driver-1").unwrap();
            driver.location = Some(new_location);
            db::save_driver(&db, "demo", &driver).unwrap();
        }
        control.release.notify_one();
        let prepared = planned.await.unwrap().unwrap();
        prepared.verify(&state.db().unwrap()).unwrap();
        assert!(control.calls.load(Ordering::SeqCst) >= 2);
        assert!(prepared
            .times("driver-1")
            .seconds(new_location, candidate.pickup.unwrap())
            .is_some());
        assert_eq!(
            prepared.times("driver-1").seconds(
                Coordinate {
                    lat: 36.715,
                    lng: 15.09
                },
                candidate.pickup.unwrap()
            ),
            None
        );
    }
    #[tokio::test]
    async fn pickup_matrix_uses_restaurant_origin_without_overwriting_reported_gps() {
        let (state, _control, _dir) = setup();
        let candidate = job(&state, "a", false);
        let driver = db::driver(&state.db().unwrap(), "demo", "driver-1").unwrap();
        let gps = driver.location.unwrap();
        let pickup = state
            .prepare_travel("demo", Some("a"), Some("driver-1"), true)
            .await
            .unwrap();
        let times = pickup.times("driver-1");
        assert!(times
            .seconds(candidate.pickup.unwrap(), candidate.dropoff.unwrap())
            .is_some());
        assert_eq!(times.seconds(gps, candidate.dropoff.unwrap()), None);
        let stored = db::driver(&state.db().unwrap(), "demo", "driver-1").unwrap();
        assert_eq!(stored.location, driver.location);
        assert_eq!(stored.location_updated_at, driver.location_updated_at);
        let ordinary = state
            .prepare_travel("demo", Some("a"), Some("driver-1"), false)
            .await
            .unwrap();
        assert!(ordinary
            .times("driver-1")
            .seconds(gps, candidate.pickup.unwrap())
            .is_some());
    }
    #[tokio::test]
    async fn committed_retries_and_dropoff_do_not_wait_for_routing() {
        let (state, control, _dir) = setup();
        job(&state, "a", false);
        for repeat in [false, true] {
            control.fail_next.store(repeat, Ordering::SeqCst);
            let before = control.calls.load(Ordering::SeqCst);
            let _ = assign(
                State(state.clone()),
                Extension(principal(false)),
                Ok(Path("a".into())),
                headers("assign-replay"),
                Ok(Json(AssignInput {
                    driver_id: "driver-1".into(),
                })),
            )
            .await
            .unwrap();
            if repeat {
                assert_eq!(before, control.calls.load(Ordering::SeqCst));
            }
        }
        for repeat in [false, true] {
            control.fail_next.store(repeat, Ordering::SeqCst);
            let before = control.calls.load(Ordering::SeqCst);
            let _ = readiness(
                State(state.clone()),
                Extension(principal(false)),
                Ok(Path("a".into())),
                headers("readiness-replay"),
                Ok(Json(ReadinessInput {
                    ready_in_minutes: 0,
                    expected_revision: 0,
                })),
            )
            .await
            .unwrap();
            if repeat {
                assert_eq!(before, control.calls.load(Ordering::SeqCst));
            }
        }
        for repeat in [false, true] {
            control.fail_next.store(repeat, Ordering::SeqCst);
            let before = control.calls.load(Ordering::SeqCst);
            let _ = status(
                State(state.clone()),
                Extension(principal(true)),
                Ok(Path("a".into())),
                headers("pickup-replay"),
                Ok(Json(StatusInput {
                    status: DeliveryStatus::PickedUp,
                })),
            )
            .await
            .unwrap();
            if repeat {
                assert_eq!(before, control.calls.load(Ordering::SeqCst));
            }
        }
        control.fail_next.store(true, Ordering::SeqCst);
        let before = control.calls.load(Ordering::SeqCst);
        let Json(delivered) = status(
            State(state.clone()),
            Extension(principal(true)),
            Ok(Path("a".into())),
            headers("dropoff-no-routing"),
            Ok(Json(StatusInput {
                status: DeliveryStatus::Delivered,
            })),
        )
        .await
        .unwrap();
        assert_eq!(delivered.status, DeliveryStatus::Delivered);
        assert_eq!(before, control.calls.load(Ordering::SeqCst));
        assert!(control.fail_next.load(Ordering::SeqCst));
    }
    #[tokio::test]
    async fn one_failed_preparation_cannot_starve_later_ready_work() {
        let (state, control, _dir) = setup();
        job(&state, "a", true);
        job(&state, "b", true);
        control.fail_next.store(true, Ordering::SeqCst);
        assert_eq!(state.dispatch_ready().await.unwrap(), 1);
        {
            let db = state.db().unwrap();
            assert_eq!(
                db::delivery(&db, "demo", "a").unwrap().status,
                DeliveryStatus::Pending
            );
            assert_eq!(
                db::delivery(&db, "demo", "b").unwrap().status,
                DeliveryStatus::Assigned
            );
        }
        assert_eq!(state.dispatch_ready().await.unwrap(), 1);
    }
    #[tokio::test]
    async fn readiness_time_is_captured_after_native_wait() {
        struct MutableClock(std::sync::atomic::AtomicI64);
        impl Clock for MutableClock {
            fn now(&self) -> i64 {
                self.0.load(Ordering::SeqCst)
            }
        }
        let (mut state, control, _dir) = setup();
        job(&state, "a", false);
        let clock = Arc::new(MutableClock(std::sync::atomic::AtomicI64::new(1000)));
        state.clock = clock.clone();
        control.block_next.store(true, Ordering::SeqCst);
        let task = tokio::spawn(async move {
            readiness(
                State(state),
                Extension(principal(false)),
                Ok(Path("a".into())),
                headers("readiness-clock"),
                Ok(Json(ReadinessInput {
                    ready_in_minutes: 5,
                    expected_revision: 0,
                })),
            )
            .await
        });
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            control.started.notified(),
        )
        .await
        .unwrap();
        clock.0.store(1060, Ordering::SeqCst);
        control.release.notify_one();
        let Json(job) = task.await.unwrap().unwrap();
        assert_eq!(job.readiness_updated_at, Some(1060));
        assert_eq!(job.ready_at, 1360);
    }
}

#[cfg(test)]
mod places_budget_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct HangingResolver(AtomicUsize);
    impl places::PlaceResolver for HangingResolver {
        fn resolve<'a>(&'a self, _: &'a str) -> places::ResolveFuture<'a> {
            Box::pin(async move {
                self.0.fetch_add(1, Ordering::SeqCst);
                std::future::pending().await
            })
        }
    }
    struct FixedClock;
    impl Clock for FixedClock {
        fn now(&self) -> i64 {
            1000
        }
    }

    #[tokio::test]
    async fn stalled_refresh_is_bounded_and_cancels_outstanding_work() {
        let dir = tempfile::tempdir().unwrap();
        let resolver = Arc::new(HangingResolver(AtomicUsize::new(0)));
        let state =
            AppState::open_with_clock(dir.path().join("budget.db"), true, Arc::new(FixedClock))
                .unwrap()
                .with_places(places::PlacesService::with_resolver(resolver.clone()));
        let mut input: NewDelivery = serde_json::from_value(serde_json::json!({
            "shop_name":"My shop", "pickup_address":"My pickup", "dropoff_address":"My dropoff",
            "pickup_google_place_id":"ChIJpickup", "dropoff_google_place_id":"ChIJdropoff",
            "ready_at":1000, "deadline_at":5000,"load_units":1,"max_ride_seconds":1800
        }))
        .unwrap();
        {
            let db = state.db().unwrap();
            for index in 0..8 {
                input.pickup_google_place_id = Some(format!("ChIJpickup{index}"));
                input.dropoff_google_place_id = Some(format!("ChIJdropoff{index}"));
                let mut job = input.clone().into_delivery(1000);
                job.status = DeliveryStatus::Assigned;
                job.driver_id = Some("driver-1".into());
                db::save_delivery(&db, "demo", &job).unwrap();
            }
        }
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            state.refresh_places_with_budget(
                "demo",
                None,
                Some("driver-1"),
                std::time::Duration::from_millis(30),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(
            resolver.0.load(Ordering::SeqCst),
            4,
            "only four provider lookups can be in flight"
        );
        let db = state.db().unwrap();
        let jobs = db::planning_deliveries(&db, "demo").unwrap();
        assert_eq!(jobs.len(), 8);
        assert!(jobs
            .iter()
            .all(|job| job.pickup.is_none() && job.dropoff.is_none()));
    }

    #[tokio::test]
    async fn slow_first_candidate_does_not_starve_the_unattempted_remainder() {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::open_with_clock(
            dir.path().join("fair-places.db"),
            true,
            Arc::new(FixedClock),
        )
        .unwrap()
        .with_places(places::PlacesService::with_resolver(Arc::new(
            HangingResolver(AtomicUsize::new(0)),
        )));
        let input: NewDelivery = serde_json::from_value(serde_json::json!({
            "shop_name":"My shop", "pickup_address":"My pickup", "dropoff_address":"My dropoff",
            "pickup_google_place_id":"ChIJpickup", "dropoff_google_place_id":"ChIJdropoff",
            "ready_at":100, "deadline_at":5000,"load_units":1,"max_ride_seconds":1800
        }))
        .unwrap();
        let mut blocked = input.into_delivery(1000);
        blocked.readiness_revision = 1;
        let mut good = blocked.clone();
        good.id = "good-legacy".into();
        good.ready_at = 101;
        good.pickup_google_place_id = None;
        good.dropoff_google_place_id = None;
        good.pickup = Some(Coordinate {
            lat: 36.7,
            lng: 15.1,
        });
        good.dropoff = good.pickup;
        {
            let db = state.db().unwrap();
            let mut driver = db::driver(&db, "demo", "driver-1").unwrap();
            driver.active = true;
            driver.location = good.pickup;
            driver.location_updated_at = Some(1000);
            db::save_driver(&db, "demo", &driver).unwrap();
            db::save_delivery(&db, "demo", &blocked).unwrap();
            db::save_delivery(&db, "demo", &good).unwrap();
        }
        assert_eq!(
            state
                .dispatch_ready_with_budget(std::time::Duration::from_millis(30))
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            state
                .dispatch_ready_with_budget(std::time::Duration::from_secs(1))
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            db::delivery(&state.db().unwrap(), "demo", &good.id)
                .unwrap()
                .status,
            DeliveryStatus::Assigned
        );
    }
}
