//! SQLite owns all durable state. Serialized domain records keep this starter's
//! schema compact; indexed identity/ownership/status columns and route foreign
//! keys are updated in the same transaction as their JSON representation.
use crate::{
    error::{ApiError, ApiResult},
    model::*,
};
use rusqlite::{params, Connection, OptionalExtension};
use std::{path::Path, time::Duration};

pub fn open(
    path: impl AsRef<Path>,
    mode: &str,
    legacy_team: &str,
    account_teams: &[(&str, &str)],
) -> ApiResult<Connection> {
    let mut db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute_batch("PRAGMA foreign_keys=ON;")?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > 6 {
        return Err(ApiError::bad_request(
            "Database schema is newer than this server",
        ));
    }
    if version >= 5
        && !db.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='idempotency_retired')",
            [],
            |r| r.get::<_, bool>(0),
        )?
    {
        return Err(ApiError::bad_request(
            "Deletion retry metadata is missing; restore a verified backup",
        ));
    }
    // All schema, legacy mappings and guards commit together; rejected upgrades leave data intact.
    let tx = db.transaction()?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS drivers (
           id TEXT PRIMARY KEY, body TEXT NOT NULL CHECK(json_valid(body))
         );
         CREATE TABLE IF NOT EXISTS deliveries (
           id TEXT PRIMARY KEY, driver_id TEXT REFERENCES drivers(id),
           status TEXT NOT NULL CHECK(status IN ('pending','assigned','picked_up','delivered')),
           body TEXT NOT NULL CHECK(json_valid(body))
         );
         CREATE INDEX IF NOT EXISTS deliveries_driver ON deliveries(driver_id, status);
         CREATE TABLE IF NOT EXISTS route_stops (
           driver_id TEXT NOT NULL REFERENCES drivers(id), position INTEGER NOT NULL,
           delivery_id TEXT NOT NULL REFERENCES deliveries(id),
           kind TEXT NOT NULL CHECK(kind IN ('pickup','dropoff')),
           PRIMARY KEY(driver_id, position), UNIQUE(delivery_id, kind)
         );
         CREATE TABLE IF NOT EXISTS deployment (key TEXT PRIMARY KEY,value TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS sessions (
           token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL,
           account_fingerprint TEXT NOT NULL, expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS sessions_account ON sessions(account_id,expires_at);
         CREATE TABLE IF NOT EXISTS login_limits (bucket TEXT PRIMARY KEY,attempts INTEGER NOT NULL,reset_at INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS idempotency_retired (scope_hash TEXT PRIMARY KEY);
         CREATE TABLE IF NOT EXISTS idempotency (
           principal_id TEXT NOT NULL, key TEXT NOT NULL, request_hash TEXT NOT NULL,
           response TEXT NOT NULL CHECK(json_valid(response)), PRIMARY KEY(principal_id,key)
         );"
    )?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS restaurants (
        id TEXT PRIMARY KEY, team_id TEXT NOT NULL,
        body TEXT NOT NULL CHECK(json_valid(body))
    ); CREATE INDEX IF NOT EXISTS restaurants_team ON restaurants(team_id,id);",
    )?;
    let marker: Option<String> = tx
        .query_row("SELECT value FROM deployment WHERE key='mode'", [], |r| {
            r.get(0)
        })
        .optional()?;
    match marker {
        Some(existing) if existing != mode => {
            return Err(ApiError::bad_request(
                "Database belongs to a different mode/fleet; use a separate database",
            ));
        }
        None => {
            let existing: i64 = tx.query_row("SELECT (SELECT COUNT(*) FROM drivers)+(SELECT COUNT(*) FROM deliveries)+(SELECT COUNT(*) FROM sessions)+(SELECT COUNT(*) FROM idempotency)", [], |r| r.get(0))?;
            if mode != "demo" && existing > 0 {
                return Err(ApiError::bad_request("An unmarked legacy database cannot be used for production; start with a separate database"));
            }
            tx.execute(
                "INSERT INTO deployment(key,value) VALUES ('mode',?1)",
                [mode],
            )?;
        }
        _ => {}
    }
    let mapping: Option<String> = tx
        .query_row(
            "SELECT value FROM deployment WHERE key='legacy_team_id'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if version >= 2 && mapping.is_none() {
        return Err(ApiError::bad_request(
            "Team schema is missing its legacy/default team mapping",
        ));
    }
    if mapping.as_deref().is_some_and(|id| id != legacy_team) {
        return Err(ApiError::bad_request(
            "The legacy/default team mapping cannot change",
        ));
    }
    for table in [
        "drivers",
        "deliveries",
        "route_stops",
        "sessions",
        "idempotency",
    ] {
        let columns: Vec<String> = {
            let mut stmt = tx.prepare(&format!("PRAGMA table_info({table})"))?;
            let rows = stmt.query_map([], |r| r.get(1))?;
            rows.collect::<Result<_, _>>()?
        };
        if !columns.iter().any(|c| c == "team_id") {
            if version >= 2 {
                return Err(ApiError::bad_request(
                    "Team schema is incomplete; restore a verified backup",
                ));
            }
            // The identifier has been validated; quote the SQL literal defensively as well.
            tx.execute_batch(&format!(
                "ALTER TABLE {table} ADD COLUMN team_id TEXT NOT NULL DEFAULT '{}';",
                legacy_team.replace('\'', "''")
            ))?;
        }
    }
    tx.execute(
        "INSERT OR IGNORE INTO deployment(key,value) VALUES ('legacy_team_id',?1)",
        [legacy_team],
    )?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS account_teams (account_id TEXT PRIMARY KEY, team_id TEXT NOT NULL);
         INSERT OR IGNORE INTO account_teams(account_id,team_id) SELECT id,team_id FROM drivers;
         INSERT OR IGNORE INTO account_teams(account_id,team_id) SELECT account_id,team_id FROM sessions;
         INSERT OR IGNORE INTO account_teams(account_id,team_id) SELECT principal_id,team_id FROM idempotency;
         CREATE INDEX IF NOT EXISTS drivers_team ON drivers(team_id,id);
         CREATE INDEX IF NOT EXISTS deliveries_team ON deliveries(team_id,driver_id,status);
         CREATE INDEX IF NOT EXISTS deliveries_team_status ON deliveries(team_id,status);
         CREATE INDEX IF NOT EXISTS routes_team ON route_stops(team_id,driver_id,position);
         CREATE INDEX IF NOT EXISTS idempotency_team ON idempotency(team_id,principal_id,key);
         CREATE INDEX IF NOT EXISTS sessions_team ON sessions(team_id,account_id);"
    )?;
    tx.execute_batch("CREATE TABLE IF NOT EXISTS invited_accounts (
        id TEXT PRIMARY KEY REFERENCES account_teams(account_id), username TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL, password_hash TEXT NOT NULL, team_id TEXT NOT NULL,
        disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1))
    ); CREATE INDEX IF NOT EXISTS invited_accounts_team ON invited_accounts(team_id,id);
    CREATE TABLE IF NOT EXISTS invites (
        id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
        issuer_id TEXT NOT NULL REFERENCES account_teams(account_id), issuer_fingerprint TEXT NOT NULL,
        team_id TEXT NOT NULL, expires_at INTEGER NOT NULL
    ); CREATE INDEX IF NOT EXISTS invites_team ON invites(team_id,expires_at);")?;
    let inconsistent_invites: i64 = tx.query_row("SELECT
        (SELECT COUNT(*) FROM invited_accounts i LEFT JOIN account_teams a ON a.account_id=i.id WHERE a.account_id IS NULL OR i.team_id<>a.team_id)
        +(SELECT COUNT(*) FROM invites i LEFT JOIN account_teams a ON a.account_id=i.issuer_id WHERE a.account_id IS NULL OR i.team_id<>a.team_id)", [], |r| r.get(0))?;
    if inconsistent_invites != 0 {
        return Err(ApiError::bad_request(
            "Persisted invitation team ownership is inconsistent",
        ));
    }
    // Fail closed on a previously inconsistent database, never re-label historical rows.
    let inconsistent: i64 = tx.query_row(
        "SELECT (SELECT COUNT(*) FROM drivers d JOIN account_teams a ON d.id=a.account_id WHERE d.team_id<>a.team_id)
          +(SELECT COUNT(*) FROM sessions s JOIN account_teams a ON s.account_id=a.account_id WHERE s.team_id<>a.team_id)
          +(SELECT COUNT(*) FROM idempotency i JOIN account_teams a ON i.principal_id=a.account_id WHERE i.team_id<>a.team_id)
          +(SELECT COUNT(*) FROM deliveries j JOIN drivers d ON j.driver_id=d.id WHERE j.team_id<>d.team_id)
          +(SELECT COUNT(*) FROM route_stops r JOIN drivers d ON r.driver_id=d.id JOIN deliveries j ON r.delivery_id=j.id WHERE r.team_id<>d.team_id OR r.team_id<>j.team_id)",
        [], |r| r.get(0)
    )?;
    if inconsistent != 0 {
        return Err(ApiError::bad_request(
            "Persisted team ownership is inconsistent; restore a verified backup",
        ));
    }
    for (id, team_id) in account_teams {
        let existing: Option<String> = tx
            .query_row(
                "SELECT team_id FROM account_teams WHERE account_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if existing.as_deref().is_some_and(|team| team != *team_id) {
            return Err(ApiError::bad_request(
                "An existing account ID cannot move teams; provision a new unique ID",
            ));
        }
    }
    // Defense in depth: even an unscoped future write cannot cross a persisted team boundary.
    for (table, guard) in [
        ("invited_accounts", "NOT EXISTS (SELECT 1 FROM account_teams WHERE account_id=NEW.id AND team_id=NEW.team_id)"),
        ("invites", "NOT EXISTS (SELECT 1 FROM account_teams WHERE account_id=NEW.issuer_id AND team_id=NEW.team_id)"),
        ("drivers", "NOT EXISTS (SELECT 1 FROM account_teams WHERE account_id=NEW.id AND team_id=NEW.team_id)"),
        ("deliveries", "NEW.driver_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM drivers WHERE id=NEW.driver_id AND team_id=NEW.team_id)"),
        ("route_stops", "NOT EXISTS (SELECT 1 FROM drivers WHERE id=NEW.driver_id AND team_id=NEW.team_id) OR NOT EXISTS (SELECT 1 FROM deliveries WHERE id=NEW.delivery_id AND team_id=NEW.team_id)"),
        ("sessions", "NOT EXISTS (SELECT 1 FROM account_teams WHERE account_id=NEW.account_id AND team_id=NEW.team_id)"),
        ("idempotency", "NOT EXISTS (SELECT 1 FROM account_teams WHERE account_id=NEW.principal_id AND team_id=NEW.team_id)"),
    ] {
        for operation in ["INSERT", "UPDATE"] {
            tx.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS {table}_team_{} BEFORE {operation} ON {table} WHEN {guard} BEGIN SELECT RAISE(ABORT,'Team ownership mismatch'); END;",operation.to_ascii_lowercase()))?;
        }
        tx.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS {table}_team_immutable BEFORE UPDATE OF team_id ON {table} WHEN NEW.team_id<>OLD.team_id BEGIN SELECT RAISE(ABORT,'Team ownership is immutable'); END;"))?;
    }
    tx.execute_batch("CREATE TRIGGER IF NOT EXISTS account_team_immutable BEFORE UPDATE ON account_teams WHEN NEW.team_id<>OLD.team_id OR NEW.account_id<>OLD.account_id BEGIN SELECT RAISE(ABORT,'Account team is immutable'); END;")?;
    if mode == "demo" {
        for (id, name, team) in [
            ("driver-1", "Driver 1", legacy_team),
            ("driver-2", "Driver 2", legacy_team),
            ("dual-1", "Revisione Apple", "demo-review"),
        ] {
            let driver = Driver {
                id: id.into(),
                name: name.into(),
                active: false,
                capacity: 2,
                location: None,
                location_updated_at: None,
            };
            tx.execute(
                "INSERT OR IGNORE INTO account_teams(account_id,team_id) VALUES (?1,?2)",
                params![id, team],
            )?;
            tx.execute(
                "INSERT OR IGNORE INTO drivers(id,team_id,body) VALUES (?1,?2,?3)",
                params![id, team, serde_json::to_string(&driver)?],
            )?;
        }
        tx.execute(
            "INSERT OR IGNORE INTO account_teams(account_id,team_id) VALUES ('dispatcher-1',?1)",
            [legacy_team],
        )?;
    }
    // Older servers assume every location is durable and non-null. Reject unsafe
    // downgrade rather than copying short-lived Google coordinates into history.
    tx.execute_batch("PRAGMA user_version=6;")?;
    tx.commit()?;
    db.execute_batch("PRAGMA journal_mode=WAL;")?;
    crate::places::initialize(&db)?;
    Ok(db)
}

