//! Google locations are short-lived working data, never part of durable history.
//! Only Place IDs and independently user-authored text belong in durable JSON.
use crate::{
    error::{ApiError, ApiResult},
    model::Coordinate,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{future::Future, pin::Pin, sync::Arc, time::Duration};

// A one-day safety margin allows prompt timer cleanup before the 30-day limit.
pub const MAX_CACHE_SECONDS: i64 = 29 * 24 * 60 * 60;
const MAX_CACHE_ENTRIES: i64 = 4096;
const FAILURE_BACKOFF_SECONDS: i64 = 30;
const UNAVAILABLE: &str = "Google Places location unavailable; retry or select the address again";

pub fn valid_place_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 512
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
}

pub type ResolveFuture<'a> =
    Pin<Box<dyn Future<Output = Result<Coordinate, String>> + Send + 'a>>;

/// Injectable transport boundary. Tests never call a paid Google endpoint.
pub trait PlaceResolver: Send + Sync {
    fn resolve<'a>(&'a self, place_id: &'a str) -> ResolveFuture<'a>;
}

#[derive(Clone, Default)]
pub struct PlacesService {
    resolver: Option<Arc<dyn PlaceResolver>>,
}

impl PlacesService {
    pub fn from_env() -> Result<Self, String> {
        match std::env::var("ARRIVAU_GOOGLE_PLACES_SERVER_KEY") {
            Err(std::env::VarError::NotPresent) => Ok(Self::default()),
            Ok(key) if !key.trim().is_empty() => Self::new(key),
            _ => Err("ARRIVAU_GOOGLE_PLACES_SERVER_KEY must be a nonempty key".into()),
        }
    }

    pub fn with_resolver(resolver: Arc<dyn PlaceResolver>) -> Self {
        Self { resolver: Some(resolver) }
    }

    fn new(key: String) -> Result<Self, String> {
        Ok(Self::with_resolver(Arc::new(HttpResolver::new(key)?)))
    }

    pub(crate) async fn resolve(&self, id: &str) -> ApiResult<Coordinate> {
        if !valid_place_id(id) {
            return Err(ApiError::bad_request("Invalid Google Place ID"));
        }
        let resolver = self.resolver.as_ref().ok_or_else(unavailable)?;
        let coordinate = resolver.resolve(id).await.map_err(|_| unavailable())?;
        if !coordinate.valid() {
            return Err(unavailable());
        }
        Ok(coordinate)
    }
}

impl HttpResolver {
    fn new(key: String) -> Result<Self, String> {
        // A separate server key, never the iOS bundle key. Disable redirects so
        // authentication headers cannot be forwarded to another destination.
        let mut headers = reqwest::header::HeaderMap::new();
        let mut key = reqwest::header::HeaderValue::from_str(&key)
            .map_err(|_| "Invalid Google Places server key".to_string())?;
        key.set_sensitive(true);
        headers.insert("X-Goog-Api-Key", key);
        headers.insert("X-Goog-FieldMask", "id,location".parse().expect("static header"));
        let client = reqwest::Client::builder()
            .default_headers(headers)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|_| "Could not initialize Google Places client".to_string())?;
        Ok(Self {
            client,
            base: "https://places.googleapis.com/v1/places/".into(),
            workers: tokio::sync::Semaphore::new(4),
        })
    }
}

pub(crate) fn unavailable() -> ApiError {
    ApiError::new(axum::http::StatusCode::SERVICE_UNAVAILABLE, UNAVAILABLE)
}

