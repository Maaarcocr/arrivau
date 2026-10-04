# Regional embedded OSRM measurement · 2026-10-04

**The real embedded engine works. The final combined-matrix implementation used
about 21 MiB process RSS in this small-region benchmark. This does not establish
that the user's existing host has enough headroom.**

Machine: shared Linux x86_64 cloud host, AMD EPYC 9V74, Debian GCC 14.2.0,
CMake 3.31.6, Rust 1.99.0. Unmodified crates.io `osrm_interface=0.8.2`, native
feature only, linked against the pinned OSRM 6.0.0 static library. No routing
server, HTTP routing call, Docker or mock engine was used.

## Map and offline preparation

- [Geofabrik dated isole source](https://download.geofabrik.de/europe/italy/isole-261003.osm.pbf)
- OSM timestamp: **2026-10-03T20:20:50Z**
- Source SHA-256: `dd8d74618baa05534b878f56913420ef0356ba043bb0e1cc3cdfdb3b7eaa44ad`
- Extract bounds: `[14.85,36.60,15.25,37.10]`; service bounds: `[14.95,36.65,15.18,36.95]`
- Pachino, Marzamemi and Noto, with a road-network buffer; `complete_ways` clipping
- Cropped PBF: 8,966,735 bytes; prepared CH files: **31,127,516 bytes (29.69 MiB)** across 23 files
- Car profile from the same pinned OSRM release, two preprocessing threads

| Offline stage | Wall time | Sampled peak RSS | Sampled peak PSS |
|---|---:|---:|---:|
| Extract | 1.96 s | 117.67 MiB | 116.55 MiB |
| CH contraction | 31.92 s | 65.27 MiB | 64.16 MiB |

These are preprocessing figures, not runtime requirements. Prepare off-host and
copy a complete verified immutable dataset if the production machine is weak.
C++ compilation also happens separately and is not included in this memory table.

## Final Arrivau matrix-service runtime

The repository's release `arrivau-routing-benchmark` exercises the actual
`RoutingService`: one owning native worker, exact-coordinate cache, bounded
snapping and a fresh **combined driver-plus-stops** matrix whenever GPS changes.
Twenty driver positions cycle through a sixteen-entry matrix cache, so these are
not merely repeated hits on a single matrix.

| Workload | Requests | Median query | p95 query | Sampled peak RSS | Sampled peak PSS |
|---|---:|---:|---:|---:|---:|
| Three stops + driver, 4×4 table | 10,000 | 0.55 ms | 0.67 ms | 19.78 MiB | 18.69 MiB |
| 34 stops + driver, 35×35 table | 1,000 | 4.15 ms | 4.69 ms | 20.58 MiB | 19.50 MiB |

Initialization including every graph-file checksum took 34.34 ms and 24.47 ms,
respectively. The size-stress run uses small coordinate offsets around the three
public town anchors. It proves upper table/cache dimensions, not performance on
every possible regional road. This is a matrix-service process, not a full
production API/SQLite/Argon2 concurrency benchmark.

Source/destination directionality is real: in the three-stop sample,
Pachino→Marzamemi is 473 s and Marzamemi→Pachino is 543 s. The API rounds native
fractional seconds upward. Synthetic native tests additionally establish
unreachable/null preservation, one-way asymmetry, 250 m snap rejection,
coverage fallback, mixed fallback provenance, and real HTTP automatic-dispatch
rejection of disconnected work. The actual release API also passed the regional
black-box restaurant→readiness→assignment→pickup→delivery smoke flow.

## Memory interpretation and limits

Linux `smaps_rollup` was sampled every 20 ms. The benchmark also reports its own
before/init/after RSS and PSS and `VmHWM`. Short-lived peaks can fall between
external samples. MiB means 1,048,576 bytes; KiB means 1,024 bytes.

Checksum validation intentionally reads all graph files and warms the filesystem
cache before querying. Most routing memory here is file-backed, with roughly
0.9–1.6 MiB sampled anonymous memory. File-backed process RSS and the kernel's
page cache overlap: **do not add them as separate memory demand**. Shared-host
load, compiler, architecture, dataset size, route geography and request concurrency
can change both latency and memory.

Measure the actual target's available memory and its normal API peaks before
opting in. Keep the default approximate mode until that check and a compatible
client rollout are complete. No live server configuration was changed by this
measurement.

## Reproduce

Follow [embedded routing setup](embedded-routing.md) to build the pinned native
SDK and prepare a dated dataset. Then:

```sh
cargo build --release --locked --manifest-path api/Cargo.toml \
  --features embedded-osrm --bin arrivau-routing-benchmark
api/target/release/arrivau-routing-benchmark /absolute/maps/manifest.json 10000 0 3
api/target/release/arrivau-routing-benchmark /absolute/maps/manifest.json 1000 0 34
./scripts/test-embedded-routing.sh
```

The benchmark opens no database or listening port. It fails if a query returns an
approximation rather than native road costs. Exact metrics, cache caveats, binary
checksum and map provenance are in [the machine-readable report](benchmarks/embedded-osrm-2026-10-04.json).
OSM data is © OpenStreetMap contributors, [ODbL 1.0](https://www.openstreetmap.org/copyright).
