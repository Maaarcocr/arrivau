//! Local, synthetic-coordinate benchmark. Never opens a database or network port.
use arrivau_api::{
    model::Coordinate,
    routing::{RoutingService, TravelMode, TravelTimes},
};
use serde_json::json;
use std::{collections::BTreeMap, error::Error, path::Path, time::Instant};

fn memory() -> BTreeMap<String, u64> {
    let mut result = BTreeMap::new();
    for file in ["/proc/self/smaps_rollup", "/proc/self/status"] {
        if let Ok(contents) = std::fs::read_to_string(file) {
            for line in contents.lines() {
                let Some((key, rest)) = line.split_once(':') else {
                    continue;
                };
                if ["Rss", "Pss", "Pss_Anon", "Pss_File", "Anonymous", "VmHWM"].contains(&key) {
                    if let Some(value) = rest
                        .split_whitespace()
                        .next()
                        .and_then(|s| s.parse::<u64>().ok())
                    {
                        result.insert(format!("{}_kib", key.to_lowercase()), value);
                    }
                }
            }
        }
    }
    result
}
fn point(lat: f64, lng: f64) -> Coordinate {
    Coordinate { lat, lng }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn Error>> {
    let arguments: Vec<String> = std::env::args().collect();
    let manifest = arguments.get(1).ok_or(
        "Usage: arrivau-routing-benchmark /absolute/manifest.json [iterations] [hold-seconds] [stop-count]",
    )?;
    let iterations: usize = arguments
        .get(2)
        .map(|s| s.parse())
        .transpose()?
        .unwrap_or(1000);
    let hold: u64 = arguments
        .get(3)
        .map(|s| s.parse())
        .transpose()?
        .unwrap_or(0);
    let stop_count: usize = arguments
        .get(4)
        .map(|s| s.parse())
        .transpose()?
        .unwrap_or(3);
    if !(1..=100_000).contains(&iterations) || hold > 300 || !(3..=34).contains(&stop_count) {
        return Err("iterations must be 1–100000; hold <=300 seconds; stops 3–34".into());
    }
    let before = memory();
    let start = Instant::now();
    let service = RoutingService::embedded(Path::new(manifest))?;
    let startup_ms = start.elapsed().as_secs_f64() * 1000.0;
    let initialized = memory();
    let anchors = [
        point(36.7163, 15.0908),
        point(36.7423, 15.1167),
        point(36.8909, 15.0703),
    ];
    // Upper-size runs repeat the three public town anchors with small offsets;
    // this stresses table/cache dimensions, not a claim to every regional road.
    let stops: Vec<_> = (0..stop_count)
        .map(|i| {
            let base = anchors[i % anchors.len()];
            point(base.lat + (i / anchors.len()) as f64 * 0.00001, base.lng)
        })
        .collect();
    let mut first_matrix = Vec::new();
    let start = Instant::now();
    let mut latencies = Vec::with_capacity(iterations);
    for iteration in 0..iterations {
        let query_start = Instant::now();
        // Small, exact GPS changes require a fresh combined native matrix.
        let driver = point(36.7170 + (iteration % 20) as f64 * 0.00001, 15.0910);
        let matrix = service.matrix(Some(driver), stops.clone()).await?;
        latencies.push(query_start.elapsed().as_secs_f64() * 1000.0);
        if matrix.estimate().mode != TravelMode::EmbeddedOsrm {
            return Err("Benchmark received fallback instead of real native routing".into());
        }
        if iteration == 0 {
            first_matrix = stops
                .iter()
                .map(|from| {
                    stops
                        .iter()
                        .map(|to| matrix.seconds(*from, *to))
                        .collect::<Vec<_>>()
                })
                .collect();
            if first_matrix.iter().flatten().any(Option::is_none) {
                return Err("Benchmark sample has unreachable road pairs".into());
            }
        }
    }
    let total_ms = start.elapsed().as_secs_f64() * 1000.0;
    latencies.sort_by(f64::total_cmp);
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "pid": std::process::id(), "iterations": iterations, "stop_count": stop_count, "combined_matrix_size": stop_count + 1,
            "startup_ms_including_manifest_checksums": startup_ms,
            "queries_total_ms": total_ms, "query_median_ms": latencies[iterations / 2],
            "query_p95_ms": latencies[(iterations * 95 / 100).min(iterations - 1)],
            "query_max_ms": latencies[iterations - 1],
            "memory_before": before, "memory_initialized": initialized, "memory_after_queries": memory(),
            "matrix_seconds": first_matrix,
            "cache_note": "Manifest checksum verification reads all graph files; exact-coordinate full matrix cache includes moving driver; each new GPS gets a fresh native matrix. RSS and page cache overlap."
        }))?
    );
    if hold > 0 {
        tokio::time::sleep(std::time::Duration::from_secs(hold)).await;
    }
    Ok(())
}