pub fn restaurants(db: &Connection, team_id: &str) -> ApiResult<Vec<Restaurant>> {
    let mut stmt = db.prepare("SELECT body FROM restaurants WHERE team_id=?1 ORDER BY rowid")?;
    let rows = stmt.query_map([team_id], |row| row.get::<_, String>(0))?;
    rows.map(|row| crate::places::decode(db, team_id, &row?))
        .collect()
}

pub fn restaurant(db: &Connection, team_id: &str, id: &str) -> ApiResult<Restaurant> {
    let body: Option<String> = db
        .query_row(
            "SELECT body FROM restaurants WHERE id=?1 AND team_id=?2",
            params![id, team_id],
            |row| row.get(0),
        )
        .optional()?;
    crate::places::decode(
        db,
        team_id,
        &body.ok_or_else(|| ApiError::not_found("Restaurant not found"))?,
    )
}

pub fn save_restaurant(db: &Connection, team_id: &str, restaurant: &Restaurant) -> ApiResult<()> {
    db.execute(
        "INSERT INTO restaurants(id,team_id,body) VALUES (?1,?2,?3)",
        params![
            restaurant.id,
            team_id,
            crate::places::durable_json(restaurant)?
        ],
    )?;
    Ok(())
}

pub fn delivery_teams(db: &Connection) -> ApiResult<Vec<String>> {
    let mut stmt = db.prepare(
        "SELECT DISTINCT team_id FROM deliveries WHERE status='pending' ORDER BY team_id",
    )?;
    let rows = stmt.query_map([], |row| row.get(0))?;
    rows.collect::<Result<_, _>>().map_err(Into::into)
}

