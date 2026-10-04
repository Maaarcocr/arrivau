use super::*;
use osrm_interface::{
    errors::{NativeOsrmError, OsrmError},
    native::OsrmEngine,
    nearest::NearestRequestBuilder,
    table::{TableAnnotation, TableRequestBuilder},
    Algorithm, Point,
};
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    fs::File,
    io::Read,
    path::{Component, Path},
    sync::{
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::sync::oneshot;

const QUEUE_CAPACITY: usize = 8;
const CACHE_CAPACITY: usize = 16;
const SNAP_CACHE_CAPACITY: usize = 256;
const QUERY_DEADLINE: Duration = Duration::from_millis(2_000);
const SNAP_METERS: f64 = 250.0;
type Durations = Vec<Vec<Option<i64>>>;
type SharedMatrices = Arc<Mutex<VecDeque<(Vec<PointKey>, Durations)>>>;
// OSRM v6.0.0 storage/storage_config.hpp common set plus the CH graph.
const REQUIRED_SUFFIXES: &[&str] = &[
    "datasource_names",
    "ebg_nodes",
    "edges",
    "fileIndex",
    "geometry",
    "icd",
    "maneuver_overrides",
    "names",
    "nbg_nodes",
    "properties",
    "ramIndex",
    "timestamp",
    "tld",
    "tls",
    "turn_duration_penalties",
    "turn_weight_penalties",
    "hsgr",
];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format_version: u32,
    osrm_version: String,
    binding_version: String,
    algorithm: String,
    profile: String,
    osm_timestamp: String,
    data_file: String,
    service_bounds: [f64; 4],
    extract_bounds: [f64; 4],
    files: HashMap<String, String>,
}
impl Manifest {
    fn read(path: &Path) -> Result<Self, String> {
        if !path.is_absolute() {
            return Err("OSRM manifest path must be absolute".into());
        }
        if !std::fs::metadata(path)
            .map_err(|_| "Cannot inspect OSRM manifest")?
            .is_file()
        {
            return Err("OSRM manifest must be a regular file".into());
        }
        let file = File::open(path).map_err(|_| "Cannot read OSRM manifest")?;
        if !file
            .metadata()
            .map_err(|_| "Cannot inspect OSRM manifest")?
            .is_file()
        {
            return Err("OSRM manifest must be a regular file".into());
        }
        let mut bytes = Vec::new();
        file.take(64 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "Cannot read OSRM manifest")?;
        if bytes.len() > 64 * 1024 {
            return Err("OSRM manifest exceeds 64 KiB".into());
        }
        let manifest: Self =
            serde_json::from_slice(&bytes).map_err(|_| "Invalid OSRM dataset manifest")?;
        manifest.validate()?;
        let directory = path.parent().ok_or("OSRM manifest has no parent")?;
        // Refuse an incomplete manifest even when an unlisted file is only an
        // offline preparation sidecar. Future preparation must publish the whole set.
        for entry in std::fs::read_dir(directory).map_err(|_| "Cannot list OSRM dataset")? {
            let entry = entry.map_err(|_| "Cannot list OSRM dataset")?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            if name.starts_with(&format!("{}.", manifest.data_file))
                && !manifest.files.contains_key(name)
            {
                return Err("OSRM dataset file is not covered by the manifest".into());
            }
        }
        for (name, expected) in &manifest.files {
            let mut file =
                File::open(directory.join(name)).map_err(|_| "OSRM dataset file is missing")?;
            let mut digest = Sha256::new();
            let mut buffer = [0u8; 65536];
            loop {
                let count = file
                    .read(&mut buffer)
                    .map_err(|_| "Cannot read OSRM dataset file")?;
                if count == 0 {
                    break;
                }
                digest.update(&buffer[..count]);
            }
            if format!("{:x}", digest.finalize()) != *expected {
                return Err(
                    "OSRM dataset checksum mismatch; prepare a matching immutable dataset".into(),
                );
            }
        }
        Ok(manifest)
    }
    fn validate(&self) -> Result<(), String> {
        fn basename(name: &str) -> bool {
            !name.is_empty()
                && Path::new(name).components().count() == 1
                && matches!(
                    Path::new(name).components().next(),
                    Some(Component::Normal(_))
                )
        }
        fn bounds(b: [f64; 4]) -> bool {
            b.iter().all(|value| value.is_finite())
                && (-180.0..=180.0).contains(&b[0])
                && (-180.0..=180.0).contains(&b[2])
                && (-90.0..=90.0).contains(&b[1])
                && (-90.0..=90.0).contains(&b[3])
                && b[0] < b[2]
                && b[1] < b[3]
        }
        let inner = self.service_bounds;
        let outer = self.extract_bounds;
        if self.format_version != 1
            || self.osrm_version != "6.0.0"
            || self.binding_version != "0.8.2"
            || self.algorithm != "CH"
            || self.profile != "car.lua"
            || self.osm_timestamp.len() < 10
            || self.osm_timestamp.len() > 40
            || !basename(&self.data_file)
            || !self.data_file.ends_with(".osrm")
            || !bounds(inner)
            || !bounds(outer)
            || inner[0] <= outer[0]
            || inner[1] <= outer[1]
            || inner[2] >= outer[2]
            || inner[3] >= outer[3]
            || self.files.is_empty()
            || self.files.len() > 64
            || self.files.iter().any(|(name, hash)| {
                !basename(name)
                    || !name.starts_with(&format!("{}.", self.data_file))
                    || hash.len() != 64
                    || !hash
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            })
            || !REQUIRED_SUFFIXES.iter().all(|extension| {
                self.files
                    .contains_key(&format!("{}.{}", self.data_file, extension))
            })
        {
            return Err("Unsupported or incomplete OSRM dataset manifest (requires OSRM 6.0.0 / binding 0.8.2 / CH / car.lua / buffered coverage)".into());
        }
        Ok(())
    }
    fn contains(&self, point: Coordinate) -> bool {
        let [west, south, east, north] = self.service_bounds;
        point.valid() && (west..=east).contains(&point.lng) && (south..=north).contains(&point.lat)
    }
    fn estimate(&self) -> TravelEstimate {
        TravelEstimate {
            mode: TravelMode::EmbeddedOsrm,
            approximate: false,
            notice: Some(
                "Tempi stradali stimati con OpenStreetMap; traffico in tempo reale non incluso."
                    .into(),
            ),
            map_date: Some(self.osm_timestamp.clone()),
            attribution: Some(
                "© OpenStreetMap contributors · ODbL · https://www.openstreetmap.org/copyright"
                    .into(),
            ),
        }
    }
}

