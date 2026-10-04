//! Operator-managed accounts and invite-only drivers share team-bound session checks.
//! The configuration is authoritative on startup; account changes invalidate sessions.
use crate::{
    error::{ApiError, ApiResult},
    Principal,
};
use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, SaltString},
    Argon2, PasswordHasher, PasswordVerifier,
};
use axum::http::StatusCode;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Account {
    pub id: String,
    pub username: String,
    pub name: String,
    #[serde(default)]
    pub role: String,
    #[serde(default)]
    pub roles: Option<Vec<String>>,
    #[serde(default)]
    pub team_id: Option<String>,
    pub password_hash: String,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Team {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProductionConfig {
    pub fleet_id: String,
    #[serde(default)]
    pub teams: Vec<Team>,
    pub session_ttl_seconds: i64,
    pub accounts: Vec<Account>,
}

impl ProductionConfig {
    pub fn validate(&self) -> Result<(), String> {
        if !valid_identifier(&self.fleet_id) || !(300..=86400).contains(&self.session_ttl_seconds) {
            return Err(
                "fleet_id must be a stable identifier; session_ttl_seconds must be 300–86400"
                    .into(),
            );
        }
        if self.accounts.is_empty() || self.accounts.len() > 100 {
            return Err("Configure 1–100 individual accounts".into());
        }
        let mut team_ids = HashSet::new();
        for team in &self.teams {
            if !valid_identifier(&team.id)
                || !team_ids.insert(&team.id)
                || team.name.trim().is_empty()
                || team.name.len() > 240
            {
                return Err("Teams need unique stable ids and names of 1–240 bytes".into());
            }
        }
        if self.teams.len() > 100 || (!self.teams.is_empty() && !team_ids.contains(&self.fleet_id))
        {
            return Err(
                "Configure at most 100 teams including fleet_id, the permanent legacy/default team"
                    .into(),
            );
        }
        let (mut ids, mut names) = (HashSet::new(), HashSet::new());
        for account in &self.accounts {
            if !valid_identifier(&account.id)
                || !valid_identifier(&account.username)
                || account.username != account.username.to_ascii_lowercase()
                || !ids.insert(&account.id)
                || !names.insert(&account.username)
                || account.name.trim().is_empty()
                || account.name.len() > 240
            {
                return Err("Accounts need unique ids and lowercase usernames, names, and driver/dispatcher roles".into());
            }
            let roles = account.capabilities();
            if roles.is_empty()
                || roles
                    .iter()
                    .any(|role| !matches!(role.as_str(), "driver" | "dispatcher"))
                || account
                    .roles
                    .as_ref()
                    .is_some_and(|r| r.len() != roles.len())
                || (!account.role.is_empty() && !roles.contains(&account.role))
            {
                return Err("Accounts need one or both unique driver/dispatcher capabilities; role must belong to roles".into());
            }
            let team = account.team_id(self);
            if !valid_identifier(team)
                || (team != self.fleet_id && !team_ids.contains(&team.to_owned()))
            {
                return Err("Every account must belong to a configured team".into());
            }
            let hash =
                PasswordHash::new(&account.password_hash).map_err(|_| "Invalid password hash")?;
            let m = hash.params.get_decimal("m").unwrap_or(0);
            let t = hash.params.get_decimal("t").unwrap_or(0);
            let p = hash.params.get_decimal("p").unwrap_or(0);
            let mut salt_bytes = [0u8; 64];
            let salt_len = hash
                .salt
                .and_then(|salt| salt.decode_b64(&mut salt_bytes).ok())
                .map_or(0, |salt| salt.len());
            let hash_len = hash.hash.as_ref().map_or(0, |output| output.len());
            if hash.algorithm.as_str() != "argon2id"
                || hash.version != Some(19)
                || !(19456..=262144).contains(&m)
                || !(2..=10).contains(&t)
                || !(1..=8).contains(&p)
                || salt_len < 16
                || hash_len < 32
            {
                return Err(
                    "Use Argon2id v19 password hashes (m=19456–262144 KiB, t=2–10, p=1–8, salt>=16 bytes, output>=32 bytes)".into(),
                );
            }
        }
        if !self.accounts.iter().any(|a| a.has_role("dispatcher")) {
            return Err("Configure at least one dispatcher".into());
        }
        Ok(())
    }
}

pub(crate) fn valid_identifier(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_alphanumeric)
        && value.len() <= 64
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

pub fn hash_password(password: &str) -> Result<String, String> {
    if !(12..=1024).contains(&password.len()) {
        return Err("Password must contain 12–1024 UTF-8 bytes".into());
    }
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|_| "Password hashing failed".into())
}

pub(crate) fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

impl Account {
    pub(crate) fn capabilities(&self) -> Vec<String> {
        let mut roles = self
            .roles
            .clone()
            .unwrap_or_else(|| vec![self.role.clone()]);
        roles.sort();
        roles.dedup();
        roles
    }
    pub(crate) fn has_role(&self, role: &str) -> bool {
        self.capabilities().iter().any(|r| r == role)
    }
    pub(crate) fn primary_role(&self) -> String {
        if !self.role.is_empty() {
            self.role.clone()
        } else if self.has_role("dispatcher") {
            "dispatcher".into()
        } else {
            "driver".into()
        }
    }
    pub(crate) fn team_id<'a>(&'a self, config: &'a ProductionConfig) -> &'a str {
        self.team_id.as_deref().unwrap_or(&config.fleet_id)
    }
    pub(crate) fn principal(&self, config: &ProductionConfig) -> Principal {
        let team_id = self.team_id(config);
        Principal {
            id: self.id.clone(),
            name: self.name.clone(),
            role: self.primary_role(),
            roles: self.capabilities(),
            team_id: team_id.into(),
            team_name: config
                .teams
                .iter()
                .find(|t| t.id == team_id)
                .map(|t| t.name.clone())
                .unwrap_or_else(|| team_id.into()),
            can_delete_account: (!config.accounts.iter().any(|a| a.id == self.id)).then_some(true),
        }
    }
    pub(crate) fn fingerprint(&self, config: &ProductionConfig) -> String {
        let role = self.primary_role();
        // Preserve existing single-role sessions when upgrading an unchanged legacy config.
        // New capabilities or non-default team identity use an explicitly scoped fingerprint.
        if self.team_id(config) == config.fleet_id && self.capabilities() == vec![role.clone()] {
            return digest(
                &serde_json::to_string(&(
                    &self.id,
                    &self.username,
                    &self.name,
                    &role,
                    &self.password_hash,
                ))
                .expect("strings serialize"),
            );
        }
        digest(
            &serde_json::to_string(&(
                &self.id,
                &self.username,
                &self.name,
                &role,
                &self.password_hash,
                self.capabilities(),
                self.team_id(config),
            ))
            .expect("strings serialize"),
        )
    }
}

pub(crate) fn initialize(db: &mut Connection, config: &ProductionConfig) -> ApiResult<()> {
    let tx = db.transaction()?;
    // Neither identity source may silently replace the other, even when disabled.
    for account in &config.accounts {
        let collision: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM invited_accounts WHERE id=?1 OR username=?2)",
            params![account.id, account.username],
            |r| r.get(0),
        )?;
        if collision {
            return Err(ApiError::conflict("Configured and invited account identities collide; keep the existing identities distinct"));
        }
    }
    // Permanent bindings prevent removed/re-added accounts and driver IDs from moving history.
    // Validate ALL identities before modifying profiles or revoking sessions.
    for account in &config.accounts {
        let existing: Option<String> = tx
            .query_row(
                "SELECT team_id FROM account_teams WHERE account_id=?1",
                [&account.id],
                |r| r.get(0),
            )
            .optional()?;
        if existing
            .as_deref()
            .is_some_and(|team| team != account.team_id(config))
        {
            return Err(ApiError::bad_request(
                "An existing account ID cannot move teams; provision a new unique ID",
            ));
        }
    }
    for account in &config.accounts {
        tx.execute(
            "INSERT OR IGNORE INTO account_teams(account_id,team_id) VALUES (?1,?2)",
            params![account.id, account.team_id(config)],
        )?;
    }
    let driver_rows: Vec<(String, String)> = {
        let mut stmt = tx.prepare("SELECT team_id,body FROM drivers")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (team_id, body) in driver_rows {
        let mut driver: crate::model::Driver = serde_json::from_str(&body)?;
        if !account_by_id(&tx, config, &driver.id)?
            .is_some_and(|a| a.has_role("driver") && a.team_id(config) == team_id)
        {
            driver.active = false;
            crate::db::save_driver(&tx, &team_id, &driver)?;
        }
    }
    for account in &config.accounts {
        if account.has_role("driver") {
            let existing: Option<String> = tx
                .query_row(
                    "SELECT body FROM drivers WHERE id=?1 AND team_id=?2",
                    params![account.id, account.team_id(config)],
                    |r| r.get(0),
                )
                .optional()?;
            let mut driver = match existing {
                Some(body) => serde_json::from_str::<crate::model::Driver>(&body)?,
                None => crate::model::Driver {
                    id: account.id.clone(),
                    name: account.name.clone(),
                    active: false,
                    capacity: 2,
                    location: None,
                    location_updated_at: None,
                },
            };
            driver.name = account.name.clone();
            tx.execute("INSERT INTO drivers(id,team_id,body) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET body=excluded.body WHERE drivers.team_id=excluded.team_id",
                params![driver.id,account.team_id(config),serde_json::to_string(&driver)?])?;
        }
    }
    let sessions: Vec<(String, String, String, String)> = {
        let mut stmt =
            tx.prepare("SELECT token_hash,account_id,account_fingerprint,team_id FROM sessions")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (token, id, fingerprint, team) in sessions {
        if !account_by_id(&tx, config, &id)?
            .is_some_and(|a| a.team_id(config) == team && a.fingerprint(config) == fingerprint)
        {
            tx.execute("DELETE FROM sessions WHERE token_hash=?1", [token])?;
        }
    }
    // Removal/capability changes revoke pending secrets permanently, even if config is restored.
    let invitations: Vec<(String, String, String, String)> = {
        let mut stmt = tx.prepare("SELECT id,issuer_id,issuer_fingerprint,team_id FROM invites")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (id, issuer, fingerprint, team) in invitations {
        if !account_by_id(&tx, config, &issuer)?.is_some_and(|a| {
            a.has_role("dispatcher")
                && a.team_id(config) == team
                && a.fingerprint(config) == fingerprint
        }) {
            tx.execute("DELETE FROM invites WHERE id=?1", [id])?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub(crate) fn unauthorized() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "A valid, unexpired session is required",
    )
}

#[derive(Clone)]
pub(crate) struct Session {
    pub principal: Principal,
    pub expires_at: Option<i64>,
    pub token_hash: Option<String>,
}

#[derive(Serialize)]
pub(crate) struct SessionIdentity {
    pub user: Principal,
    pub expires_at: Option<i64>,
}

pub(crate) fn session(
    db: &Connection,
    config: &ProductionConfig,
    token: &str,
    now: i64,
) -> ApiResult<Session> {
    if token.len() != 64 || !token.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(unauthorized());
    }
    let token_hash = digest(token);
    let row: Option<(String,String,i64,String)> = db.query_row("SELECT account_id,account_fingerprint,expires_at,team_id FROM sessions WHERE token_hash=?1 AND expires_at>?2",params![token_hash,now],|r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    let (id, fingerprint, expires_at, team_id) = row.ok_or_else(unauthorized)?;
    let account = account_by_id(db, config, &id)?
        .filter(|a| a.fingerprint(config) == fingerprint && a.team_id(config) == team_id)
        .ok_or_else(unauthorized)?;
    Ok(Session {
        principal: account.principal(config),
        expires_at: Some(expires_at),
        token_hash: Some(token_hash),
    })
}

pub(crate) fn reserve_login(db: &Connection, username: &str, now: i64) -> ApiResult<()> {
    db.execute("DELETE FROM login_limits WHERE reset_at<=?1", [now])?;
    // Account-independent global and per-name limits also cover unknown usernames.
    for (key, max, window) in [
        ("global".to_owned(), 60, 60),
        (format!("user:{}", digest(username)), 10, 300),
    ] {
        let count: i64 = db.query_row(
            "SELECT COALESCE((SELECT attempts FROM login_limits WHERE bucket=?1),0)",
            [&key],
            |r| r.get(0),
        )?;
        if count >= max {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "Too many login attempts; try again later",
            ));
        }
        db.execute("INSERT INTO login_limits(bucket,attempts,reset_at) VALUES (?1,1,?2) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1",params![key,now+window])?;
    }
    Ok(())
}

pub(crate) fn verify(hash: &str, password: &str) -> bool {
    PasswordHash::new(hash).ok().is_some_and(|parsed| {
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok()
    })
}

pub(crate) fn configured_team(config: &ProductionConfig, team: &str) -> bool {
    team == config.fleet_id || config.teams.iter().any(|t| t.id == team)
}

fn invited_account(row: &rusqlite::Row<'_>) -> rusqlite::Result<Account> {
    Ok(Account {
        id: row.get(0)?,
        username: row.get(1)?,
        name: row.get(2)?,
        role: "driver".into(),
        roles: Some(vec!["driver".into()]),
        team_id: Some(row.get(4)?),
        password_hash: row.get(3)?,
    })
}

pub(crate) fn account_by_id(
    db: &Connection,
    config: &ProductionConfig,
    id: &str,
) -> ApiResult<Option<Account>> {
    if let Some(account) = config.accounts.iter().find(|a| a.id == id) {
        return Ok(Some(account.clone()));
    }
    Ok(db.query_row("SELECT i.id,i.username,i.name,i.password_hash,i.team_id FROM invited_accounts i JOIN account_teams a ON a.account_id=i.id AND a.team_id=i.team_id WHERE i.id=?1 AND i.disabled=0", [id], invited_account).optional()?.filter(|a| configured_team(config,a.team_id(config))))
}

pub(crate) fn account_by_username(
    db: &Connection,
    config: &ProductionConfig,
    username: &str,
) -> ApiResult<Option<Account>> {
    if let Some(account) = config.accounts.iter().find(|a| a.username == username) {
        return Ok(Some(account.clone()));
    }
    Ok(db.query_row("SELECT i.id,i.username,i.name,i.password_hash,i.team_id FROM invited_accounts i JOIN account_teams a ON a.account_id=i.id AND a.team_id=i.team_id WHERE i.username=?1 AND i.disabled=0", [username], invited_account).optional()?.filter(|a| configured_team(config,a.team_id(config))))
}

pub(crate) fn random_token() -> ApiResult<String> {
    use rand_core::RngCore;
    let mut bytes = [0u8; 32];
    OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(ApiError::internal)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub(crate) fn save_session(
    db: &Connection,
    account: &Account,
    config: &ProductionConfig,
    token: &str,
    now: i64,
    expires_at: i64,
) -> ApiResult<()> {
    db.execute("DELETE FROM sessions WHERE expires_at<=?1", [now])?;
    db.execute("DELETE FROM sessions WHERE account_id=?1 AND token_hash NOT IN (SELECT token_hash FROM sessions WHERE account_id=?1 ORDER BY created_at DESC,rowid DESC LIMIT 9)", [&account.id])?;
    db.execute("INSERT INTO sessions(token_hash,account_id,account_fingerprint,expires_at,created_at,team_id) VALUES (?1,?2,?3,?4,?5,?6)",params![digest(token),account.id,account.fingerprint(config),expires_at,now,account.team_id(config)])?;
    Ok(())
}

pub(crate) fn reserve_attempt(
    db: &Connection,
    key: &str,
    max: i64,
    window: i64,
    now: i64,
) -> ApiResult<()> {
    db.execute("DELETE FROM login_limits WHERE reset_at<=?1", [now])?;
    let count: i64 = db.query_row(
        "SELECT COALESCE((SELECT attempts FROM login_limits WHERE bucket=?1),0)",
        [key],
        |r| r.get(0),
    )?;
    if count >= max {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many invite attempts; try again later",
        ));
    }
    db.execute("INSERT INTO login_limits(bucket,attempts,reset_at) VALUES (?1,1,?2) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1", params![key,now+window])?;
    Ok(())
}

