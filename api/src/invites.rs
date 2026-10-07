//! Invitation secrets are hashed at rest. Invites are minted by operator script,
//! never via the API; redemption creates the account with the invite's role.
use crate::{auth, json_body, ApiError, ApiResult, AppState, Authentication};
use axum::{
    extract::{rejection::JsonRejection, State},
    http::StatusCode,
    Json,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RedeemInput {
    token: String,
    username: String,
    password: String,
}

fn unavailable() -> ApiError {
    ApiError::not_found("Invitations are unavailable in isolated demo mode")
}
fn invalid_invite() -> ApiError {
    ApiError::bad_request("Invite is invalid, expired or already used")
}

fn valid_invite(
    db: &Connection,
    hash: &str,
    now: i64,
) -> ApiResult<(String, String, String)> {
    let row: Option<(String, String, String)> = db.query_row("SELECT name,team_id,role FROM invites WHERE token_hash=?1 AND expires_at>?2", params![hash,now], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    row.ok_or_else(invalid_invite)
}
fn username_available(
    db: &Connection,
    config: &auth::ProductionConfig,
    username: &str,
) -> ApiResult<()> {
    let used: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM invited_accounts WHERE username=?1)",
        [username],
        |r| r.get(0),
    )?;
    if used || config.accounts.iter().any(|a| a.username == username) {
        return Err(ApiError::conflict("Username is unavailable"));
    }
    Ok(())
}

pub(crate) async fn redeem(
    State(state): State<AppState>,
    body: Result<Json<RedeemInput>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let Authentication::Production(config) = state.authentication.as_ref() else {
        return Err(unavailable());
    };
    let input = json_body(body)?;
    let username = input.username.trim().to_ascii_lowercase();
    let hash = auth::digest(&input.token);
    {
        let db = state.db()?;
        let now = state.clock.now();
        // Global limiter bounds random-token traffic. Token/name buckets bound targeted hashing.
        auth::reserve_attempt(&db, "invite-redeem-global", 60, 60, now)?;
        auth::reserve_attempt(&db, &format!("invite-token:{hash}"), 10, 300, now)?;
        auth::reserve_attempt(
            &db,
            &format!("invite-user:{}", auth::digest(&username)),
            10,
            300,
            now,
        )?;
        if input.token.len() != 64
            || !input
                .token
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err(invalid_invite());
        }
        valid_invite(&db, &hash, now)?;
        if !auth::valid_identifier(&username) || input.username.len() > 64 {
            return Err(ApiError::bad_request("Username must be 1–64 ASCII letters, digits, dots, underscores or hyphens, starting with a letter or digit"));
        }
        if !(12..=1024).contains(&input.password.len()) {
            return Err(ApiError::bad_request(
                "Password must contain 12–1024 UTF-8 bytes",
            ));
        }
        username_available(&db, config, &username)?;
    }
    let permit = state
        .auth_workers
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "Signup is busy; try again shortly",
            )
        })?;
    let password_hash = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        auth::hash_password(&input.password)
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::internal)?;
    let token = auth::random_token()?;
    let mut db = state.db()?;
    let tx = db.transaction()?;
    // Recheck everything after expensive hashing, under the same transaction as consumption.
    let now = state.clock.now();
    let (name, team, role) = valid_invite(&tx, &hash, now)?;
    username_available(&tx, config, &username)?;
    let count: i64 = tx.query_row(
        "SELECT COUNT(*) FROM invited_accounts WHERE team_id=?1",
        [&team],
        |r| r.get(0),
    )?;
    if count >= 100 {
        return Err(ApiError::conflict(
            "Pilot account limit reached; contact the operator",
        ));
    }
    let account = auth::Account {
        id: format!("invited-{}", uuid::Uuid::new_v4()),
        username,
        name,
        role: role.clone(),
        roles: Some(vec![role.clone()]),
        team_id: Some(team.clone()),
        password_hash,
    };
    // Reserve generated ids against configured and historic domain identities too.
    let used: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM account_teams WHERE account_id=?1)",
        [&account.id],
        |r| r.get(0),
    )?;
    if used || config.accounts.iter().any(|a| a.id == account.id) {
        return Err(ApiError::conflict(
            "Could not allocate account identity; retry",
        ));
    }
    tx.execute(
        "INSERT INTO account_teams(account_id,team_id) VALUES (?1,?2)",
        params![account.id, team],
    )?;
    tx.execute("INSERT INTO invited_accounts(id,username,name,password_hash,team_id) VALUES (?1,?2,?3,?4,?5)", params![account.id,account.username,account.name,account.password_hash,team])?;
    let driver = crate::model::Driver {
        id: account.id.clone(),
        name: account.name.clone(),
        active: false,
        capacity: 2,
        location: None,
        location_updated_at: None,
    };
    tx.execute(
        "INSERT INTO drivers(id,body,team_id) VALUES (?1,?2,?3)",
        params![driver.id, serde_json::to_string(&driver)?, team],
    )?;
    tx.execute("DELETE FROM invites WHERE token_hash=?1", [&hash])?;
    let expires_at = now + config.session_ttl_seconds;
    auth::save_session(&tx, &account, config, &token, now, expires_at)?;
    tx.commit()?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"token":token,"expires_at":expires_at,"user":account.principal(config)})),
    ))
}
