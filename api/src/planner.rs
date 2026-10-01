//! Small-fleet pickup/dropoff insertion heuristic. Existing relative stop order is
//! retained; every possible ordered insertion pair is evaluated. Distances are
//! deliberately approximate, NOT a road-routing or traffic model.
use crate::model::*;
use std::collections::{HashMap, HashSet};

const HANDLING_SECONDS: i64 = 60;
pub const LOCATION_FRESHNESS_SECONDS: i64 = 300;
pub const MAX_ROUTE_STOPS: usize = 32;

pub fn location_is_fresh(driver: &Driver, now: i64) -> bool {
    driver.location.is_some()
        && driver
            .location_updated_at
            .map(|updated| {
                updated <= now && now.saturating_sub(updated) <= LOCATION_FRESHNESS_SECONDS
            })
            .unwrap_or(false)
}

pub fn travel_seconds(from: Coordinate, to: Coordinate) -> i64 {
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

pub fn evaluate(driver: &Driver, keys: &[StopKey], jobs: &[Delivery], now: i64) -> Route {
    let mut route = Route {
        driver_id: driver.id.clone(),
        stops: Vec::new(),
        travel_seconds: 0,
        finish_at: now,
        feasible: true,
        warnings: Vec::new(),
    };
    let assigned: HashMap<&str, &Delivery> = jobs
        .iter()
        .filter(|job| {
            job.driver_id.as_deref() == Some(driver.id.as_str())
                && matches!(
                    job.status,
                    DeliveryStatus::Assigned | DeliveryStatus::PickedUp
                )
        })
        .map(|job| (job.id.as_str(), job))
        .collect();
    if keys.is_empty() && assigned.is_empty() {
        return route;
    }
    if !driver.active {
        route.warnings.push("Driver is not on shift".into());
    }
    if driver.location.is_none() {
        route.warnings.push("Driver location is unavailable".into());
    }
    if driver.location.is_some() && !location_is_fresh(driver, now) {
        route
            .warnings
            .push("Driver location is older than 5 minutes; estimates may be inaccurate".into());
    }
    let mut current = driver.location;
    let mut onboard: HashMap<&str, i64> = HashMap::new();
    let mut load = 0;
    for job in assigned.values() {
        if job.status == DeliveryStatus::PickedUp {
            onboard.insert(job.id.as_str(), job.picked_up_at.unwrap_or(now));
            load += job.load_units;
        }
    }
    if load > driver.capacity {
        route.warnings.push("Onboard load exceeds capacity".into());
    }
    let mut seen = HashSet::new();
    let mut time = now;
    for key in keys {
        if !seen.insert(key.clone()) {
            route
                .warnings
                .push(format!("Duplicate stop for {}", key.delivery_id));
        }
        let Some(job) = assigned.get(key.delivery_id.as_str()) else {
            route
                .warnings
                .push(format!("Invalid route reference {}", key.delivery_id));
            continue;
        };
        let (coordinate, address) = match key.kind {
            StopKind::Pickup => (job.pickup, job.pickup_address.clone()),
            StopKind::Dropoff => (job.dropoff, job.dropoff_address.clone()),
        };
        let travel = current
            .map(|from| travel_seconds(from, coordinate))
            .unwrap_or(0);
        route.travel_seconds = route.travel_seconds.saturating_add(travel);
        time = time.saturating_add(travel);
        match key.kind {
            StopKind::Pickup => {
                time = time.max(job.ready_at);
                if job.status == DeliveryStatus::PickedUp || onboard.contains_key(job.id.as_str()) {
                    route
                        .warnings
                        .push(format!("Duplicate pickup for {}", job.id));
                }
                onboard.insert(job.id.as_str(), time);
                load += job.load_units;
                if load > driver.capacity {
                    route
                        .warnings
                        .push(format!("Capacity exceeded at pickup {}", job.id));
                }
            }
            StopKind::Dropoff => {
                if let Some(picked_at) = onboard.remove(job.id.as_str()) {
                    if time.saturating_sub(picked_at) > job.max_ride_seconds {
                        route
                            .warnings
                            .push(format!("Maximum ride time exceeded for {}", job.id));
                    }
                } else {
                    route
                        .warnings
                        .push(format!("Dropoff precedes pickup for {}", job.id));
                }
                load -= job.load_units;
                if time > job.deadline_at {
                    route
                        .warnings
                        .push(format!("Deadline missed for {}", job.id));
                }
            }
        }
        let departure = time.saturating_add(HANDLING_SECONDS);
        route.stops.push(RouteStop {
            delivery_id: job.id.clone(),
            kind: key.kind,
            address,
            coordinate,
            arrival_at: time,
            departure_at: departure,
        });
        time = departure;
        current = Some(coordinate);
    }
    // Never report a route feasible if persisted ordering omitted outstanding work.
    for job in assigned.values() {
        for kind in [StopKind::Pickup, StopKind::Dropoff] {
            if kind == StopKind::Pickup && job.status == DeliveryStatus::PickedUp {
                continue;
            }
            if !seen.contains(&StopKey {
                delivery_id: job.id.clone(),
                kind,
            }) {
                route
                    .warnings
                    .push(format!("Missing {:?} stop for {}", kind, job.id));
            }
        }
    }
    route.finish_at = time;
    route.feasible = route.warnings.is_empty();
    route
}

pub fn insert(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
) -> Option<(Vec<StopKey>, Route)> {
    if !driver.active || !location_is_fresh(driver, now) || candidate.load_units > driver.capacity {
        return None;
    }
    let base: Vec<StopKey> = current
        .iter()
        .filter(|stop| stop.delivery_id != candidate.id)
        .cloned()
        .collect();
    if base.len() + 2 > MAX_ROUTE_STOPS {
        return None;
    }
    let mut proposed_jobs: Vec<Delivery> = jobs
        .iter()
        .filter(|j| j.id != candidate.id)
        .cloned()
        .collect();
    let mut assigned_candidate = candidate.clone();
    assigned_candidate.driver_id = Some(driver.id.clone());
    assigned_candidate.status = DeliveryStatus::Assigned;
    proposed_jobs.push(assigned_candidate);
    let mut best: Option<(Vec<StopKey>, Route)> = None;
    for pickup_index in 0..=base.len() {
        for dropoff_index in (pickup_index + 1)..=(base.len() + 1) {
            let mut keys = base.clone();
            keys.insert(
                pickup_index,
                StopKey {
                    delivery_id: candidate.id.clone(),
                    kind: StopKind::Pickup,
                },
            );
            keys.insert(
                dropoff_index,
                StopKey {
                    delivery_id: candidate.id.clone(),
                    kind: StopKind::Dropoff,
                },
            );
            let route = evaluate(driver, &keys, &proposed_jobs, now);
            if route.feasible
                && best
                    .as_ref()
                    .map(|(_, old)| {
                        (route.travel_seconds, route.finish_at)
                            < (old.travel_seconds, old.finish_at)
                    })
                    .unwrap_or(true)
            {
                best = Some((keys, route));
            }
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    fn driver(capacity: i32) -> Driver {
        Driver {
            id: "driver-1".into(),
            name: "One".into(),
            active: true,
            capacity,
            location: Some(Coordinate {
                lat: 36.7163,
                lng: 15.0908,
            }),
            location_updated_at: Some(1000),
        }
    }
    fn job(id: &str) -> Delivery {
        NewDelivery {
            shop_name: "Pizza".into(),
            pickup_address: "A".into(),
            dropoff_address: "B".into(),
            pickup: driver(2).location.unwrap(),
            dropoff: Coordinate {
                lat: 36.717,
                lng: 15.092,
            },
            ready_at: 1000,
            deadline_at: 5000,
            load_units: 1,
            max_ride_seconds: 1800,
        }
        .into_delivery(1000)
        .with_id(id)
    }
    impl Delivery {
        fn with_id(mut self, id: &str) -> Self {
            self.id = id.into();
            self
        }
    }
    #[test]
    fn inserts_pair_in_precedence_order_and_honors_ready_time() {
        let mut candidate = job("a");
        candidate.ready_at = 1200;
        let (keys, route) = insert(&driver(1), &[], &[], &candidate, 1000).unwrap();
        assert_eq!(keys[0].kind, StopKind::Pickup);
        assert_eq!(keys[1].kind, StopKind::Dropoff);
        assert_eq!(route.stops[0].arrival_at, 1200);
        assert_eq!(route.stops[0].departure_at, 1260);
        assert!(route.feasible);
    }
    #[test]
    fn sequential_insertions_respect_capacity_instead_of_rejecting_all_batching() {
        let a = job("a");
        let b = job("b");
        let d = driver(1);
        let (keys, _) = insert(&d, &[], &[], &a, 1000).unwrap();
        let mut assigned = a;
        assigned.driver_id = Some(d.id.clone());
        assigned.status = DeliveryStatus::Assigned;
        let (keys, route) = insert(&d, &keys, &[assigned], &b, 1000).unwrap();
        assert!(route.feasible);
        assert_eq!(keys.len(), 4);
        assert_eq!(keys[0].kind, StopKind::Pickup);
        assert_eq!(keys[1].kind, StopKind::Dropoff);
        assert_eq!(keys[2].kind, StopKind::Pickup);
        assert_eq!(keys[3].kind, StopKind::Dropoff);
    }
    #[test]
    fn rejects_capacity_deadline_and_freshness_violations() {
        let d = driver(1);
        let mut candidate = job("a");
        candidate.load_units = 2;
        assert!(insert(&d, &[], &[], &candidate, 1000).is_none());
        candidate.load_units = 1;
        candidate.deadline_at = 1010;
        assert!(insert(&d, &[], &[], &candidate, 1000).is_none());
        candidate.deadline_at = 10000;
        candidate.max_ride_seconds = 60;
        assert!(insert(&d, &[], &[], &candidate, 1000).is_none());
    }
    #[test]
    fn expired_onboard_work_remains_visible_and_infeasible() {
        let d = driver(1);
        let mut a = job("a");
        a.driver_id = Some(d.id.clone());
        a.status = DeliveryStatus::PickedUp;
        a.picked_up_at = Some(1000);
        a.max_ride_seconds = 60;
        let keys = [StopKey {
            delivery_id: a.id.clone(),
            kind: StopKind::Dropoff,
        }];
        let route = evaluate(&d, &keys, &[a], 1100);
        assert!(!route.feasible);
        assert_eq!(route.stops.len(), 1);
        assert!(route.warnings.iter().any(|w| w.contains("ride time")));
    }
    #[test]
    fn rejects_missing_and_reversed_stops() {
        let d = driver(2);
        let mut a = job("a");
        a.driver_id = Some(d.id.clone());
        a.status = DeliveryStatus::Assigned;
        assert!(!evaluate(&d, &[], &[a.clone()], 1000).feasible);
        let keys = [
            StopKey {
                delivery_id: a.id.clone(),
                kind: StopKind::Dropoff,
            },
            StopKey {
                delivery_id: a.id.clone(),
                kind: StopKind::Pickup,
            },
        ];
        assert!(!evaluate(&d, &keys, &[a], 1000).feasible);
    }
    #[test]
    fn distance_handles_antipodes_and_identical_coordinates() {
        let origin = Coordinate { lat: 0.0, lng: 0.0 };
        assert_eq!(travel_seconds(origin, origin), 0);
        assert!(
            travel_seconds(
                origin,
                Coordinate {
                    lat: 0.0,
                    lng: 180.0
                }
            ) > 0
        );
    }
}