pub fn drivers(db: &Connection, team_id: &str) -> ApiResult<Vec<Driver>> {
    let mut stmt = db.prepare("SELECT body FROM drivers WHERE team_id=?1 ORDER BY id")?;
    let rows = stmt.query_map([team_id], |row| row.get::<_, String>(0))?;
    rows.map(|row| crate::places::decode(db, team_id, &row?))
        .collect()
}

pub fn driver(db: &Connection, team_id: &str, id: &str) -> ApiResult<Driver> {
    let body: Option<String> = db
        .query_row(
            "SELECT body FROM drivers WHERE id = ?1 AND team_id=?2",
            params![id, team_id],
            |r| r.get(0),
        )
        .optional()?;
    serde_json::from_str(&body.ok_or_else(|| ApiError::not_found("Driver not found"))?)
        .map_err(Into::into)
}

pub fn save_driver(db: &Connection, team_id: &str, driver: &Driver) -> ApiResult<()> {
    let count = db.execute(
        "UPDATE drivers SET body = ?2 WHERE id = ?1 AND team_id=?3",
        params![driver.id, serde_json::to_string(driver)?, team_id],
    )?;
    if count != 1 {
        return Err(ApiError::not_found("Driver not found"));
    }
    Ok(())
}

pub fn deliveries(db: &Connection, team_id: &str) -> ApiResult<Vec<Delivery>> {
    let mut stmt = db.prepare("SELECT body FROM deliveries WHERE team_id=?1 ORDER BY rowid")?;
    let rows = stmt.query_map([team_id], |row| row.get::<_, String>(0))?;
    rows.map(|row| crate::places::decode(db, team_id, &row?))
        .collect()
}