#[derive(Default)]
struct EngineCache {
    // The exact driver point is part of the full matrix key. The native binding
    // discards hints; splitting a stop table and a driver row can choose
    // inconsistent component snaps, so never combine separate native tables.
    matrices: SharedMatrices,
    snapped: VecDeque<PointKey>,
}

struct Query {
    driver: Option<Coordinate>,
    stops: Vec<Coordinate>,
    reply: oneshot::Sender<Result<TravelMatrix, &'static str>>,
}
#[derive(Clone)]
pub(super) struct Worker {
    sender: SyncSender<Query>,
    estimate: TravelEstimate,
    matrices: SharedMatrices,
}
impl Worker {
    pub fn start(path: &Path) -> Result<Self, String> {
        let manifest = Manifest::read(path)?;
        let graph = path.parent().unwrap().join(&manifest.data_file);
        let graph = graph
            .to_str()
            .ok_or("OSRM dataset path must be UTF-8")?
            .to_owned();
        let estimate = manifest.estimate();
        let matrices = SharedMatrices::default();
        let worker_matrices = Arc::clone(&matrices);
        let (sender, receiver) = mpsc::sync_channel::<Query>(QUEUE_CAPACITY);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("arrivau-osrm".into())
            .spawn(move || {
                // Never clone the binding engine: it owns a native pointer. This is
                // the only engine and it is dropped only on this owning thread.
                let engine = match OsrmEngine::new(&graph, Algorithm::CH) {
                    Ok(engine) => engine,
                    Err(_) => {
                        let _ = ready_tx.send(Err(
                            "Cannot initialize OSRM 6.0.0 with this CH dataset".to_owned(),
                        ));
                        return;
                    }
                };
                let _ = ready_tx.send(Ok(()));
                let mut cache = EngineCache {
                    matrices: worker_matrices,
                    snapped: VecDeque::new(),
                };
                for query in receiver {
                    if query.reply.is_closed() {
                        continue;
                    }
                    let result = matrix(&engine, &manifest, &mut cache, query.driver, query.stops);
                    let _ = query.reply.send(result);
                }
            })
            .map_err(|_| "Cannot start OSRM worker")?;
        ready_rx
            .recv()
            .map_err(|_| "OSRM worker failed during initialization")??;
        Ok(Self {
            sender,
            estimate,
            matrices,
        })
    }
    pub fn fallback(&self, points: &[Coordinate]) -> Result<TravelMatrix, String> {
        let key: Vec<PointKey> = points.iter().map(|point| (*point).into()).collect();
        if let Some(durations) = cached_matrix(&self.matrices, &key).map_err(str::to_owned)? {
            // This is the exact ordered full query, including GPS, for this
            // immutable dataset. Preserve its native nulls even under overload.
            return TravelMatrix::new(points, durations, self.estimate.clone());
        }
        let mut matrix = TravelMatrix::approximate(points, true)?;
        matrix.estimate.map_date = self.estimate.map_date.clone();
        matrix.estimate.attribution = self.estimate.attribution.clone();
        Ok(matrix)
    }
    pub async fn matrix(
        &self,
        driver: Option<Coordinate>,
        stops: Vec<Coordinate>,
    ) -> Result<TravelMatrix, &'static str> {
        let (reply, receiver) = oneshot::channel();
        self.sender
            .try_send(Query {
                driver,
                stops,
                reply,
            })
            .map_err(|_| "busy_or_unavailable")?;
        tokio::time::timeout(QUERY_DEADLINE, receiver)
            .await
            .map_err(|_| "deadline")?
            .map_err(|_| "worker_unavailable")?
    }
}

