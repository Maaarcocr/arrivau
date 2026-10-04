#![cfg(feature = "embedded-osrm")]
use arrivau_api::{
    model::Coordinate,
    routing::{RoutingService, TravelMode, TravelTimes},
};
use std::path::Path;

fn coordinate(lat: f64, lng: f64) -> Coordinate {
    Coordinate { lat, lng }
}

// CI explicitly prepares the checked-in synthetic graph and runs ignored tests.
// A native feature compilation alone or a mocked engine cannot satisfy this.
#[tokio::test]
#[ignore = "requires scripts/test-embedded-routing.sh synthetic native dataset"]
async fn native_directed_unreachable_snapping_and_fresh_driver_matrix() {
    let path =
        std::env::var("ARRIVAU_TEST_OSRM_MANIFEST").expect("native fixture manifest required");
    let service = RoutingService::embedded(Path::new(&path)).expect("actual native OSRM startup");
    let a = coordinate(36.7160, 15.0910);
    let b = coordinate(36.7160, 15.0930);
    let c = coordinate(36.7400, 15.1310);
    let driver = coordinate(36.7200, 15.0910);
    let matrix = service.matrix(Some(driver), vec![a, b, c]).await.unwrap();
    assert_eq!(matrix.estimate().mode, TravelMode::EmbeddedOsrm);
    assert!(!matrix.estimate().approximate);
    assert!(matrix.seconds(a, b).unwrap() > 0);
    assert!(matrix.seconds(b, a).unwrap() > matrix.seconds(a, b).unwrap());
    assert_eq!(
        matrix.seconds(a, c),
        None,
        "disconnected roads must not become zero or air-line estimates"
    );
    assert_eq!(matrix.seconds(c, a), None);
    let moved = coordinate(36.7160, 15.0920);
    let fresh = service.matrix(Some(moved), vec![a, b, c]).await.unwrap();
    assert_eq!(fresh.estimate().mode, TravelMode::EmbeddedOsrm);
    assert_ne!(fresh.seconds(moved, b), matrix.seconds(driver, b));
    assert_eq!(fresh.seconds(a, b), matrix.seconds(a, b));
    let outside = service
        .matrix(Some(coordinate(40.0, 12.0)), vec![a])
        .await
        .unwrap();
    assert_eq!(outside.estimate().mode, TravelMode::ApproximateFallback);
    let no_snap = service
        .matrix(Some(coordinate(36.73, 15.11)), vec![a])
        .await
        .unwrap();
    assert_eq!(no_snap.estimate().mode, TravelMode::ApproximateFallback);
    assert!(no_snap
        .estimate()
        .notice
        .unwrap()
        .contains("approssimativi"));
    // Failure to snap the driver must never turn a native impossible road
    // leg between supported stops into a finite air-line estimate.
    let mixed_driver = service
        .matrix(Some(coordinate(36.73, 15.11)), vec![a, b, c])
        .await
        .unwrap();
    assert_eq!(
        mixed_driver.estimate().mode,
        TravelMode::ApproximateFallback
    );
    assert_eq!(mixed_driver.seconds(a, c), None);
    assert_eq!(mixed_driver.seconds(a, b), matrix.seconds(a, b));
    assert!(mixed_driver.estimate().attribution.is_some());
    let outside_driver = service
        .matrix(Some(coordinate(40.0, 12.0)), vec![a, c])
        .await
        .unwrap();
    assert_eq!(outside_driver.seconds(a, c), None);
    // Also test a new static key that mixes covered, disconnected and unsnappable stops.
    for _ in 0..2 {
        let mixed_stops = service
            .matrix(Some(driver), vec![a, c, coordinate(36.73, 15.11)])
            .await
            .unwrap();
        assert_eq!(mixed_stops.estimate().mode, TravelMode::ApproximateFallback);
        assert_eq!(mixed_stops.seconds(a, c), None);
        assert!(mixed_stops.estimate().attribution.is_some());
    }
}

#[tokio::test]
#[ignore = "requires scripts/test-embedded-routing.sh synthetic native dataset"]
async fn http_planning_uses_native_costs_and_never_auto_assigns_disconnected_work() {
    use arrivau_api::{app, AppState, Clock};
    use serde_json::{json, Value};
    use std::sync::Arc;
    struct FixedClock;
    impl Clock for FixedClock {
        fn now(&self) -> i64 {
            1000
        }
    }
    let path = std::env::var("ARRIVAU_TEST_OSRM_MANIFEST").unwrap();
    let service = RoutingService::embedded(Path::new(&path)).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::open_with_clock(
        dir.path().join("native.sqlite3"),
        true,
        Arc::new(FixedClock),
    )
    .unwrap()
    .with_routing(service.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, app(state)).await.unwrap();
    });
    let client = reqwest::Client::new();
    let driver = coordinate(36.7200, 15.0910);
    for (endpoint, body) in [
        ("shift", json!({"active":true,"capacity":2})),
        ("location", json!(driver)),
    ] {
        assert!(client
            .post(format!("{base}/v1/{endpoint}"))
            .bearer_auth("demo-driver-1")
            .json(&body)
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
    }
    let pickup = coordinate(36.7160, 15.0910);
    let dropoff = coordinate(36.7160, 15.0930);
    let delivery = json!({"shop_name":"Synthetic","pickup_address":"A","dropoff_address":"B","pickup":pickup,"dropoff":dropoff,"ready_at":1000,"deadline_at":5000,"load_units":1,"max_ride_seconds":1800});
    let saved: Value = client
        .post(format!("{base}/v1/deliveries"))
        .bearer_auth("demo-dispatcher")
        .json(&delivery)
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = saved["id"].as_str().unwrap();
    client
        .post(format!("{base}/v1/deliveries/{id}/assign"))
        .bearer_auth("demo-dispatcher")
        .json(&json!({"driver_id":"driver-1"}))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap();
    let route: Value = client
        .get(format!("{base}/v1/route"))
        .bearer_auth("demo-driver-1")
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(route["travel_estimate"]["mode"], "embedded_osrm");
    assert_eq!(route["travel_estimate"]["approximate"], false);
    let matrix = service
        .matrix(Some(driver), vec![pickup, dropoff])
        .await
        .unwrap();
    let expected =
        matrix.seconds(driver, pickup).unwrap() + matrix.seconds(pickup, dropoff).unwrap();
    assert_eq!(route["travel_seconds"].as_i64(), Some(expected));
    assert_ne!(
        expected,
        arrivau_api::routing::approximate_seconds(driver, pickup)
            + arrivau_api::routing::approximate_seconds(pickup, dropoff)
    );
    let mut disconnected = delivery;
    disconnected["dropoff"] = json!(coordinate(36.7400, 15.1310));
    let saved: Value = client
        .post(format!("{base}/v1/deliveries"))
        .bearer_auth("demo-dispatcher")
        .json(&disconnected)
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = saved["id"].as_str().unwrap();
    let ready: Value = client
        .post(format!("{base}/v1/deliveries/{id}/readiness"))
        .bearer_auth("demo-dispatcher")
        .json(&json!({"ready_in_minutes":0,"expected_revision":0}))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        ready["status"], "pending",
        "least-bad timing never permits unreachable road legs"
    );
    assert!(ready["driver_id"].is_null());
    let rejected = client
        .post(format!("{base}/v1/deliveries/{id}/assign"))
        .bearer_auth("demo-dispatcher")
        .json(&json!({"driver_id":"driver-1"}))
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), reqwest::StatusCode::UNPROCESSABLE_ENTITY);
    server.abort();
}
