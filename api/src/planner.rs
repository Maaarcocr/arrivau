//! Small-fleet pickup/dropoff insertion heuristic. Existing relative stop order is
//! retained; every possible ordered insertion pair is evaluated. Distances are
//! selected by an injected directed matrix; the compatibility wrappers use the
//! explicit air-line approximation. No native calls occur inside the search.
use crate::model::*;
use crate::routing::{Approximate, TravelTimes};
use std::collections::{HashMap, HashSet};

const HANDLING_SECONDS: i64 = 60;
pub const LOCATION_FRESHNESS_SECONDS: i64 = 300;
pub const MAX_ROUTE_STOPS: usize = 32;
pub const PICKUP_TARGET_SECONDS: i64 = 600;
/// A supervised-pilot policy, not a guarantee: the total extra delay after
/// pickup is bounded against one persisted ETA, never reset by new insertions.
pub const MAX_ADDITIONAL_ONBOARD_SECONDS: i64 = 300;

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
    crate::routing::approximate_seconds(from, to)
}

pub fn evaluate(driver: &Driver, keys: &[StopKey], jobs: &[Delivery], now: i64) -> Route {
    evaluate_with_travel(driver, keys, jobs, now, &Approximate)
}

pub fn evaluate_with_travel(
    driver: &Driver,
    keys: &[StopKey],
    jobs: &[Delivery],
    now: i64,
    travel: &dyn TravelTimes,
) -> Route {
    let mut route = Route {
        travel_estimate: travel.estimate(),
        driver_id: driver.id.clone(),
        stops: Vec::new(),
        travel_seconds: 0,
        finish_at: now,
        feasible: true,
        warnings: Vec::new(),
        notices: Vec::new(),
        estimates_available: driver.location.is_some(),
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
        let travel = match current {
            Some(from) => match travel.seconds(from, coordinate) {
                Some(seconds) => seconds,
                None => {
                    route.estimates_available = false;
                    route.warnings.push(format!(
                        "Percorso stradale non raggiungibile per {}",
                        job.id
                    ));
                    // Compatibility-only numeric placeholder; never a cost usable
                    // for assignment. Clients hide ETAs when estimates unavailable.
                    1
                }
            },
            None => 0, // No GPS is explicitly unavailable, not a routed zero leg.
        };
        route.travel_seconds = route.travel_seconds.saturating_add(travel);
        time = time.saturating_add(travel);
        match key.kind {
            StopKind::Pickup => {
                if let Some(ready_at) = job.readiness_at() {
                    time = time.max(ready_at);
                    if time > ready_at.saturating_add(PICKUP_TARGET_SECONDS) {
                        route
                            .notices
                            .push(format!("Pickup target missed for {}", job.id));
                    }
                } else {
                    route
                        .warnings
                        .push(format!("Readiness is unknown for {}", job.id));
                }
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
                if job.onboard_deadline_at.is_some_and(|limit| time > limit) {
                    route
                        .warnings
                        .push(format!("Onboard delivery delay exceeded for {}", job.id));
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
    insert_with_travel(driver, current, jobs, candidate, now, &Approximate)
}

pub fn insert_with_travel(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
    travel: &dyn TravelTimes,
) -> Option<(Vec<StopKey>, Route)> {
    if !driver.active
        || !location_is_fresh(driver, now)
        || candidate.readiness_at().is_none()
        || candidate.load_units > driver.capacity
    {
        return None;
    }
    best_insertion(driver, current, jobs, candidate, now, false, travel)
}

/// Automatic dispatch must still pick the least-bad driver when timing targets
/// cannot all be met. Active shift and structurally safe capacity/precedence are
/// mandatory; elapsed time and stale GPS remain visible as warnings.
pub fn insert_for_dispatch(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
) -> Option<(Vec<StopKey>, Route)> {
    insert_for_dispatch_with_travel(driver, current, jobs, candidate, now, &Approximate)
}

pub fn insert_for_dispatch_with_travel(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
    travel: &dyn TravelTimes,
) -> Option<(Vec<StopKey>, Route)> {
    if !driver.active
        || candidate.readiness_at().is_none()
        || candidate.load_units > driver.capacity
    {
        return None;
    }
    if driver.location.is_none() {
        // Queue after committed work instead of inventing a starting position.
        let mut keys = current.to_vec();
        if keys.len() + 2 > MAX_ROUTE_STOPS {
            return None;
        }
        keys.push(StopKey {
            delivery_id: candidate.id.clone(),
            kind: StopKind::Pickup,
        });
        keys.push(StopKey {
            delivery_id: candidate.id.clone(),
            kind: StopKind::Dropoff,
        });
        let mut proposed_jobs = jobs.to_vec();
        let mut assigned = candidate.clone();
        assigned.driver_id = Some(driver.id.clone());
        assigned.status = DeliveryStatus::Assigned;
        proposed_jobs.retain(|job| job.id != candidate.id);
        proposed_jobs.push(assigned);
        let route = evaluate_with_travel(driver, &keys, &proposed_jobs, now, travel);
        return structurally_safe(&route).then_some((keys, route));
    }
    best_insertion(driver, current, jobs, candidate, now, true, travel)
}

/// A readiness report is a fact, even when its timing is no longer feasible.
/// Preserve every stop and use recovery ranking to protect food already aboard.
/// Fresh assignments still use insert() and require every hard constraint.
pub fn replan_readiness(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
) -> (Vec<StopKey>, Route) {
    replan_readiness_with_travel(driver, current, jobs, candidate, now, &Approximate)
}

pub fn replan_readiness_with_travel(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
    travel: &dyn TravelTimes,
) -> (Vec<StopKey>, Route) {
    if driver.location.is_none() {
        let base: Vec<_> = current
            .iter()
            .filter(|key| key.delivery_id != candidate.id)
            .cloned()
            .collect();
        return insert_for_dispatch_with_travel(driver, &base, jobs, candidate, now, travel)
            .unwrap_or_else(|| {
                (
                    current.to_vec(),
                    evaluate_with_travel(driver, current, jobs, now, travel),
                )
            });
    }
    best_insertion(driver, current, jobs, candidate, now, true, travel).unwrap_or_else(|| {
        (
            current.to_vec(),
            evaluate_with_travel(driver, current, jobs, now, travel),
        )
    })
}

fn best_insertion(
    driver: &Driver,
    current: &[StopKey],
    jobs: &[Delivery],
    candidate: &Delivery,
    now: i64,
    recovery: bool,
    travel: &dyn TravelTimes,
) -> Option<(Vec<StopKey>, Route)> {
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
    let baseline = evaluate_with_travel(driver, current, jobs, now, travel);
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
            let route = evaluate_with_travel(driver, &keys, &proposed_jobs, now, travel);
            if (route.feasible || (recovery && structurally_safe(&route)))
                && best
                    .as_ref()
                    .map(|(_, old)| {
                        route_rank(&route, &baseline, &proposed_jobs)
                            < route_rank(old, &baseline, &proposed_jobs)
                    })
                    .unwrap_or(true)
            {
                best = Some((keys, route));
            }
        }
    }
    best
}

fn structurally_safe(route: &Route) -> bool {
    route.warnings.iter().all(|warning| {
        warning.starts_with("Driver ")
            || warning.starts_with("Deadline missed for ")
            || warning.starts_with("Maximum ride time exceeded for ")
            || warning.starts_with("Onboard delivery delay exceeded for ")
    })
}

/// Finite preference for prompt pickups: one second past the ten-minute target
/// costs eight extra seconds, plus two per second of restaurant waiting. Hard
/// delivery guards are applied before this score. This is an insertion heuristic.
fn operating_cost(route: &Route, jobs: &[Delivery]) -> i64 {
    route
        .stops
        .iter()
        .filter(|stop| stop.kind == StopKind::Pickup)
        .fold(route.travel_seconds, |cost, stop| {
            let wait = jobs
                .iter()
                .find(|job| job.id == stop.delivery_id)
                .and_then(Delivery::readiness_at)
                .map(|ready| stop.arrival_at.saturating_sub(ready).max(0))
                .unwrap_or(0);
            cost.saturating_add(wait.saturating_mul(2)).saturating_add(
                wait.saturating_sub(PICKUP_TARGET_SECONDS)
                    .max(0)
                    .saturating_mul(8),
            )
        })
}

pub fn incremental_priority_cost(route: &Route, baseline: &Route, jobs: &[Delivery]) -> i64 {
    let extra_onboard = jobs
        .iter()
        .filter(|job| job.status == DeliveryStatus::PickedUp)
        .filter_map(|job| Some((dropoff_at(route, &job.id)?, dropoff_at(baseline, &job.id)?)))
        .map(|(after, before)| after.saturating_sub(before).max(0))
        .sum::<i64>();
    operating_cost(route, jobs)
        .saturating_sub(operating_cost(baseline, jobs))
        .saturating_add(extra_onboard)
}

pub fn dropoff_at(route: &Route, id: &str) -> Option<i64> {
    route
        .stops
        .iter()
        .find(|stop| stop.delivery_id == id && stop.kind == StopKind::Dropoff)
        .map(|stop| stop.arrival_at)
}

pub fn onboard_deadline(job: &Delivery, committed: &Route, now: i64) -> Option<i64> {
    if !committed.estimates_available {
        return None;
    }
    Some(
        dropoff_at(committed, &job.id)
            .unwrap_or(now)
            .saturating_add(MAX_ADDITIONAL_ONBOARD_SECONDS)
            .min(job.deadline_at)
            .min(
                job.picked_up_at
                    .unwrap_or(now)
                    .saturating_add(job.max_ride_seconds),
            ),
    )
}

/// Return lateness separately per constraint so recovery cannot trade worsening
/// one person's already-late delivery against improving a different one.
pub fn timing_overruns(route: &Route, jobs: &[Delivery]) -> HashMap<String, [i64; 3]> {
    jobs.iter()
        .filter_map(|job| {
            let dropoff = dropoff_at(route, &job.id)?;
            let pickup = job.picked_up_at.or_else(|| {
                route
                    .stops
                    .iter()
                    .find(|stop| stop.delivery_id == job.id && stop.kind == StopKind::Pickup)
                    .map(|stop| stop.arrival_at)
            });
            Some((
                job.id.clone(),
                [
                    dropoff.saturating_sub(job.deadline_at).max(0),
                    pickup
                        .map(|at| {
                            dropoff
                                .saturating_sub(at)
                                .saturating_sub(job.max_ride_seconds)
                                .max(0)
                        })
                        .unwrap_or(0),
                    job.onboard_deadline_at
                        .map(|at| dropoff.saturating_sub(at).max(0))
                        .unwrap_or(0),
                ],
            ))
        })
        .collect()
}

pub fn route_rank(route: &Route, baseline: &Route, jobs: &[Delivery]) -> (i64, i64, i64, i64, i64) {
    let overruns = timing_overruns(route, jobs);
    let onboard = jobs
        .iter()
        .filter(|job| job.status == DeliveryStatus::PickedUp)
        .filter_map(|job| overruns.get(&job.id))
        .flatten()
        .sum();
    let all = overruns.values().flatten().sum();
    (
        onboard,
        all,
        incremental_priority_cost(route, baseline, jobs),
        route.travel_seconds,
        route.finish_at,
    )
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
            ready_at: Some(1000),
            deadline_at: 5000,
            load_units: 1,
            max_ride_seconds: 1800,
            restaurant_id: None,
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

    fn stop(id: &str, kind: StopKind) -> StopKey {
        StopKey {
            delivery_id: id.into(),
            kind,
        }
    }
    fn nearby(id: &str, status: DeliveryStatus) -> Delivery {
        let mut job = job(id);
        job.dropoff = job.pickup;
        job.status = status;
        if status != DeliveryStatus::Pending {
            job.driver_id = Some("driver-1".into());
        }
        if status == DeliveryStatus::PickedUp {
            job.picked_up_at = Some(900);
        }
        job
    }

    #[test]
    fn unknown_readiness_never_becomes_an_urgent_or_executable_pickup() {
        let mut candidate = nearby("unknown", DeliveryStatus::Pending);
        candidate.ready_at = 0;
        candidate.readiness_state = ReadinessState::Unknown;
        assert!(insert(&driver(2), &[], &[], &candidate, 1000).is_none());
        assert!(insert_for_dispatch(&driver(2), &[], &[], &candidate, 1000).is_none());
        candidate.status = DeliveryStatus::Assigned;
        candidate.driver_id = Some("driver-1".into());
        let route = evaluate(
            &driver(2),
            &[
                stop("unknown", StopKind::Pickup),
                stop("unknown", StopKind::Dropoff),
            ],
            &[candidate],
            1000,
        );
        assert!(!route.feasible);
        assert!(route.notices.is_empty());
    }

    #[test]
    fn pickup_target_is_soft_with_exact_boundary_and_ready_time_wait() {
        let mut candidate = nearby("a", DeliveryStatus::Pending);
        candidate.ready_at = 400;
        let (_, route) = insert(&driver(2), &[], &[], &candidate, 1000).unwrap();
        assert!(route.feasible && route.notices.is_empty());
        candidate.ready_at = 399;
        let (_, route) = insert(&driver(2), &[], &[], &candidate, 1000).unwrap();
        assert!(route.feasible);
        assert_eq!(route.notices, vec!["Pickup target missed for a"]);
        candidate.ready_at = 1400;
        let (_, route) = insert(&driver(2), &[], &[], &candidate, 1000).unwrap();
        assert_eq!(route.stops[0].arrival_at, 1400);
    }

    #[test]
    fn urgent_pickup_can_delay_onboard_delivery_but_not_reset_its_guard() {
        let mut onboard = nearby("aboard", DeliveryStatus::PickedUp);
        onboard.onboard_deadline_at = Some(1300);
        let mut keys = vec![stop("aboard", StopKind::Dropoff)];
        let mut jobs = vec![onboard];
        let d = driver(8);
        for index in 0..7 {
            let mut candidate = nearby(&format!("ready-{index}"), DeliveryStatus::Pending);
            candidate.ready_at = 0;
            let (next, route) = insert(&d, &keys, &jobs, &candidate, 1000).unwrap();
            if index == 0 {
                assert_eq!(next[0], stop(&candidate.id, StopKind::Pickup));
                assert_eq!(dropoff_at(&route, "aboard"), Some(1060));
            }
            assert!(dropoff_at(&route, "aboard").unwrap() <= 1300);
            assert_eq!(jobs[0].onboard_deadline_at, Some(1300));
            candidate.status = DeliveryStatus::Assigned;
            candidate.driver_id = Some(d.id.clone());
            jobs.push(candidate);
            keys = next;
        }
        assert!(
            keys.iter()
                .position(|key| key.delivery_id == "aboard")
                .unwrap()
                <= 5
        );
    }

    #[test]
    fn additional_onboard_boundary_is_cumulative_and_deadline_remains_tighter() {
        let mut onboard = nearby("aboard", DeliveryStatus::PickedUp);
        onboard.onboard_deadline_at = Some(1300);
        let mut candidate = nearby("a", DeliveryStatus::Assigned);
        candidate.ready_at = 1240;
        let keys = [
            stop("a", StopKind::Pickup),
            stop("aboard", StopKind::Dropoff),
            stop("a", StopKind::Dropoff),
        ];
        assert!(
            evaluate(
                &driver(2),
                &keys,
                &[onboard.clone(), candidate.clone()],
                1000
            )
            .feasible
        );
        candidate.ready_at = 1241;
        let route = evaluate(
            &driver(2),
            &keys,
            &[onboard.clone(), candidate.clone()],
            1000,
        );
        assert!(!route.feasible);
        assert!(route
            .warnings
            .iter()
            .any(|warning| warning.contains("Onboard delivery delay")));
        onboard.deadline_at = 1250;
        let (_, route) = insert(
            &driver(2),
            &[stop("aboard", StopKind::Dropoff)],
            &[onboard],
            &candidate,
            1000,
        )
        .unwrap();
        assert_eq!(route.stops[0].delivery_id, "aboard");
    }

    #[test]
    fn delaying_assigned_food_reorders_behind_onboard_even_if_new_deadline_is_impossible() {
        let mut onboard = nearby("aboard", DeliveryStatus::PickedUp);
        onboard.onboard_deadline_at = Some(1300);
        let mut changed = nearby("delayed", DeliveryStatus::Assigned);
        changed.ready_at = 2000;
        changed.deadline_at = 1100;
        let current = [
            stop("delayed", StopKind::Pickup),
            stop("delayed", StopKind::Dropoff),
            stop("aboard", StopKind::Dropoff),
        ];
        let (keys, route) = replan_readiness(
            &driver(2),
            &current,
            &[onboard, changed.clone()],
            &changed,
            1000,
        );
        assert_eq!(keys[0], stop("aboard", StopKind::Dropoff));
        assert_eq!(keys.len(), 3);
        assert!(!route.feasible);
        assert_eq!(dropoff_at(&route, "aboard"), Some(1000));
    }

    #[test]
    fn dispatch_fallback_keeps_capacity_and_precedence_even_when_all_times_are_late() {
        let mut onboard = nearby("aboard", DeliveryStatus::PickedUp);
        onboard.deadline_at = 950;
        onboard.max_ride_seconds = 60;
        onboard.onboard_deadline_at = Some(960);
        let mut candidate = nearby("new", DeliveryStatus::Pending);
        candidate.deadline_at = 980;
        let current = [stop("aboard", StopKind::Dropoff)];
        assert!(insert(&driver(1), &current, &[onboard.clone()], &candidate, 1000).is_none());
        let (keys, route) =
            insert_for_dispatch(&driver(1), &current, &[onboard], &candidate, 1000).unwrap();
        assert_eq!(keys[0], stop("aboard", StopKind::Dropoff));
        assert_eq!(keys[1], stop("new", StopKind::Pickup));
        assert!(!route.feasible);
        assert!(!route
            .warnings
            .iter()
            .any(|warning| warning.contains("Capacity")));
    }

    #[test]
    fn readiness_edits_without_gps_never_jump_a_pickup_ahead_of_onboard_work() {
        let mut d = driver(2);
        d.location = None;
        d.location_updated_at = None;
        let aboard = nearby("aboard", DeliveryStatus::PickedUp);
        let mut changed = nearby("queued", DeliveryStatus::Assigned);
        changed.ready_at = 1000;
        changed.readiness_state = ReadinessState::Ready;
        let current = [
            stop("aboard", StopKind::Dropoff),
            stop("queued", StopKind::Pickup),
            stop("queued", StopKind::Dropoff),
        ];
        let (keys, route) =
            replan_readiness(&d, &current, &[aboard, changed.clone()], &changed, 1000);
        assert_eq!(keys, current);
        assert!(!route.estimates_available);
        assert_eq!(route.stops[0].delivery_id, "aboard");
    }
    #[test]
    fn native_unreachable_is_hard_even_for_late_or_no_gps_dispatch() {
        use crate::routing::{TravelEstimate, TravelMatrix, TravelMode};
        let mut d = driver(2);
        let candidate = job("unreachable");
        let a = candidate.pickup;
        let b = candidate.dropoff;
        let matrix = TravelMatrix::new(
            &[a, b],
            vec![vec![Some(0), None], vec![Some(90), Some(0)]],
            TravelEstimate {
                mode: TravelMode::EmbeddedOsrm,
                approximate: false,
                notice: None,
                map_date: None,
                attribution: None,
            },
        )
        .unwrap();
        assert!(insert_with_travel(&d, &[], &[], &candidate, 1000, &matrix).is_none());
        assert!(insert_for_dispatch_with_travel(&d, &[], &[], &candidate, 1000, &matrix).is_none());
        d.location = None;
        assert!(insert_for_dispatch_with_travel(&d, &[], &[], &candidate, 1000, &matrix).is_none());
    }
    #[test]
    fn no_gps_readiness_replan_preserves_native_unreachable_constraints() {
        use crate::routing::{TravelEstimate, TravelMatrix};
        let mut d = driver(2);
        d.location = None;
        let mut candidate = job("unreachable");
        candidate.status = DeliveryStatus::Assigned;
        candidate.driver_id = Some(d.id.clone());
        let keys = vec![
            stop(&candidate.id, StopKind::Pickup),
            stop(&candidate.id, StopKind::Dropoff),
        ];
        let matrix = TravelMatrix::new(
            &[candidate.pickup, candidate.dropoff],
            vec![vec![Some(0), None], vec![Some(90), Some(0)]],
            TravelEstimate::default(),
        )
        .unwrap();
        let (after, route) = replan_readiness_with_travel(
            &d,
            &keys,
            &[candidate.clone()],
            &candidate,
            1000,
            &matrix,
        );
        assert_eq!(after, keys);
        assert!(!route.feasible && !route.estimates_available);
        assert!(route
            .warnings
            .iter()
            .any(|warning| warning.starts_with("Percorso stradale non raggiungibile")));
    }
}
