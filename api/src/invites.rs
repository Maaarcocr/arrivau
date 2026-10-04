//! Invitation secrets are returned once, hashed at rest, and never placed in HTTP URLs.
//! Only driver membership can be delegated; dispatchers remain operator-provisioned.
use crate::{auth, json_body, path_id, ApiError, ApiResult, AppState, Authentication, Principal};
use axum::{
    extract::{
        rejection::{JsonRejection, PathRejection},
        Path, State,
    },
    http::StatusCode,
    Extension, Json,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};

const INVITE_TTL: i64 = 24 * 60 * 60;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct IssueInput {
    name: String,
}

pub(crate) async fn issue(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Result<Json<IssueInput>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    principal.require("dispatcher")?;
    let Authentication::Production(config) = state.authentication.as_ref() else {
        return Err(unavailable());
    };
    let input = json_body(body)?;
    let name = input.name.trim();
    if name.is_empty() || name.len() > 240 || name.chars().any(char::is_control) {
        return Err(ApiError::bad_request(
            "Invite name must contain 1–240 UTF-8 bytes without control characters",
        ));
    }
    let token = auth::random_token()?;
    let id = uuid::Uuid::new_v4().to_string();
    let now = state.clock.now();
    let expires_at = now + INVITE_TTL;
    let mut db = state.db()?;
    auth::reserve_attempt(
        &db,
        &format!("invite-issue:{}", principal.id),
        20,
        3600,
        now,
    )?;
    let tx = db.transaction()?;
    let issuer = auth::account_by_id(&tx, config, &principal.id)?.ok_or_else(auth::unauthorized)?;
    issuer.principal(config).require("dispatcher")?;
    if issuer.team_id(config) != principal.team_id {
        return Err(auth::unauthorized());
    }
    tx.execute("DELETE FROM invites WHERE expires_at<=?1", [now])?;
    let pending: i64 = tx.query_row(
        "SELECT COUNT(*) FROM invites WHERE team_id=?1",
        [&principal.team_id],
        |r| r.get(0),
    )?;
    if pending >= 100 {
        return Err(ApiError::conflict(
            "Too many pending invites; revoke one or wait for expiry",
        ));
    }
    tx.execute("INSERT INTO invites(id,token_hash,name,issuer_id,issuer_fingerprint,expires_at,team_id) VALUES (?1,?2,?3,?4,?5,?6,?7)", params![id,auth::digest(&token),name,issuer.id,issuer.fingerprint(config),expires_at,principal.team_id])?;
    tx.commit()?;
    Ok((
        StatusCode::CREATED,
        Json(
            json!({"id":id,"token":token,"expires_at":expires_at,"name":name,"role":"driver","team_id":principal.team_id,"team_name":principal.team_name}),
        ),
    ))
}

pub(crate) async fn revoke(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    path: Result<Path<String>, PathRejection>,
) -> ApiResult<StatusCode> {
    principal.require("dispatcher")?;
    if !matches!(state.authentication.as_ref(), Authentication::Production(_)) {
        return Err(unavailable());
    }
    let id = path_id(path)?;
    // Idempotent and secret-free; another team's dispatcher cannot revoke this invite.
    state.db()?.execute(
        "DELETE FROM invites WHERE id=?1 AND team_id=?2",
        params![id, principal.team_id],
    )?;
    Ok(StatusCode::NO_CONTENT)
}

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
    config: &auth::ProductionConfig,
    hash: &str,
    now: i64,
) -> ApiResult<(String, String)> {
    let row: Option<(String,String,String,String)> = db.query_row("SELECT name,issuer_id,issuer_fingerprint,team_id FROM invites WHERE token_hash=?1 AND expires_at>?2", params![hash,now], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    let (name, issuer_id, fingerprint, team) = row.ok_or_else(invalid_invite)?;
    let valid = auth::account_by_id(db, config, &issuer_id)?.is_some_and(|a| {
        a.has_role("dispatcher")
            && a.fingerprint(config) == fingerprint
            && a.team_id(config) == team
    });
    if !valid {
        return Err(invalid_invite());
    }
    Ok((name, team))
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
        valid_invite(&db, config, &hash, now)?;
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
    let (name, team) = valid_invite(&tx, config, &hash, now)?;
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
        role: "driver".into(),
        roles: Some(vec!["driver".into()]),
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