/// Planning never needs completed history. Keep every outstanding job, including
/// pending ones, while avoiding repeated JSON deserialization of archived work.
pub fn planning_deliveries(db: &Connection, team_id: &str) -> ApiResult<Vec<Delivery>> {
    let mut stmt = db.prepare("SELECT body FROM deliveries WHERE team_id=?1 AND status IN ('pending','assigned','picked_up') ORDER BY rowid")?;
    let rows = stmt.query_map([team_id], |row| row.get::<_, String>(0))?;
    rows.map(|row| crate::places::decode(db, team_id, &row?))
        .collect()
}

pub fn delivery(db: &Connection, team_id: &str, id: &str) -> ApiResult<Delivery> {
    let body: Option<String> = db
        .query_row(
            "SELECT body FROM deliveries WHERE id = ?1 AND team_id=?2",
            params![id, team_id],
            |r| r.get(0),
        )
        .optional()?;
    crate::places::decode(
        db,
        team_id,
        &body.ok_or_else(|| ApiError::not_found("Delivery not found"))?,
    )
}

pub fn save_delivery(db: &Connection, team_id: &str, delivery: &Delivery) -> ApiResult<()> {
    let status = match delivery.status {
        DeliveryStatus::Pending => "pending",
        DeliveryStatus::Assigned => "assigned",
        DeliveryStatus::PickedUp => "picked_up",
        DeliveryStatus::Delivered => "delivered",
    };
    let count = db.execute("INSERT INTO deliveries(id, driver_id, status, body, team_id) VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(id) DO UPDATE SET driver_id=excluded.driver_id, status=excluded.status, body=excluded.body WHERE deliveries.team_id=excluded.team_id",
        params![delivery.id, delivery.driver_id, status, crate::places::durable_json(delivery)?,team_id])?;
    if count != 1 {
        return Err(ApiError::not_found("Delivery not found"));
    }
    Ok(())
}