struct HttpResolver {
    client: reqwest::Client,
    base: String,
    workers: tokio::sync::Semaphore,
}
impl PlaceResolver for HttpResolver {
    fn resolve<'a>(&'a self, id: &'a str) -> ResolveFuture<'a> {
        Box::pin(async move {
            // No unbounded provider queue; callers retain their existing work.
            let _permit = self.workers.try_acquire().map_err(|_| UNAVAILABLE)?;
            let mut response = self.client.get(format!("{}{id}", self.base))
                .send().await.map_err(|_| UNAVAILABLE)?;
            if !response.status().is_success() {
                return Err(UNAVAILABLE.into());
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| UNAVAILABLE)? {
                if bytes.len() + chunk.len() > 8 * 1024 {
                    return Err(UNAVAILABLE.into());
                }
                bytes.extend_from_slice(&chunk);
            }
            #[derive(Deserialize)]
            struct Location { latitude: f64, longitude: f64 }
            #[derive(Deserialize)]
            struct Details { id: String, location: Location }
            let details: Details = serde_json::from_slice(&bytes).map_err(|_| UNAVAILABLE)?;
            if details.id != id { return Err(UNAVAILABLE.into()); }
            let coordinate = Coordinate { lat: details.location.latitude, lng: details.location.longitude };
            if !coordinate.valid() { return Err(UNAVAILABLE.into()); }
            Ok(coordinate)
        })
    }
}

/// TEMP plus memory storage keeps Google coordinates out of database backups,
/// WAL, idempotency responses and completed delivery history. Restart means a
/// fresh lookup. Nothing copied out of this cache becomes durable again.
pub(crate) fn initialize(db: &Connection) -> ApiResult<()> {
    db.execute_batch("PRAGMA temp_store=MEMORY;
        CREATE TEMP TABLE google_place_cache (
            team_id TEXT NOT NULL, place_id TEXT NOT NULL,
            provider TEXT NOT NULL CHECK(provider='google'),
            lat REAL NOT NULL, lng REAL NOT NULL, fetched_at INTEGER NOT NULL,
            PRIMARY KEY(team_id,place_id)
        );
        CREATE TEMP TABLE google_place_failures (
            team_id TEXT NOT NULL, place_id TEXT NOT NULL, retry_after INTEGER NOT NULL,
            PRIMARY KEY(team_id,place_id)
        );")?;
    Ok(())
}

pub(crate) fn purge(db: &Connection, now: i64) -> ApiResult<()> {
    db.execute("DELETE FROM google_place_cache WHERE fetched_at<=?1 OR fetched_at>?2",
        params![now.saturating_sub(MAX_CACHE_SECONDS), now])?;
    db.execute("DELETE FROM google_place_failures WHERE retry_after<=?1 OR retry_after>?2",
        params![now, now.saturating_add(FAILURE_BACKOFF_SECONDS)])?;
    Ok(())
}

pub(crate) fn cached(db: &Connection, team: &str, id: &str) -> ApiResult<Option<(Coordinate, i64)>> {
    db.query_row("SELECT lat,lng,fetched_at FROM google_place_cache WHERE team_id=?1 AND place_id=?2",
        params![team,id], |row| Ok((Coordinate {lat:row.get(0)?,lng:row.get(1)?},row.get(2)?)))
        .optional().map_err(Into::into)
}

pub(crate) fn save(db: &Connection, team: &str, id: &str, coordinate: Coordinate, now: i64) -> ApiResult<()> {
    db.execute("INSERT INTO google_place_cache(team_id,place_id,provider,lat,lng,fetched_at) VALUES (?1,?2,'google',?3,?4,?5)
        ON CONFLICT(team_id,place_id) DO UPDATE SET lat=excluded.lat,lng=excluded.lng,fetched_at=excluded.fetched_at",
        params![team,id,coordinate.lat,coordinate.lng,now])?;
    db.execute("DELETE FROM google_place_failures WHERE team_id=?1 AND place_id=?2", params![team,id])?;
    db.execute("DELETE FROM google_place_cache WHERE rowid IN (SELECT rowid FROM google_place_cache ORDER BY fetched_at DESC,rowid DESC LIMIT -1 OFFSET ?1)", [MAX_CACHE_ENTRIES])?;
    Ok(())
}

pub(crate) fn retry_blocked(db: &Connection, team: &str, id: &str) -> ApiResult<bool> {
    db.query_row("SELECT EXISTS(SELECT 1 FROM google_place_failures WHERE team_id=?1 AND place_id=?2)",
        params![team,id], |r| r.get(0)).map_err(Into::into)
}

pub(crate) fn failed(db: &Connection, team: &str, id: &str, now: i64) -> ApiResult<()> {
    db.execute("INSERT INTO google_place_failures(team_id,place_id,retry_after) VALUES (?1,?2,?3)
        ON CONFLICT(team_id,place_id) DO UPDATE SET retry_after=excluded.retry_after",
        params![team,id,now.saturating_add(FAILURE_BACKOFF_SECONDS)])?;
    db.execute("DELETE FROM google_place_failures WHERE rowid IN (SELECT rowid FROM google_place_failures ORDER BY retry_after DESC,rowid DESC LIMIT -1 OFFSET ?1)", [MAX_CACHE_ENTRIES])?;
    Ok(())
}

const DESTINATIONS: [(&str, &str, &str); 3] = [
    ("google_place_id", "coordinate", "coordinate_fetched_at"),
    ("pickup_google_place_id", "pickup", "pickup_coordinate_fetched_at"),
    ("dropoff_google_place_id", "dropoff", "dropoff_coordinate_fetched_at"),
];

/// Scrub every nested response too, so future envelopes cannot accidentally
/// persist cached Google content in an idempotency snapshot.
fn strip(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (id, coordinate, at) in DESTINATIONS {
                if map.get(id).is_some_and(Value::is_string) {
                    map.insert(coordinate.into(), Value::Null);
                    map.insert(at.into(), Value::Null);
                }
            }
            map.values_mut().for_each(strip);
        }
        Value::Array(values) => values.iter_mut().for_each(strip),
        _ => {}
    }
}

