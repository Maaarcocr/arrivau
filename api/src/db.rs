//! SQLite owns all durable state. Serialized domain records keep this starter's
//! schema compact; indexed identity/ownership/status columns and route foreign
//! keys are updated in the same transaction as their JSON representation.
use crate::{
    error::{ApiError, ApiResult},
    model::*,
};
use rusqlite::{params, Connection, OptionalExtension};
use std::{path::Path, time::Duration};

pub fn open(path: impl AsRef<Path>) -> ApiResult<Connection> {
    let mut db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute_batch(
        "PRAGMA foreign_keys = ON;
         PRAGMA journal_mode = WAL;
         CREATE TABLE IF NOT EXISTS drivers (
           id TEXT PRIMARY KEY,
           body TEXT NOT NULL CHECK(json_valid(body))
         );
         CREATE TABLE IF NOT EXISTS deliveries (
           id TEXT PRIMARY KEY,
           driver_id TEXT REFERENCES drivers(id),
           status TEXT NOT NULL CHECK(status IN ('pending','assigned','picked_up','delivered')),
           body TEXT NOT NULL CHECK(json_valid(body))
         );
         CREATE INDEX IF NOT EXISTS deliveries_driver ON deliveries(driver_id, status);
         CREATE TABLE IF NOT EXISTS route_stops (
           driver_id TEXT NOT NULL REFERENCES drivers(id),
           position INTEGER NOT NULL,
           delivery_id TEXT NOT NULL REFERENCES deliveries(id),
           kind TEXT NOT NULL CHECK(kind IN ('pickup','dropoff')),
           PRIMARY KEY(driver_id, position),
           UNIQUE(delivery_id, kind)
         );
         PRAGMA user_version = 1;",
    )?;
    let tx = db.transaction()?;
    for i in 1..=2 {
        let driver = Driver {
            id: format!("driver-{i}"),
            name: format!("Driver {i}"),
            active: false,
            capacity: 2,
            location: None,
            location_updated_at: None,
        };
        tx.execute(
            "INSERT OR IGNORE INTO drivers(id, body) VALUES (?1, ?2)",
            params![driver.id, serde_json::to_string(&driver)?],
        )?;
    }
    tx.commit()?;
    Ok(db)
}

pub fn drivers(db: &Connection) -> ApiResult<Vec<Driver>> {
    let mut stmt = db.prepare("SELECT body FROM drivers ORDER BY id")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}

pub fn driver(db: &Connection, id: &str) -> ApiResult<Driver> {
    let body: Option<String> = db
        .query_row("SELECT body FROM drivers WHERE id = ?1", [id], |r| r.get(0))
        .optional()?;
    serde_json::from_str(&body.ok_or_else(|| ApiError::not_found("Driver not found"))?)
        .map_err(Into::into)
}

pub fn save_driver(db: &Connection, driver: &Driver) -> ApiResult<()> {
    let count = db.execute(
        "UPDATE drivers SET body = ?2 WHERE id = ?1",
        params![driver.id, serde_json::to_string(driver)?],
    )?;
    if count != 1 {
        return Err(ApiError::not_found("Driver not found"));
    }
    Ok(())
}

pub fn deliveries(db: &Connection) -> ApiResult<Vec<Delivery>> {
    let mut stmt = db.prepare("SELECT body FROM deliveries ORDER BY rowid")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}

pub fn delivery(db: &Connection, id: &str) -> ApiResult<Delivery> {
    let body: Option<String> = db
        .query_row("SELECT body FROM deliveries WHERE id = ?1", [id], |r| {
            r.get(0)
        })
        .optional()?;
    serde_json::from_str(&body.ok_or_else(|| ApiError::not_found("Delivery not found"))?)
        .map_err(Into::into)
}

pub fn save_delivery(db: &Connection, delivery: &Delivery) -> ApiResult<()> {
    let status = match delivery.status {
        DeliveryStatus::Pending => "pending",
        DeliveryStatus::Assigned => "assigned",
        DeliveryStatus::PickedUp => "picked_up",
        DeliveryStatus::Delivered => "delivered",
    };
    db.execute("INSERT INTO deliveries(id, driver_id, status, body) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(id) DO UPDATE SET driver_id=excluded.driver_id, status=excluded.status, body=excluded.body",
        params![delivery.id, delivery.driver_id, status, serde_json::to_string(delivery)?])?;
    Ok(())
}

pub fn route_keys(db: &Connection, driver_id: &str) -> ApiResult<Vec<StopKey>> {
    let mut stmt = db.prepare(
        "SELECT delivery_id, kind FROM route_stops WHERE driver_id = ?1 ORDER BY position",
    )?;
    let rows = stmt.query_map([driver_id], |row| {
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

pub fn save_route(db: &Connection, driver_id: &str, keys: &[StopKey]) -> ApiResult<()> {
    db.execute("DELETE FROM route_stops WHERE driver_id = ?1", [driver_id])?;
    let mut stmt = db.prepare(
        "INSERT INTO route_stops(driver_id, position, delivery_id, kind) VALUES (?1, ?2, ?3, ?4)",
    )?;
    for (position, key) in keys.iter().enumerate() {
        let kind = match key.kind {
            StopKind::Pickup => "pickup",
            StopKind::Dropoff => "dropoff",
        };
        stmt.execute(params![driver_id, position as i64, key.delivery_id, kind])?;
    }
    Ok(())
}