pub fn route_keys(db: &Connection, team_id: &str, driver_id: &str) -> ApiResult<Vec<StopKey>> {
    let mut stmt = db.prepare(
        "SELECT delivery_id, kind FROM route_stops WHERE driver_id = ?1 AND team_id=?2 ORDER BY position",
    )?;
    let rows = stmt.query_map(params![driver_id, team_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    rows.map(|row| {
        let (delivery_id, kind) = row?;
        let kind = match kind.as_str() {
            "pickup" => StopKind::Pickup,
            "dropoff" => StopKind::Dropoff,
            _ => return Err(ApiError::internal("Invalid persisted stop kind")),
        };
        Ok(StopKey { delivery_id, kind })
    })
    .collect()
}

pub fn save_route(
    db: &Connection,
    team_id: &str,
    driver_id: &str,
    keys: &[StopKey],
) -> ApiResult<()> {
    driver(db, team_id, driver_id)?;
    db.execute(
        "DELETE FROM route_stops WHERE driver_id = ?1 AND team_id=?2",
        params![driver_id, team_id],
    )?;
    let mut stmt = db.prepare(
        "INSERT INTO route_stops(driver_id, position, delivery_id, kind, team_id) VALUES (?1, ?2, ?3, ?4, ?5)",
    )?;
    for (position, key) in keys.iter().enumerate() {
        let kind = match key.kind {
            StopKind::Pickup => "pickup",
            StopKind::Dropoff => "dropoff",
        };
        stmt.execute(params![
            driver_id,
            position as i64,
            key.delivery_id,
            kind,
            team_id
        ])?;
    }
    Ok(())
}
