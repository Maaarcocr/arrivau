//! Password-confirmed, snapshot-bound hard deletion for deletable accounts.
use crate::{
    auth,
    error::{ApiError, ApiResult},
    json_body, AppState, Authentication, Idempotency,
};
use axum::{
    extract::{rejection::JsonRejection, State},
    http::StatusCode,
    Extension, Json,
};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
pub(crate) struct DeletionPreview {
    delivery_count: usize,
    active_delivery_count: usize,
    confirmation: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DeleteInput {
    password: String,
    confirmation: String,
}

fn unsupported() -> ApiError {
    ApiError::new(StatusCode::FORBIDDEN, "Self-service deletion is available only for deletable driver accounts; operator-managed accounts must be managed by the operator")
}

// Middleware authentication happens before body extraction or Argon2 work. Recheck the
// exact session, account fingerprint and immutable team inside the deletion transaction.
fn current_account(
    db: &Connection,
    config: &auth::ProductionConfig,
    session: &auth::Session,
    now: i64,
) -> ApiResult<auth::Account> {
    let hash = session.token_hash.as_ref().ok_or_else(auth::unauthorized)?;
    let fingerprint: Option<String> = db.query_row(
        "SELECT account_fingerprint FROM sessions WHERE token_hash=?1 AND account_id=?2 AND team_id=?3 AND expires_at>?4",
        params![hash, session.principal.id, session.principal.team_id, now], |r| r.get(0),
    ).optional()?;
    let account = auth::account_by_id(db, config, &session.principal.id)?
        .filter(|a| {
            a.team_id(config) == session.principal.team_id
                && fingerprint.as_deref() == Some(a.fingerprint(config).as_str())
        })
        .ok_or_else(auth::unauthorized)?;
    if !account.deletable || !account.has_role("driver") {
        return Err(unsupported());
    }
    Ok(account)
}

fn snapshot(
    db: &Connection,
    account: &auth::Account,
    config: &auth::ProductionConfig,
) -> ApiResult<DeletionPreview> {
    // Persisted JSON plus indexed identity/status bind every linked delivery field,
    // including readiness revisions, pickup and deadlines. Unrelated team/route/GPS
    // activity does not force a new confirmation of an unchanged deletion scope.
    let rows: Vec<(String, String, String)> = {
        let mut stmt = db.prepare(
            "SELECT id,status,body FROM deliveries WHERE team_id=?1 AND driver_id=?2 ORDER BY id",
        )?;
        let rows = stmt.query_map(params![account.team_id(config), account.id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?;
        rows.collect::<Result<_, _>>()?
    };
    let confirmation = auth::digest(&serde_json::to_string(&(
        "account-deletion-v1",
        &account.id,
        account.team_id(config),
        account.fingerprint(config),
        &rows,
    ))?);
    Ok(DeletionPreview {
        delivery_count: rows.len(),
        active_delivery_count: rows
            .iter()
            .filter(|(_, status, _)| status != "delivered")
            .count(),
        confirmation,
    })
}

pub(crate) async fn preview(
    State(state): State<AppState>,
    Extension(session): Extension<auth::Session>,
) -> ApiResult<Json<DeletionPreview>> {
    let Authentication::Production(config) = state.authentication.as_ref() else {
        return Err(unsupported());
    };
    let mut db = state.db()?;
    let tx = db.transaction()?;
    let account = current_account(&tx, config, &session, state.clock.now())?;
    Ok(Json(snapshot(&tx, &account, config)?))
}

fn reserve(db: &Connection, id: &str, now: i64) -> ApiResult<()> {
    for (key, max, window) in [
        ("account-delete-global".to_owned(), 30, 60),
        (format!("account-delete:{}", auth::digest(id)), 5, 300),
    ] {
        auth::reserve_attempt(db, &key, max, window, now).map_err(|error| {
            if error.status == StatusCode::TOO_MANY_REQUESTS {
                ApiError::new(
                    StatusCode::TOO_MANY_REQUESTS,
                    "Too many password confirmation attempts; try again later",
                )
            } else {
                error
            }
        })?;
    }
    Ok(())
}

pub(crate) async fn delete(
    State(state): State<AppState>,
    Extension(session): Extension<auth::Session>,
    body: Result<Json<DeleteInput>, JsonRejection>,
) -> ApiResult<StatusCode> {
    let Authentication::Production(config) = state.authentication.as_ref() else {
        return Err(unsupported());
    };
    let input = json_body(body)?;
    if input.confirmation.len() != 64
        || !input
            .confirmation
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err(ApiError::bad_request(
            "A valid deletion preview confirmation is required",
        ));
    }
    let account = {
        let db = state.db()?;
        let account = current_account(&db, config, &session, state.clock.now())?;
        reserve(&db, &account.id, state.clock.now())?;
        account
    };
    if input.password.is_empty() || input.password.len() > 1024 {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "Password confirmation failed",
        ));
    }
    let permit = state
        .auth_workers
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "Password confirmation is busy; try again shortly",
            )
        })?;
    let hash = account.password_hash.clone();
    let valid = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        auth::verify(&hash, &input.password)
    })
    .await
    .map_err(ApiError::internal)?;
    let mut db = state.db()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = current_account(&tx, config, &session, state.clock.now())?;
    if current.fingerprint(config) != account.fingerprint(config) {
        return Err(auth::unauthorized());
    }
    if !valid {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "Password confirmation failed",
        ));
    }
    if snapshot(&tx, &current, config)?.confirmation != input.confirmation {
        return Err(ApiError::conflict("Deletion preview changed; review again"));
    }
    erase(&tx, &current, config)?;
    tx.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