// The mutex protects a small bounded Rust cache only. It is always released
// before nearest/table FFI calls, so cache recovery never waits on native work.
fn cached_matrix(
    cache: &SharedMatrices,
    key: &[PointKey],
) -> Result<Option<Durations>, &'static str> {
    let mut cache = cache.lock().map_err(|_| "routing_cache_unavailable")?;
    let Some(index) = cache.iter().position(|(old, _)| old == key) else {
        return Ok(None);
    };
    let cached = cache.remove(index).unwrap();
    let durations = cached.1.clone();
    cache.push_front(cached);
    Ok(Some(durations))
}

fn matrix(
    engine: &OsrmEngine,
    manifest: &Manifest,
    cache: &mut EngineCache,
    driver: Option<Coordinate>,
    stops: Vec<Coordinate>,
) -> Result<TravelMatrix, &'static str> {
    let mut points = stops;
    if let Some(driver) = driver {
        push_unique(&mut points, driver);
    }
    let key: Vec<PointKey> = points.iter().map(|point| (*point).into()).collect();
    if let Some(durations) = cached_matrix(&cache.matrices, &key)? {
        return TravelMatrix::new(&points, durations, manifest.estimate())
            .map_err(|_| "invalid_native_matrix");
    }
    let mut durations: Durations = points
        .iter()
        .map(|from| {
            points
                .iter()
                .map(|to| Some(approximate_seconds(*from, *to)))
                .collect()
        })
        .collect();
    // An unsupported GPS or stop is omitted from this native table, never
    // allowed to turn native nulls between supported points into approximations.
    let native_indexes: Vec<_> = points
        .iter()
        .enumerate()
        .filter_map(|(i, point)| {
            let key = PointKey::from(*point);
            let snapped = if cache.snapped.contains(&key) {
                true
            } else if manifest.contains(*point) && can_snap(engine, *point) {
                cache.snapped.push_front(key);
                cache.snapped.truncate(SNAP_CACHE_CAPACITY);
                true
            } else {
                false
            };
            snapped.then_some(i)
        })
        .collect();
    let supported: Vec<_> = native_indexes.iter().map(|i| points[*i]).collect();
    let mut approximate = native_indexes.len() != points.len();
    if !supported.is_empty() {
        if let Ok(native) = table(engine, &supported, &supported) {
            for (i, &from) in native_indexes.iter().enumerate() {
                for (j, &to) in native_indexes.iter().enumerate() {
                    durations[from][to] = native[i][j];
                }
            }
            if !approximate {
                let mut matrices = cache
                    .matrices
                    .lock()
                    .map_err(|_| "routing_cache_unavailable")?;
                matrices.push_front((key, durations.clone()));
                matrices.truncate(CACHE_CAPACITY);
            }
        } else {
            approximate = true;
        }
    }
    let mut estimate = manifest.estimate();
    if approximate {
        estimate.mode = TravelMode::ApproximateFallback;
        estimate.approximate = true;
        estimate.notice = Some(FALLBACK_NOTICE.into());
    }
    TravelMatrix::new(&points, durations, estimate).map_err(|_| "invalid_native_matrix")
}