/// Offline operator recovery: disable an invited driver without deleting delivery history.
/// Opens only an existing production DB; never accepts passwords or creates credentials.
pub fn disable_invited_account(path: &std::path::Path, username: &str) -> Result<(), String> {
    if !path.is_absolute()
        || !valid_identifier(username)
        || username != username.to_ascii_lowercase()
    {
        return Err("Use an absolute production database path and exact lowercase username".into());
    }
    let run = || -> ApiResult<()> {
        let mut db =
            Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        let tx = db.transaction()?;
        let mode: String =
            tx.query_row("SELECT value FROM deployment WHERE key='mode'", [], |r| {
                r.get(0)
            })?;
        if !mode.starts_with("production:") {
            return Err(ApiError::bad_request("Use the production database"));
        }
        let (id, team): (String,String) = tx.query_row("SELECT id,team_id FROM invited_accounts WHERE username=?1", [username], |r| Ok((r.get(0)?,r.get(1)?))).optional()?.ok_or_else(|| ApiError::not_found("Invited account not found; configured accounts are managed in the auth configuration"))?;
        tx.execute("UPDATE invited_accounts SET disabled=1 WHERE id=?1", [&id])?;
        tx.execute("DELETE FROM sessions WHERE account_id=?1", [&id])?;
        let mut driver = crate::db::driver(&tx, &team, &id)?;
        driver.active = false;
        crate::db::save_driver(&tx, &team, &driver)?;
        tx.commit()?;
        Ok(())
    };
    run().map_err(|e| e.message)
}
