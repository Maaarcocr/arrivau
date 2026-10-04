//! Bounded, offline travel-time matrices. No HTTP routing client is compiled.
//!
//! OSRM owns a single long-lived native engine on its worker thread. Queries
//! never hold SQLite's mutex; callers must revalidate snapshots before writes.
use crate::model::Coordinate;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const MAX_MATRIX_POINTS: usize = 35;
pub const APPROXIMATE_NOTICE: &str =
    "Tempi di viaggio approssimativi: stima in linea d'aria, senza viabilità o traffico.";
pub const FALLBACK_NOTICE: &str = "Percorso stradale non disponibile per quest'area o al momento: tempi approssimativi in linea d'aria. Verifica il percorso prima di assegnare.";

/// Direction matters. An unreachable leg MUST remain None, never zero.
pub trait TravelTimes {
    fn seconds(&self, from: Coordinate, to: Coordinate) -> Option<i64>;
    fn estimate(&self) -> TravelEstimate;
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TravelMode {
    Approximate,
    EmbeddedOsrm,
    ApproximateFallback,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TravelEstimate {
    pub mode: TravelMode,
    pub approximate: bool,
    pub notice: Option<String>,
    pub map_date: Option<String>,
    pub attribution: Option<String>,
}
impl Default for TravelEstimate {
    fn default() -> Self {
        Self {
            mode: TravelMode::Approximate,
            approximate: true,
            notice: Some(APPROXIMATE_NOTICE.into()),
            map_date: None,
            attribution: None,
        }
    }
}

pub struct Approximate;
impl TravelTimes for Approximate {
    fn seconds(&self, from: Coordinate, to: Coordinate) -> Option<i64> {
        (from.valid() && to.valid()).then(|| approximate_seconds(from, to))
    }
    fn estimate(&self) -> TravelEstimate {
        TravelEstimate::default()
    }
}

pub fn approximate_seconds(from: Coordinate, to: Coordinate) -> i64 {
    let lat_delta = (to.lat - from.lat).to_radians();
    let lng_delta = (to.lng - from.lng).to_radians();
    let a = ((lat_delta / 2.0).sin().powi(2)
        + from.lat.to_radians().cos()
            * to.lat.to_radians().cos()
            * (lng_delta / 2.0).sin().powi(2))
    .clamp(0.0, 1.0);
    let meters = 6_371_000.0 * 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
    (meters * 1.3 / (25_000.0 / 3600.0)).ceil() as i64
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct PointKey(u64, u64);
impl From<Coordinate> for PointKey {
    fn from(point: Coordinate) -> Self {
        // Canonicalize negative zero without rounding GPS coordinates.
        Self((point.lat + 0.0).to_bits(), (point.lng + 0.0).to_bits())
    }
}

#[derive(Clone, Debug)]
pub struct TravelMatrix {
    indexes: HashMap<PointKey, usize>,
    seconds: Vec<Vec<Option<i64>>>,
    estimate: TravelEstimate,
}
impl TravelMatrix {
    /// Validates shape and values at the native boundary. Null remains unreachable.
    pub fn new(
        points: &[Coordinate],
        seconds: Vec<Vec<Option<i64>>>,
        estimate: TravelEstimate,
    ) -> Result<Self, String> {
        if points.len() > MAX_MATRIX_POINTS
            || points.iter().any(|point| !point.valid())
            || seconds.len() != points.len()
            || seconds.iter().any(|row| {
                row.len() != points.len() || row.iter().flatten().any(|seconds| *seconds < 0)
            })
        {
            return Err("Invalid travel matrix".into());
        }
        Ok(Self {
            indexes: points
                .iter()
                .enumerate()
                .map(|(i, p)| ((*p).into(), i))
                .collect(),
            seconds,
            estimate,
        })
    }
    pub fn approximate(points: &[Coordinate], fallback: bool) -> Result<Self, String> {
        if points.len() > MAX_MATRIX_POINTS || points.iter().any(|point| !point.valid()) {
            return Err("Route exceeds travel matrix limits".into());
        }
        let mut estimate = TravelEstimate::default();
        if fallback {
            estimate.mode = TravelMode::ApproximateFallback;
            estimate.notice = Some(FALLBACK_NOTICE.into());
        }
        Self::new(
            points,
            points
                .iter()
                .map(|from| {
                    points
                        .iter()
                        .map(|to| {
                            (from.valid() && to.valid()).then(|| approximate_seconds(*from, *to))
                        })
                        .collect()
                })
                .collect(),
            estimate,
        )
    }
}
impl TravelTimes for TravelMatrix {
    fn seconds(&self, from: Coordinate, to: Coordinate) -> Option<i64> {
        let from = *self.indexes.get(&from.into())?;
        let to = *self.indexes.get(&to.into())?;
        self.seconds[from][to]
    }
    fn estimate(&self) -> TravelEstimate {
        self.estimate.clone()
    }
}

/// Collect only this driver's outstanding job points plus the candidate. A
/// matrix must never grow with a team's delivery history or other teams' data.
pub fn plan_points(
    driver: &crate::model::Driver,
    jobs: &[crate::model::Delivery],
    candidate: Option<&crate::model::Delivery>,
) -> Vec<Coordinate> {
    use crate::model::DeliveryStatus;
    let mut points = Vec::new();
    for job in jobs
        .iter()
        .filter(|job| {
            job.driver_id.as_deref() == Some(driver.id.as_str())
                && matches!(
                    job.status,
                    DeliveryStatus::Assigned | DeliveryStatus::PickedUp
                )
        })
        .chain(candidate)
    {
        if job.status != DeliveryStatus::PickedUp {
            push_unique(&mut points, job.pickup);
        }
        push_unique(&mut points, job.dropoff);
    }
    points
}

fn push_unique(points: &mut Vec<Coordinate>, point: Coordinate) {
    if !points
        .iter()
        .any(|other| PointKey::from(*other) == point.into())
    {
        points.push(point);
    }
}

#[cfg(test)]
#[derive(Default)]
pub(crate) struct TestControl {
    pub started: tokio::sync::Notify,
    pub release: tokio::sync::Notify,
    pub block_next: std::sync::atomic::AtomicBool,
    pub fail_next: std::sync::atomic::AtomicBool,
    pub calls: std::sync::atomic::AtomicUsize,
}

#[derive(Clone, Default)]
pub struct RoutingService {
    #[cfg(test)]
    control: Option<std::sync::Arc<TestControl>>,
    #[cfg(feature = "embedded-osrm")]
    native: Option<native::Worker>,
}
impl RoutingService {
    #[cfg(test)]
    pub(crate) fn controlled() -> (Self, std::sync::Arc<TestControl>) {
        let control = std::sync::Arc::new(TestControl::default());
        (
            Self {
                control: Some(control.clone()),
                #[cfg(feature = "embedded-osrm")]
                native: None,
            },
            control,
        )
    }
    pub fn is_embedded(&self) -> bool {
        #[cfg(test)]
        if self.control.is_some() {
            return true;
        }
        #[cfg(feature = "embedded-osrm")]
        {
            self.native.is_some()
        }
        #[cfg(not(feature = "embedded-osrm"))]
        {
            false
        }
    }
    pub fn from_env() -> Result<Self, String> {
        let mode = std::env::var("ARRIVAU_ROUTING").unwrap_or_else(|_| "approximate".into());
        match mode.as_str() {
            "approximate" => {
                if std::env::var_os("ARRIVAU_OSRM_DATASET").is_some() {
                    return Err(
                        "ARRIVAU_OSRM_DATASET requires ARRIVAU_ROUTING=embedded-osrm".into(),
                    );
                }
                Ok(Self::default())
            }
            "embedded-osrm" => {
                #[cfg(feature = "embedded-osrm")]
                {
                    let path = std::env::var("ARRIVAU_OSRM_DATASET").map_err(|_| {
                        "ARRIVAU_OSRM_DATASET must name an absolute dataset manifest"
                    })?;
                    Self::embedded(std::path::Path::new(&path))
                }
                #[cfg(not(feature = "embedded-osrm"))]
                Err("Rebuild with --features embedded-osrm before enabling ARRIVAU_ROUTING=embedded-osrm".into())
            }
            _ => Err("ARRIVAU_ROUTING must be approximate or embedded-osrm".into()),
        }
    }

    /// Runtime failures use a visibly labelled local approximation. Missing or
    /// incompatible deployment configuration fails at startup instead.
    pub async fn matrix(
        &self,
        driver: Option<Coordinate>,
        stops: Vec<Coordinate>,
    ) -> Result<TravelMatrix, String> {
        let mut points = stops.clone();
        if let Some(point) = driver {
            push_unique(&mut points, point);
        }
        if points.len() > MAX_MATRIX_POINTS || points.iter().any(|point| !point.valid()) {
            return Err("Route exceeds travel matrix limits".into());
        }
        #[cfg(test)]
        if let Some(control) = &self.control {
            use std::sync::atomic::Ordering;
            control.calls.fetch_add(1, Ordering::SeqCst);
            if control.block_next.swap(false, Ordering::SeqCst) {
                control.started.notify_one();
                control.release.notified().await;
            }
            if control.fail_next.swap(false, Ordering::SeqCst) {
                return Err("Injected routing preparation failure".into());
            }
        }
        #[cfg(feature = "embedded-osrm")]
        if let Some(worker) = &self.native {
            return match worker.matrix(driver, stops).await {
                Ok(matrix) => Ok(matrix),
                Err(reason) => {
                    // No coordinates, delivery IDs, addresses or native error text.
                    tracing::warn!(
                        reason,
                        "Embedded routing unavailable; exact cached road matrix or labelled approximation"
                    );
                    worker.fallback(&points)
                }
            };
        }
        TravelMatrix::approximate(&points, false)
    }

    #[cfg(feature = "embedded-osrm")]
    pub fn embedded(manifest: &std::path::Path) -> Result<Self, String> {
        Ok(Self {
            native: Some(native::Worker::start(manifest)?),
            #[cfg(test)]
            control: None,
        })
    }
}

#[cfg(feature = "embedded-osrm")]
mod native;

#[cfg(test)]
mod tests {
    use super::*;
    fn a() -> Coordinate {
        Coordinate {
            lat: 36.7163,
            lng: 15.0908,
        }
    }
    fn b() -> Coordinate {
        Coordinate {
            lat: 36.73,
            lng: 15.1,
        }
    }
    #[test]
    fn directed_nulls_and_missing_points_stay_unreachable() {
        let matrix = TravelMatrix::new(
            &[a(), b()],
            vec![vec![Some(0), Some(42)], vec![None, Some(0)]],
            TravelEstimate::default(),
        )
        .unwrap();
        assert_eq!(matrix.seconds(a(), b()), Some(42));
        assert_eq!(matrix.seconds(b(), a()), None);
        assert_eq!(matrix.seconds(a(), Coordinate { lat: 0.0, lng: 0.0 }), None);
    }
    #[test]
    fn invalid_matrices_are_rejected() {
        assert!(
            TravelMatrix::new(&[a(), b()], vec![vec![Some(0)]], TravelEstimate::default()).is_err()
        );
        assert!(
            TravelMatrix::new(&[a()], vec![vec![Some(-1)]], TravelEstimate::default()).is_err()
        );
        assert!(TravelMatrix::approximate(&vec![a(); MAX_MATRIX_POINTS + 1], false).is_err());
    }
    #[test]
    fn fallback_is_explicit_and_in_italian() {
        let matrix = TravelMatrix::approximate(&[a(), b()], true).unwrap();
        assert!(matrix.estimate().approximate);
        assert_eq!(matrix.estimate().mode, TravelMode::ApproximateFallback);
        assert!(matrix
            .estimate()
            .notice
            .unwrap()
            .contains("Verifica il percorso"));
    }
}
