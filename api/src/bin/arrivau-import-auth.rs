//! One-time operator import: legacy auth.json (teams + static accounts) into the database.
//!
//! Run once against a stopped API, before the first boot of the DB-backed auth
//! release:
//!   arrivau-import-auth /absolute/pilot.sqlite3 /absolute/auth.json
//!
//! Imported accounts are operator-managed (not self-deletable), matching the
//! old file-based semantics. Safe to re-run: inserts are idempotent.
use rusqlite::params;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        return Err(
            "Usage: arrivau-import-auth /absolute/pilot.sqlite3 /absolute/auth.json".into(),
        );
    }
    let db_path = std::path::Path::new(&args[0]);
    let auth_path = std::path::Path::new(&args[1]);
    if !db_path.is_absolute() || !auth_path.is_absolute() {
        return Err("Both paths must be absolute".into());
    }
    let raw = std::fs::read_to_string(auth_path)?;
    let legacy: serde_json::Value = serde_json::from_str(&raw)?;
    let fleet_id = legacy
        .get("fleet_id")
        .and_then(|v| v.as_str())
        .ok_or("auth.json: missing fleet_id")?;
    if !arrivau_api::auth::valid_identifier(fleet_id) {
        return Err("auth.json: invalid fleet_id".into());
    }
    // Opening runs the v8 schema migration (teams table, accounts table).
    let mut db = arrivau_api::db::open(db_path, &format!("production:{fleet_id}"), fleet_id, &[])
        .map_err(|e| format!("open db: {}", e.message))?;
    let tx = db.transaction().map_err(|e| format!("begin tx: {e}"))?;

    let mut team_count = 0usize;
    if let Some(teams) = legacy.get("teams").and_then(|v| v.as_array()) {
        for t in teams {
            let id = t
                .get("id")
                .and_then(|v| v.as_str())
                .ok_or("team: missing id")?;
            let name = t
                .get("name")
                .and_then(|v| v.as_str())
                .ok_or("team: missing name")?;
            if !arrivau_api::auth::valid_identifier(id) {
                return Err(format!("team: invalid id {id}").into());
            }
            tx.execute(
                "INSERT OR IGNORE INTO teams(id, name) VALUES (?1, ?2)",
                params![id, name],
            )
            .map_err(|e| format!("insert team: {e}"))?;
            team_count += 1;
        }
    }
    // The fleet team must exist for configured_team() checks.
    tx.execute(
        "INSERT OR IGNORE INTO teams(id, name) VALUES (?1, ?1)",
        params![fleet_id],
    )
    .map_err(|e| format!("insert fleet team: {e}"))?;

    let mut account_count = 0usize;
    if let Some(accounts) = legacy.get("accounts").and_then(|v| v.as_array()) {
        for a in accounts {
            let id = a
                .get("id")
                .and_then(|v| v.as_str())
                .ok_or("account: missing id")?;
            let username = a
                .get("username")
                .and_then(|v| v.as_str())
                .ok_or("account: missing username")?;
            let name = a.get("name").and_then(|v| v.as_str()).unwrap_or(username);
            let password_hash = a
                .get("password_hash")
                .and_then(|v| v.as_str())
                .ok_or("account: missing password_hash")?;
            let team_id = a
                .get("team_id")
                .and_then(|v| v.as_str())
                .unwrap_or(fleet_id);
            let role = a.get("role").and_then(|v| v.as_str()).unwrap_or("");
            let roles: Vec<String> = a
                .get("roles")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            let primary = if role == "dispatcher" || role == "driver" {
                role.to_string()
            } else if roles.iter().any(|r| r == "dispatcher") {
                "dispatcher".to_string()
            } else {
                "driver".to_string()
            };
            tx.execute(
                "INSERT OR IGNORE INTO account_teams(account_id, team_id) VALUES (?1, ?2)",
                params![id, team_id],
            )
            .map_err(|e| format!("insert account_teams: {e}"))?;
            let roles_json = if roles.is_empty() {
                None
            } else {
                Some(serde_json::to_string(&roles).map_err(|e| format!("roles json: {e}"))?)
            };
            let inserted = tx.execute(
                "INSERT OR IGNORE INTO accounts(id, username, name, password_hash, team_id, role, deletable, roles) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)",
                params![id, username, name, password_hash, team_id, primary, roles_json],
            )
            .map_err(|e| format!("insert account: {e}"))?;
            account_count += inserted as usize;
        }
    }
    tx.commit().map_err(|e| format!("commit: {e}"))?;
    println!(
        "Imported {team_count} teams and {account_count} new accounts into {}",
        db_path.display()
    );
    Ok(())
}
