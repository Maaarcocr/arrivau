//! Dispatcher-controlled removal, including safe retries of lost DELETE responses.
use crate::{auth, error::ApiResult, path_id, AppState, Authentication, Idempotency, Principal};
use axum::{
    extract::{rejection::PathRejection, Path, State},
    http::StatusCode,
    Extension,
};
use rusqlite::{params, TransactionBehavior};

pub(crate) async fn delete(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<StatusCode> {
    principal.require("dispatcher")?;
    let id = path_id(path)?;
    let mut db = state.db()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // A concurrently deleted invited account must not retain write capability.
    if let Authentication::Production(config) = state.authentication.as_ref() {
        let account =
            auth::account_by_id(&tx, config, &principal.id)?.ok_or_else(auth::unauthorized)?;
        if account.team_id(config) != principal.team_id {
            return Err(auth::unauthorized());
        }
        account.principal(config).require("dispatcher")?;
    }
    let team = &principal.team_id;
    let exists: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM deliveries WHERE team_id=?1 AND id=?2)",
        params![team, id],
        |row| row.get(0),
    )?;
    if exists {
        // Retire every saved mutation response for this delivery, across team
        // dispatchers/drivers. Old create retries must never resurrect deleted work.
        let retries: Vec<(String, String)> = {
            let mut stmt = tx.prepare(
                "SELECT principal_id,key FROM idempotency WHERE team_id=?1 AND json_extract(response,'$.id')=?2",
            )?;
            let rows = stmt.query_map(params![team, id], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect::<Result<_, _>>()?
        };
        for (principal_id, key) in retries {
            tx.execute(
                "INSERT OR IGNORE INTO idempotency_retired(scope_hash) VALUES (?1)",
                [Idempotency::scope_hash(team, &principal_id, &key)],
            )?;
            tx.execute(
                "DELETE FROM idempotency WHERE team_id=?1 AND principal_id=?2 AND key=?3",
                params![team, principal_id, key],
            )?;
        }
        // Keep the remaining route's relative order. Position gaps are supported
        // by route_keys and normalized on the next save_route.
        tx.execute(
            "DELETE FROM route_stops WHERE team_id=?1 AND delivery_id=?2",
            params![team, id],
        )?;
        tx.execute(
            "DELETE FROM deliveries WHERE team_id=?1 AND id=?2",
            params![team, id],
        )?;
        // Fence in-flight place lookups so erased destinations cannot reappear.
        crate::places::clear_team(&tx, team)?;
    }
    tx.commit()?;
    // Missing and other-team IDs are indistinguishable; retries are safe.
    Ok(StatusCode::NO_CONTENT)
}