fn can_snap(engine: &OsrmEngine, coordinate: Coordinate) -> bool {
    let Some(point) = Point::new(coordinate.lat, coordinate.lng) else {
        return false;
    };
    let Ok(request) = NearestRequestBuilder::new(&point, 1)
        .radius(SNAP_METERS)
        .build()
    else {
        return false;
    };
    engine.nearest(&request).is_ok_and(|response| {
        response.code == "Ok"
            && response.waypoints.first().is_some_and(|point| {
                point.distance.is_finite() && (0.0..=SNAP_METERS).contains(&point.distance)
            })
    })
}

fn table(
    engine: &OsrmEngine,
    sources: &[Coordinate],
    destinations: &[Coordinate],
) -> Result<Durations, &'static str> {
    let sources: Vec<Point> = sources
        .iter()
        .map(|p| Point::new(p.lat, p.lng).ok_or("invalid_coordinate"))
        .collect::<Result<_, _>>()?;
    let destinations: Vec<Point> = destinations
        .iter()
        .map(|p| Point::new(p.lat, p.lng).ok_or("invalid_coordinate"))
        .collect::<Result<_, _>>()?;
    let source_radiuses = vec![Some(SNAP_METERS); sources.len()];
    let destination_radiuses = vec![Some(SNAP_METERS); destinations.len()];
    let request = TableRequestBuilder::new(&sources, &destinations)
        .annotations(TableAnnotation::Duration)
        .source_radiuses(&source_radiuses)
        .destination_radiuses(&destination_radiuses)
        .generate_hints(false)
        // Deliberately no fallback speed: native null means unreachable.
        .build()
        .map_err(|_| "invalid_table_request")?;
    let response = match engine.table(&request) {
        Ok(response) => response,
        // Binding 0.8.2 discards the JSON code and retains this exact pinned
        // OSRM 6 message. Normal CH disconnections arrive as Ok/null instead.
        Err(OsrmError::Native(NativeOsrmError::FfiError(details)))
            if details == "OSRM error: No table found" =>
        {
            return Ok(vec![vec![None; destinations.len()]; sources.len()]);
        }
        Err(_) => return Err("native_query_failed"),
    };
    if response.code == "NoTable" {
        return Ok(vec![vec![None; destinations.len()]; sources.len()]);
    }
    if response.code != "Ok" {
        return Err("native_query_failed");
    }
    for (waypoints, count) in [
        (&response.sources, sources.len()),
        (&response.destinations, destinations.len()),
    ] {
        let waypoints = waypoints.as_ref().ok_or("missing_snaps")?;
        if waypoints.len() != count
            || waypoints
                .iter()
                .any(|p| !p.distance.is_finite() || !(0.0..=SNAP_METERS).contains(&p.distance))
        {
            return Err("outside_snap_radius");
        }
    }
    let durations = response.durations.ok_or("missing_durations")?;
    if durations.len() != sources.len()
        || durations.iter().any(|row| row.len() != destinations.len())
    {
        return Err("invalid_dimensions");
    }
    durations
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|seconds| match seconds {
                    None => Ok(None),
                    Some(seconds)
                        if seconds.is_finite() && (0.0..=31_536_000.0).contains(&seconds) =>
                    {
                        Ok(Some(seconds.ceil() as i64))
                    }
                    Some(_) => Err("invalid_duration"),
                })
                .collect()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn full_or_closed_worker_queue_fails_without_waiting() {
        let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
        let worker = Worker {
            sender,
            matrices: SharedMatrices::default(),
            estimate: TravelEstimate::default(),
        };
        let mut replies = Vec::new();
        for _ in 0..QUEUE_CAPACITY {
            let (reply, response) = oneshot::channel();
            worker
                .sender
                .try_send(Query {
                    driver: None,
                    stops: Vec::new(),
                    reply,
                })
                .unwrap();
            replies.push(response);
        }
        assert_eq!(
            worker.matrix(None, Vec::new()).await.unwrap_err(),
            "busy_or_unavailable"
        );
        drop(receiver);
        assert_eq!(
            worker.matrix(None, Vec::new()).await.unwrap_err(),
            "busy_or_unavailable"
        );
    }
    #[test]
    fn whole_query_fallback_remains_labelled_and_attributed() {
        let (sender, _receiver) = mpsc::sync_channel(1);
        let worker = Worker {
            sender,
            matrices: SharedMatrices::default(),
            estimate: TravelEstimate {
                map_date: Some("2026-10-03".into()),
                attribution: Some("OSM".into()),
                ..TravelEstimate::default()
            },
        };
        let fallback = worker
            .fallback(&[Coordinate {
                lat: 36.716,
                lng: 15.09,
            }])
            .unwrap();
        assert!(fallback.estimate().approximate);
        assert_eq!(fallback.estimate().attribution.as_deref(), Some("OSM"));
    }
    #[tokio::test]
    async fn overload_reuses_only_exact_native_query_and_keeps_nulls() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let a = Coordinate {
            lat: 36.716,
            lng: 15.09,
        };
        let b = Coordinate {
            lat: 36.74,
            lng: 15.13,
        };
        let driver = Coordinate {
            lat: 36.717,
            lng: 15.091,
        };
        let points = [a, b, driver];
        let native = vec![
            vec![Some(0), None, Some(5)],
            vec![None, Some(0), None],
            vec![Some(4), None, Some(0)],
        ];
        let matrices = SharedMatrices::default();
        matrices
            .lock()
            .unwrap()
            .push_front((points.iter().map(|p| (*p).into()).collect(), native));
        let worker = Worker {
            sender,
            matrices,
            estimate: TravelEstimate {
                mode: TravelMode::EmbeddedOsrm,
                approximate: false,
                notice: None,
                map_date: Some("2026-10-03".into()),
                attribution: Some("OSM".into()),
            },
        };
        drop(receiver); // Exercise the actual RoutingService failure dispatch.
        let service = RoutingService {
            native: Some(worker),
            control: None,
        };
        let cached = service.matrix(Some(driver), vec![a, b]).await.unwrap();
        assert_eq!(cached.estimate().mode, TravelMode::EmbeddedOsrm);
        assert_eq!(cached.seconds(a, b), None);
        assert_eq!(cached.seconds(driver, a), Some(4));
        let moved = Coordinate {
            lat: 36.71701,
            ..driver
        };
        assert_eq!(
            service
                .matrix(Some(moved), vec![a, b])
                .await
                .unwrap()
                .estimate()
                .mode,
            TravelMode::ApproximateFallback
        );
        assert_eq!(
            service
                .matrix(Some(driver), vec![b, a])
                .await
                .unwrap()
                .estimate()
                .mode,
            TravelMode::ApproximateFallback
        );
    }
    #[test]
    fn rejects_unbuffered_or_mismatched_manifest() {
        let mut manifest = Manifest {
            format_version: 1,
            osrm_version: "6.0.0".into(),
            binding_version: "0.8.2".into(),
            algorithm: "CH".into(),
            profile: "car.lua".into(),
            osm_timestamp: "2026-10-03T00:00:00Z".into(),
            data_file: "region.osrm".into(),
            service_bounds: [15.0, 36.6, 15.2, 36.95],
            extract_bounds: [14.9, 36.5, 15.3, 37.0],
            files: REQUIRED_SUFFIXES
                .iter()
                .map(|ext| (format!("region.osrm.{ext}"), "a".repeat(64)))
                .collect(),
        };
        assert!(manifest.validate().is_ok());
        let hash = manifest.files.remove("region.osrm.ebg_nodes").unwrap();
        assert!(
            manifest.validate().is_err(),
            "every runtime graph must be checksummed"
        );
        manifest.files.insert("region.osrm.ebg_nodes".into(), hash);
        manifest.osrm_version = "5.27.1".into();
        assert!(manifest.validate().is_err());
        manifest.osrm_version = "6.0.0".into();
        manifest.extract_bounds = manifest.service_bounds;
        assert!(manifest.validate().is_err());
    }
}