pub(crate) fn durable_json(value: &impl Serialize) -> ApiResult<String> {
    let mut value = serde_json::to_value(value)?;
    strip(&mut value);
    Ok(serde_json::to_string(&value)?)
}

fn hydrate(db: &Connection, team: &str, value: &mut Value) -> ApiResult<()> {
    match value {
        Value::Object(map) => {
            for (id, coordinate, at) in DESTINATIONS {
                if let Some(id) = map.get(id).and_then(Value::as_str) {
                    let cached = cached(db, team, id)?;
                    map.insert(coordinate.into(), serde_json::to_value(cached.map(|c| c.0))?);
                    map.insert(at.into(), serde_json::to_value(cached.map(|c| c.1))?);
                }
            }
            for value in map.values_mut() { hydrate(db, team, value)?; }
        }
        Value::Array(values) => for value in values { hydrate(db, team, value)?; },
        _ => {}
    }
    Ok(())
}

pub(crate) fn decode<T: serde::de::DeserializeOwned>(db: &Connection, team: &str, body: &str) -> ApiResult<T> {
    let mut value = serde_json::from_str(body)?;
    hydrate(db, team, &mut value)?;
    Ok(serde_json::from_value(value)?)
}

pub(crate) fn demo_coordinate(id: &str) -> Option<Coordinate> {
    match id {
        "arrivau-test-pachino-pickup" => Some(Coordinate {lat:36.7163,lng:15.0908}),
        "arrivau-test-pachino-dropoff" => Some(Coordinate {lat:36.7210,lng:15.1000}),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Path, http::{HeaderMap, StatusCode}, response::{IntoResponse, Response}, routing::get, Json, Router};
    use serde_json::json;

    #[test]
    fn cache_is_memory_only_and_expires_at_the_boundary() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let db = Connection::open(file.path()).unwrap();
        initialize(&db).unwrap();
        let coordinate = Coordinate { lat: 36.7163, lng: 15.0908 };
        save(&db, "a", "ChIJfixture", coordinate, 1000).unwrap();
        assert!(cached(&db, "b", "ChIJfixture").unwrap().is_none());
        let other = Connection::open(file.path()).unwrap();
        assert!(other.prepare("SELECT * FROM google_place_cache").is_err());
        purge(&db, 1000 + MAX_CACHE_SECONDS - 1).unwrap();
        assert!(cached(&db, "a", "ChIJfixture").unwrap().is_some());
        purge(&db, 1000 + MAX_CACHE_SECONDS).unwrap();
        assert!(cached(&db, "a", "ChIJfixture").unwrap().is_none());
        save(&db, "a", "ChIJfixture", coordinate, 2000).unwrap();
        purge(&db, 1000).unwrap();
        assert!(cached(&db, "a", "ChIJfixture").unwrap().is_none());
    }

    #[test]
    fn historical_snapshots_never_contain_google_coordinates() {
        let record = json!({"result": {
            "pickup_google_place_id":"ChIJfixture", "pickup":{"lat":36.7,"lng":15.1},
            "pickup_coordinate_fetched_at":1234,
            "dropoff":{"lat":10.0,"lng":20.0},"pickup_address":"User-entered address"
        }});
        let clean: Value = serde_json::from_str(&durable_json(&record).unwrap()).unwrap();
        assert!(clean["result"]["pickup"].is_null());
        assert!(clean["result"]["pickup_coordinate_fetched_at"].is_null());
        assert_eq!(clean["result"]["dropoff"], record["result"]["dropoff"]);
        assert_eq!(clean["result"]["pickup_google_place_id"], "ChIJfixture");
        assert_eq!(clean["result"]["pickup_address"], "User-entered address");
    }

    #[test]
    fn identifiers_cannot_inject_urls_or_headers() {
        for id in ["", "../other", "places/ChIJ", "ChIJ?key=secret", "a\r\nb", "a b", "https://example.com"] {
            assert!(!valid_place_id(id));
        }
        assert!(valid_place_id("ChIJ_abc-123"));
        assert!(!valid_place_id(&"a".repeat(513)));
    }

    async fn details(Path(id): Path<String>, headers: HeaderMap) -> Response {
        assert_eq!(headers["X-Goog-Api-Key"], "test-only-server-key");
        assert_eq!(headers["X-Goog-FieldMask"], "id,location");
        match id.as_str() {
            "redirect" => (StatusCode::FOUND, [("Location", "/must-not-follow")]).into_response(),
            "denied" => (StatusCode::FORBIDDEN, "private upstream details").into_response(),
            "missing" => Json(json!({"id":id})).into_response(),
            "wrong" => Json(json!({"id":"different", "location":{"latitude":36.7,"longitude":15.1}})).into_response(),
            "invalid" => Json(json!({"id":id, "location":{"latitude":91,"longitude":15.1}})).into_response(),
            "oversized" => "a".repeat(9000).into_response(),
            _ => Json(json!({"id":id, "location":{"latitude":36.7,"longitude":15.1}, "displayName":{"text":"must never persist"}})).into_response(),
        }
    }

    #[tokio::test]
    async fn http_details_uses_essentials_and_fails_closed_without_exposing_upstream_data() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/v1/places/", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, Router::new().route("/v1/places/{id}", get(details))
                .route("/must-not-follow", get(|| async { Json(json!({"id":"redirect", "location":{"latitude":36.7,"longitude":15.1}})) }))).await.unwrap();
        });
        let mut resolver = HttpResolver::new("test-only-server-key".into()).unwrap();
        resolver.base = base;
        let service = PlacesService::with_resolver(Arc::new(resolver));
        assert_eq!(service.resolve("ChIJfixture").await.unwrap(), Coordinate {lat:36.7,lng:15.1});
        for id in ["redirect", "denied", "missing", "wrong", "invalid", "oversized"] {
            let error = service.resolve(id).await.unwrap_err();
            assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(error.message, UNAVAILABLE);
        }
        task.abort();
    }
}
