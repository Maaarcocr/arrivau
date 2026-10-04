//! Single-fleet pilot accounts are provisioned offline, never by a public signup.
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
    pub role: String,
    pub password_hash: String,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProductionConfig {
    pub fleet_id: String,
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
        let (mut ids, mut names) = (HashSet::new(), HashSet::new());
        for account in &self.accounts {
            if !valid_identifier(&account.id)
                || !valid_identifier(&account.username)
                || account.username != account.username.to_ascii_lowercase()
                || !ids.insert(&account.id)
                || !names.insert(&account.username)
                || account.name.trim().is_empty()
                || account.name.len() > 240
                || !matches!(account.role.as_str(), "driver" | "dispatcher")
            {
                return Err("Accounts need unique ids and lowercase usernames, names, and driver/dispatcher roles".into());
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
        if !self.accounts.iter().any(|a| a.role == "dispatcher") {
            return Err("Configure at least one dispatcher".into());
        }
        Ok(())
    }
}

fn valid_identifier(value: &str) -> bool {
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
    pub(crate) fn principal(&self) -> Principal {
        Principal {
            id: self.id.clone(),
            name: self.name.clone(),
            role: self.role.clone(),
        }
    }
    pub(crate) fn fingerprint(&self) -> String {
        digest(
            &serde_json::to_string(&(
                &self.id,
                &self.username,
                &self.name,
                &self.role,
                &self.password_hash,
            ))
            .expect("strings serialize"),
        )
    }
}

pub(crate) fn initialize(db: &mut Connection, config: &ProductionConfig) -> ApiResult<()> {
    let tx = db.transaction()?;
    // Removed accounts remain in domain history, but cannot authenticate or receive work.
    let drivers = crate::db::drivers(&tx)?;
    for mut driver in drivers {
        if !config
            .accounts
            .iter()
            .any(|a| a.id == driver.id && a.role == "driver")
        {
            driver.active = false;
            crate::db::save_driver(&tx, &driver)?;
        }
    }
    for account in &config.accounts {
        if account.role == "driver" {
            let existing: Option<String> = tx
                .query_row("SELECT body FROM drivers WHERE id=?1", [&account.id], |r| {
                    r.get(0)
                })
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
            tx.execute("INSERT INTO drivers(id,body) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET body=excluded.body", params![driver.id,serde_json::to_string(&driver)?])?;
        }
    }
    let sessions: Vec<(String, String, String)> = {
        let mut stmt =
            tx.prepare("SELECT token_hash,account_id,account_fingerprint FROM sessions")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (token, id, fingerprint) in sessions {
        if !config
            .accounts
            .iter()
            .any(|a| a.id == id && a.fingerprint() == fingerprint)
        {
            tx.execute("DELETE FROM sessions WHERE token_hash=?1", [token])?;
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
    let row: Option<(String,String,i64)> = db.query_row("SELECT account_id,account_fingerprint,expires_at FROM sessions WHERE token_hash=?1 AND expires_at>?2",params![token_hash,now],|r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let (id, fingerprint, expires_at) = row.ok_or_else(unauthorized)?;
    let account = config
        .accounts
        .iter()
        .find(|a| a.id == id && a.fingerprint() == fingerprint)
        .ok_or_else(unauthorized)?;
    Ok(Session {
        principal: account.principal(),
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