fn erase(
    db: &Connection,
    account: &auth::Account,
    config: &auth::ProductionConfig,
) -> ApiResult<()> {
    let team = account.team_id(config);
    // Old snapshots can reference a driver even after reassignment; find those too.
    // Surviving dispatchers keep only a non-reversible, scoped key digest so a
    // disconnected client's original create request cannot resurrect erased work.
    let retries: Vec<(String, String)> = {
        let mut stmt = db.prepare("SELECT principal_id,key FROM idempotency i WHERE team_id=?1 AND (principal_id=?2 OR EXISTS (SELECT 1 FROM json_tree(i.response) j WHERE j.type='text' AND (j.atom=?2 OR j.atom IN (SELECT id FROM deliveries WHERE team_id=?1 AND driver_id=?2))))")?;
        let rows = stmt.query_map(params![team, account.id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (principal_id, key) in retries {
        if principal_id != account.id {
            db.execute(
                "INSERT OR IGNORE INTO idempotency_retired(scope_hash) VALUES (?1)",
                [Idempotency::scope_hash(team, &principal_id, &key)],
            )?;
        }
        db.execute(
            "DELETE FROM idempotency WHERE team_id=?1 AND principal_id=?2 AND key=?3",
            params![team, principal_id, key],
        )?;
    }
    // Delete references on every route, not only the deleted driver's route.
    db.execute("DELETE FROM route_stops WHERE team_id=?1 AND (driver_id=?2 OR delivery_id IN (SELECT id FROM deliveries WHERE team_id=?1 AND driver_id=?2))", params![team, account.id])?;
    db.execute(
        "DELETE FROM deliveries WHERE team_id=?1 AND driver_id=?2",
        params![team, account.id],
    )?;
    // Google locations/failure metadata are shared only as a temporary team
    // cache. Clear them atomically and prevent pre-deletion lookups restoring
    // erased destinations; retained team records refresh on their next use.
    crate::places::clear_team(db, team)?;
    db.execute("DELETE FROM sessions WHERE account_id=?1", [&account.id])?;
    db.execute(
        "DELETE FROM drivers WHERE team_id=?1 AND id=?2",
        params![team, account.id],
    )?;
    db.execute(
        "DELETE FROM accounts WHERE team_id=?1 AND id=?2",
        params![team, account.id],
    )?;
    for key in [
        format!("user:{}", auth::digest(&account.username)),
        format!("invite-user:{}", auth::digest(&account.username)),
        format!("account-delete:{}", auth::digest(&account.id)),
    ] {
        db.execute("DELETE FROM login_limits WHERE bucket=?1", [key])?;
    }
    // Bindings protect extant history; release this one only after all references
    // are gone. Shared team/configuration and restaurants are never modified.
    db.execute(
        "DELETE FROM account_teams WHERE account_id=?1 AND team_id=?2
        AND NOT EXISTS(SELECT 1 FROM drivers WHERE id=?1)
        AND NOT EXISTS(SELECT 1 FROM deliveries WHERE driver_id=?1)
        AND NOT EXISTS(SELECT 1 FROM route_stops WHERE driver_id=?1)
        AND NOT EXISTS(SELECT 1 FROM accounts WHERE id=?1)
        AND NOT EXISTS(SELECT 1 FROM sessions WHERE account_id=?1)
        AND NOT EXISTS(SELECT 1 FROM idempotency WHERE principal_id=?1)",
        params![account.id, team],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{db, model::*, routing::RoutingService, Clock};
    use axum::{extract::Path, http::HeaderMap};
    use std::sync::{
        atomic::{AtomicI64, Ordering},
        Arc, OnceLock,
    };
    const PASSWORD: &str = "synthetic-deletion-password";
    const TEAM: &str = "deletion-fixture";

    struct TestClock(AtomicI64);
    impl Clock for TestClock {
        fn now(&self) -> i64 {
            self.0.load(Ordering::SeqCst)
        }
    }
    fn setup() -> (AppState, auth::Session, tempfile::TempDir, Arc<TestClock>) {
        static HASH: OnceLock<String> = OnceLock::new();
        let hash = HASH
            .get_or_init(|| auth::hash_password(PASSWORD).unwrap())
            .clone();
        let config = auth::ProductionConfig {
            fleet_id: TEAM.into(),
            teams: vec![],
            session_ttl_seconds: 3600,
            accounts: vec![auth::Account {
                id: "dispatcher".into(),
                username: "dispatcher".into(),
                name: "Fixture".into(),
                role: "dispatcher".into(),
                roles: None,
                team_id: None,
                password_hash: hash.clone(),
                deletable: false,
            }],
        };
        let dir = tempfile::tempdir().unwrap();
        let clock = Arc::new(TestClock(AtomicI64::new(1000)));
        let state = AppState::open_production_with_clock(
            dir.path().join("p.db"),
            config.clone(),
            clock.clone(),
        )
        .unwrap();
        let account = auth::Account {
            id: "invited-fixture".into(),
            username: "invited".into(),
            name: "Fixture".into(),
            role: "driver".into(),
            roles: Some(vec!["driver".into()]),
            team_id: Some(TEAM.into()),
            password_hash: hash,
            deletable: true,
        };
        let session = {
            let db = state.db().unwrap();
            db.execute(
                "INSERT INTO account_teams VALUES (?1,?2)",
                params![account.id, TEAM],
            )
            .unwrap();
            db.execute("INSERT INTO accounts(id,username,name,password_hash,team_id) VALUES (?1,?2,?3,?4,?5)", params![account.id, account.username, account.name, account.password_hash, TEAM]).unwrap();
            let driver = Driver {
                id: account.id.clone(),
                name: account.name.clone(),
                active: true,
                capacity: 2,
                location: Some(Coordinate {
                    lat: 36.715,
                    lng: 15.09,
                }),
                location_updated_at: Some(1000),
            };
            db.execute(
                "INSERT INTO drivers(id,team_id,body) VALUES (?1,?2,?3)",
                params![account.id, TEAM, serde_json::to_string(&driver).unwrap()],
            )
            .unwrap();
            auth::save_session(&db, &account, &config, &"a".repeat(64), 1000, 4600).unwrap();
            auth::session(&db, &config, &"a".repeat(64), 1000).unwrap()
        };
        (state, session, dir, clock)
    }
    fn dispatcher(state: &AppState) -> crate::Principal {
        let Authentication::Production(config) = state.authentication.as_ref() else {
            unreachable!()
        };
        config.accounts[0].principal(config)
    }
    fn job(state: &AppState, assigned: bool) -> Delivery {
        let mut job = NewDelivery {
            shop_name: "Fixture".into(),
            pickup_address: "A".into(),
            pickup: Some(Coordinate {
                lat: 36.716,
                lng: 15.09,
            }),
            dropoff_address: "B".into(),
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
        job.id = "fixture-job".into();
        job.readiness_revision = 1;
        if assigned {
            job.driver_id = Some("invited-fixture".into());
            job.status = DeliveryStatus::Assigned;
        }
        let db = state.db().unwrap();
        db::save_delivery(&db, TEAM, &job).unwrap();
        if assigned {
            db::save_route(
                &db,
                TEAM,
                "invited-fixture",
                &[
                    StopKey {
                        delivery_id: job.id.clone(),
                        kind: StopKind::Pickup,
                    },
                    StopKey {
                        delivery_id: job.id.clone(),
                        kind: StopKind::Dropoff,
                    },
                ],
            )
            .unwrap();
        }
        job
    }
    async fn confirmation(state: &AppState, session: &auth::Session) -> String {
        preview(State(state.clone()), Extension(session.clone()))
            .await
            .unwrap()
            .0
            .confirmation
    }
    async fn remove(
        state: AppState,
        session: auth::Session,
        confirmation: String,
    ) -> ApiResult<StatusCode> {
        delete(
            State(state),
            Extension(session),
            Ok(Json(DeleteInput {
                password: PASSWORD.into(),
                confirmation,
            })),
        )
        .await
    }
    fn exists(state: &AppState) -> bool {
        state
            .db()
            .unwrap()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM accounts WHERE id='invited-fixture')",
                [],
                |r| r.get(0),
            )
            .unwrap()
    }

    // A one-thread blocking pool lets the test hold Argon2 precisely between its
    // initial admission and transactional revalidation, without production hooks.
    async fn queued_delete(
        state: &AppState,
        session: &auth::Session,
        confirmation: String,
    ) -> (
        std::sync::mpsc::Sender<()>,
        tokio::task::JoinHandle<()>,
        tokio::task::JoinHandle<ApiResult<StatusCode>>,
    ) {
        let (release, wait) = std::sync::mpsc::channel();
        let started = Arc::new(tokio::sync::Notify::new());
        let notice = started.clone();
        let blocker = tokio::task::spawn_blocking(move || {
            notice.notify_one();
            wait.recv().unwrap();
        });
        started.notified().await;
        let task = tokio::spawn(remove(state.clone(), session.clone(), confirmation));
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while state.auth_workers.available_permits() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        (release, blocker, task)
    }

    #[test]
    fn hashing_races_recheck_session_expiry_revocation_password_and_disabled_account() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .max_blocking_threads(1)
            .build()
            .unwrap();
        runtime.block_on(async {
            for change in ["expiry", "revoke", "password", "disable"] {
                let (state, session, _dir, clock) = setup();
                job(&state, true);
                let token = confirmation(&state, &session).await;
                let (release, blocker, task) = queued_delete(&state, &session, token).await;
                match change {
                    "expiry" => {
                        clock.0.store(4600, Ordering::SeqCst);
                    }
                    "revoke" => {
                        state
                            .db()
                            .unwrap()
                            .execute("DELETE FROM sessions", [])
                            .unwrap();
                    }
                    "password" => {
                        state
                            .db()
                            .unwrap()
                            .execute("UPDATE accounts SET password_hash='changed'", [])
                            .unwrap();
                    }
                    "disable" => {
                        state
                            .db()
                            .unwrap()
                            .execute("UPDATE accounts SET disabled=1", [])
                            .unwrap();
                    }
                    _ => unreachable!(),
                }
                release.send(()).unwrap();
                blocker.await.unwrap();
                assert_eq!(
                    task.await.unwrap().unwrap_err().status,
                    StatusCode::UNAUTHORIZED,
                    "{change}"
                );
                assert!(exists(&state));
                assert!(db::delivery(&state.db().unwrap(), TEAM, "fixture-job").is_ok());
            }
        });
    }

    #[test]
    fn assignment_readiness_and_pickup_committed_during_hashing_require_new_preview() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .max_blocking_threads(1)
            .build()
            .unwrap();
        runtime.block_on(async {
            for change in ["assignment", "readiness", "pickup"] {
                let (state, session, _dir, _) = setup();
                let job = job(&state, change != "assignment");
                let token = confirmation(&state, &session).await;
                let (release, blocker, task) = queued_delete(&state, &session, token).await;
                match change {
                    "assignment" => {
                        let _ = crate::assign(
                            State(state.clone()),
                            Extension(dispatcher(&state)),
                            Ok(Path(job.id.clone())),
                            HeaderMap::new(),
                            Ok(Json(crate::AssignInput {
                                driver_id: session.principal.id.clone(),
                            })),
                        )
                        .await
                        .unwrap();
                    }
                    "readiness" => {
                        let _ = crate::readiness(
                            State(state.clone()),
                            Extension(dispatcher(&state)),
                            Ok(Path(job.id.clone())),
                            HeaderMap::new(),
                            Ok(Json(crate::ReadinessInput {
                                ready_in_minutes: 1,
                                expected_revision: job.readiness_revision,
                            })),
                        )
                        .await
                        .unwrap();
                    }
                    "pickup" => {
                        let _ = crate::status(
                            State(state.clone()),
                            Extension(session.principal.clone()),
                            Ok(Path(job.id.clone())),
                            HeaderMap::new(),
                            Ok(Json(crate::StatusInput {
                                status: DeliveryStatus::PickedUp,
                            })),
                        )
                        .await
                        .unwrap();
                    }
                    _ => unreachable!(),
                }
                release.send(()).unwrap();
                blocker.await.unwrap();
                let error = task.await.unwrap().unwrap_err();
                assert_eq!(error.status, StatusCode::CONFLICT, "{change}");
                assert_eq!(error.message, "Deletion preview changed; review again");
                assert!(exists(&state));
                let token = confirmation(&state, &session).await;
                assert_eq!(
                    remove(state.clone(), session, token).await.unwrap(),
                    StatusCode::NO_CONTENT
                );
                assert!(!exists(&state));
            }
        });
    }

    #[tokio::test]
    async fn deletion_during_native_wait_cannot_resurrect_account_or_delivery() {
        for operation in [
            "assign",
            "assign_pending",
            "readiness",
            "readiness_pending",
            "pickup",
            "auto",
        ] {
            let (state, session, _dir, _) = setup();
            let (routing, control) = RoutingService::controlled();
            let state = state.with_routing(routing);
            let retained_pending =
                matches!(operation, "auto" | "assign_pending" | "readiness_pending");
            let job = job(&state, !retained_pending);
            let token = confirmation(&state, &session).await;
            control.block_next.store(true, Ordering::SeqCst);
            let task = {
                let state = state.clone();
                let session = session.clone();
                tokio::spawn(async move {
                    match operation {
                        "assign" | "assign_pending" => crate::assign(
                            State(state.clone()),
                            Extension(dispatcher(&state)),
                            Ok(Path(job.id)),
                            HeaderMap::new(),
                            Ok(Json(crate::AssignInput {
                                driver_id: session.principal.id,
                            })),
                        )
                        .await
                        .map(|_| ()),
                        "readiness" | "readiness_pending" => crate::readiness(
                            State(state.clone()),
                            Extension(dispatcher(&state)),
                            Ok(Path(job.id)),
                            HeaderMap::new(),
                            Ok(Json(crate::ReadinessInput {
                                ready_in_minutes: 0,
                                expected_revision: job.readiness_revision,
                            })),
                        )
                        .await
                        .map(|_| ()),
                        "pickup" => crate::status(
                            State(state),
                            Extension(session.principal),
                            Ok(Path(job.id)),
                            HeaderMap::new(),
                            Ok(Json(crate::StatusInput {
                                status: DeliveryStatus::PickedUp,
                            })),
                        )
                        .await
                        .map(|_| ()),
                        "auto" => state.dispatch_ready_inner().await.map(|count| {
                            assert_eq!(count, 0);
                        }),
                        _ => unreachable!(),
                    }
                })
            };
            tokio::time::timeout(
                std::time::Duration::from_secs(5),
                control.started.notified(),
            )
            .await
            .unwrap();
            assert_eq!(
                remove(state.clone(), session, token).await.unwrap(),
                StatusCode::NO_CONTENT
            );
            control.release.notify_one();
            let outcome = task.await.unwrap();
            if !matches!(operation, "auto" | "readiness_pending") {
                assert!(outcome.is_err(), "{operation}");
            } else {
                outcome.unwrap();
            }
            assert!(!exists(&state));
            let db = state.db().unwrap();
            assert!(db::driver(&db, TEAM, "invited-fixture").is_err());
            if retained_pending {
                let pending = db::delivery(&db, TEAM, "fixture-job").unwrap();
                assert!(pending.driver_id.is_none());
                assert_eq!(pending.status, DeliveryStatus::Pending);
            } else {
                assert!(db::delivery(&db, TEAM, "fixture-job").is_err());
            }
        }
    }

    #[tokio::test]
    async fn stale_authenticated_driver_mutations_cannot_recreate_erased_profile() {
        let (state, session, _dir, _) = setup();
        let job = job(&state, true);
        let token = confirmation(&state, &session).await;
        remove(state.clone(), session.clone(), token).await.unwrap();
        assert_eq!(
            crate::shift(
                State(state.clone()),
                Extension(session.principal.clone()),
                Ok(Json(crate::ShiftInput {
                    active: true,
                    capacity: 2
                }))
            )
            .await
            .unwrap_err()
            .status,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            crate::location(
                State(state.clone()),
                Extension(session.principal.clone()),
                Ok(Json(Coordinate { lat: 1.0, lng: 2.0 }))
            )
            .await
            .unwrap_err()
            .status,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            crate::status(
                State(state.clone()),
                Extension(session.principal),
                Ok(Path(job.id)),
                HeaderMap::new(),
                Ok(Json(crate::StatusInput {
                    status: DeliveryStatus::Delivered
                }))
            )
            .await
            .unwrap_err()
            .status,
            StatusCode::UNAUTHORIZED
        );
        assert!(!exists(&state));
        assert!(db::driver(&state.db().unwrap(), TEAM, "invited-fixture").is_err());
    }

    #[tokio::test]
    async fn concurrent_deletions_commit_once_and_revoke_the_other_request() {
        let (state, session, _dir, _) = setup();
        job(&state, true);
        let token = confirmation(&state, &session).await;
        let (first, second) = tokio::join!(
            remove(state.clone(), session.clone(), token.clone()),
            remove(state.clone(), session, token),
        );
        let mut statuses = [first, second].map(|result| match result {
            Ok(status) => status.as_u16(),
            Err(error) => error.status.as_u16(),
        });
        statuses.sort();
        assert_eq!(statuses, [204, 401]);
        assert!(!exists(&state));
    }

    #[tokio::test]
    async fn deletion_uses_the_same_bounded_argon2_pool_as_signup_and_login() {
        let (state, session, _dir, _) = setup();
        let token = confirmation(&state, &session).await;
        let busy = state
            .auth_workers
            .clone()
            .acquire_many_owned(2)
            .await
            .unwrap();
        assert_eq!(
            remove(state.clone(), session.clone(), token.clone())
                .await
                .unwrap_err()
                .status,
            StatusCode::TOO_MANY_REQUESTS
        );
        assert!(exists(&state));
        drop(busy);
        assert_eq!(
            remove(state.clone(), session, token).await.unwrap(),
            StatusCode::NO_CONTENT
        );
    }

    #[tokio::test]
    async fn deletion_clears_only_its_teams_transient_places_and_keeps_restaurants() {
        let (state, session, _dir, _) = setup();
        job(&state, true);
        let coordinate = Coordinate {
            lat: 36.7,
            lng: 15.1,
        };
        {
            let db = state.db().unwrap();
            crate::places::save(&db, TEAM, "ChIJhome", coordinate, 1000).unwrap();
            crate::places::failed(&db, TEAM, "ChIJfailed", 1000).unwrap();
            crate::places::save(&db, "other-team", "ChIJhome", coordinate, 1000).unwrap();
            crate::places::failed(&db, "other-team", "ChIJfailed", 1000).unwrap();
            db::save_restaurant(
                &db,
                TEAM,
                &Restaurant {
                    id: "retained-restaurant".into(),
                    name: "User-owned restaurant name".into(),
                    address: "User-owned address".into(),
                    coordinate: Some(coordinate),
                    created_at: 1000,
                    google_place_id: Some("ChIJhome".into()),
                    coordinate_fetched_at: Some(1000),
                },
            )
            .unwrap();
        }
        let token = confirmation(&state, &session).await;
        remove(state.clone(), session, token).await.unwrap();
        let db = state.db().unwrap();
        assert!(crate::places::cached(&db, TEAM, "ChIJhome")
            .unwrap()
            .is_none());
        assert!(!crate::places::retry_blocked(&db, TEAM, "ChIJfailed").unwrap());
        assert!(crate::places::cached(&db, "other-team", "ChIJhome")
            .unwrap()
            .is_some());
        assert!(crate::places::retry_blocked(&db, "other-team", "ChIJfailed").unwrap());
        assert_eq!(crate::places::generation(&db, TEAM).unwrap(), 1);
        assert_eq!(crate::places::generation(&db, "other-team").unwrap(), 0);
        let restaurant = db::restaurant(&db, TEAM, "retained-restaurant").unwrap();
        assert_eq!(restaurant.name, "User-owned restaurant name");
        assert_eq!(restaurant.google_place_id.as_deref(), Some("ChIJhome"));
        assert!(restaurant.coordinate.is_none());
    }

    struct DelayedPlaces {
        calls: std::sync::atomic::AtomicUsize,
        started: tokio::sync::Notify,
        release: tokio::sync::Semaphore,
        fail: bool,
    }
    impl crate::places::PlaceResolver for DelayedPlaces {
        fn resolve<'a>(&'a self, _: &'a str) -> crate::places::ResolveFuture<'a> {
            Box::pin(async move {
                if self.calls.fetch_add(1, Ordering::SeqCst) + 1 == 4 {
                    self.started.notify_one();
                }
                self.release.acquire().await.unwrap().forget();
                if self.fail {
                    Err("synthetic provider outage".into())
                } else {
                    Ok(Coordinate {
                        lat: 36.7,
                        lng: 15.1,
                    })
                }
            })
        }
    }

    #[tokio::test]
    async fn deletion_fences_inflight_places_and_not_yet_started_snapshot_lookups() {
        for fail in [false, true] {
            let (state, session, _dir, _) = setup();
            let resolver = Arc::new(DelayedPlaces {
                calls: std::sync::atomic::AtomicUsize::new(0),
                started: tokio::sync::Notify::new(),
                release: tokio::sync::Semaphore::new(0),
                fail,
            });
            let state = state.with_places(crate::places::PlacesService::with_resolver(
                resolver.clone(),
            ));
            let base = job(&state, true);
            {
                let db = state.db().unwrap();
                for index in 0..3 {
                    let mut job = base.clone();
                    if index > 0 {
                        job.id = format!("linked-{index}");
                    }
                    job.pickup_google_place_id = Some(format!("ChIJpickup{index}"));
                    job.dropoff_google_place_id = Some(format!("ChIJdropoff{index}"));
                    db::save_delivery(&db, TEAM, &job).unwrap();
                }
            }
            let token = confirmation(&state, &session).await;
            let task = {
                let state = state.clone();
                tokio::spawn(async move {
                    state
                        .refresh_places(TEAM, None, Some("invited-fixture"))
                        .await
                })
            };
            tokio::time::timeout(
                std::time::Duration::from_secs(5),
                resolver.started.notified(),
            )
            .await
            .unwrap();
            remove(state.clone(), session, token).await.unwrap();
            resolver.release.add_permits(4);
            task.await.unwrap().unwrap();
            // Four requests were awaiting the provider; the other two IDs were
            // in the pre-deletion snapshot and must never start provider work.
            assert_eq!(resolver.calls.load(Ordering::SeqCst), 4);
            let db = state.db().unwrap();
            for table in ["google_place_cache", "google_place_failures"] {
                let count: i64 = db
                    .query_row(
                        &format!("SELECT COUNT(*) FROM {table} WHERE team_id=?1"),
                        [TEAM],
                        |row| row.get(0),
                    )
                    .unwrap();
                assert_eq!(count, 0, "late provider result restored {table}");
            }
        }
    }
}
