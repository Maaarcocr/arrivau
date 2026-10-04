# Embedded road routing (optional)

Arrivau can link **OSRM 6.0.0** into its Rust API through **osrm_interface
0.8.2**. This is a C++ native dependency, not a pure-Rust routing engine. There
is no routing HTTP server, Docker requirement, commercial routing API, or runtime
map download. OpenStreetMap-derived driving durations respect the prepared road
network and directionality. They do not include live traffic or guarantee that a
road is currently open or suitable for a particular vehicle.

The normal build and deployment remain available without OSRM. See the [measured regional benchmark](embedded-routing-benchmark.md) for reproducible local results and their limits. Enable the native
feature and point it at a separately prepared, versioned dataset only after
measuring the actual host. Embedding does **not** remove the graph's memory cost.
No migration, service restart, live configuration change, server deployment or
TestFlight upload is performed by these scripts.

## Pinned compatibility

- Rust: repository `rust-toolchain.toml`
- Binding: crates.io `osrm_interface = "=0.8.2"`, native feature only;
  checksum in `api/Cargo.lock`
- OSRM: `v6.0.0`, commit `054b0a6395f689a47a908b26b12e32ed7704c533`
- Official source archive SHA-256:
  `369192672c0041600740c623ce961ef856e618878b7d28ae5e80c9f6c2643031`
- CH preprocessing with the same version's `profiles/car.lua`
- The dataset manifest records versions, source timestamp, service and extract
  bounds, and every prepared graph file's SHA-256. Startup validates all recorded
  files before initializing the native engine. Mixed versions/checksum failures
  fail startup rather than silently downgrading a broken deployment

The binding owns a C++ pointer; do not clone its `OsrmEngine`. Arrivau creates one
engine on one worker thread and never copies it. Only the request sender is cloned.

## Build the native dependency on a preparation/build machine

The tested proof used Linux with GCC 14; the CI uses Ubuntu 24.04. Install normal
compiler/library packages from your OS's official package repositories. For
Ubuntu/Debian (an operator-run command):

```sh
sudo apt-get update
sudo apt-get install -y build-essential cmake libboost-all-dev libtbb-dev \
  liblua5.4-dev libbz2-dev libexpat1-dev libxml2-dev libzip-dev zlib1g-dev \
  osmium-tool python3 curl
./scripts/build-osrm.sh /absolute/build/osrm-6.0.0
export OSRM_BACKEND_PATH=/absolute/build/osrm-6.0.0
cargo build --release --locked --manifest-path api/Cargo.toml --features embedded-osrm
```

The build helper verifies the official archive, uses Release with LTO disabled,
installs only the library/headers and offline `osrm-extract`/`osrm-contract` tools
into the requested prefix, and defaults to two build jobs. `OSRM_BUILD_JOBS=1`
reduces build parallelism. GCC 14 emits an array-bounds warning in the bundled
sol2 headers; that warning remains visible but is not treated as fatal. No OSRM
source patch is applied. The helper neither runs sudo nor changes a service.
Reusing the same completed prefix is safe; an unrelated nonempty prefix is refused.

`libosrm.a` is statically linked, but Boost, TBB, the C++ runtime, zlib, bzip2 and
expat are dynamic system dependencies. Check `ldd` on the final binary. Build for
the target architecture and compatible OS ABI; do not copy this cloud machine's
binary blindly onto the existing host. The build/preparation toolchain does not
need to stay on the runtime host.

## Prepare the regional map separately

Download a dated Sicily-containing OSM PBF from the official
[Geofabrik Italy extracts](https://download.geofabrik.de/europe/italy.html).
The `isole` extract includes Sicily. Keep the source timestamp, source URL and
checksum with the deployment record. Public map download happens on the
preparation machine, not when the API starts or handles a request.

```sh
export OSRM_BACKEND_PATH=/absolute/build/osrm-6.0.0
./scripts/prepare-osrm-region.sh /absolute/maps/isole-YYMMDD.osm.pbf \
  /absolute/maps/pachino-YYYY-MM-DD
```

The supplied preparation scope is:

- Supported service bounds (west, south, east, north):
  `[14.95, 36.65, 15.18, 36.95]`, covering Pachino, Marzamemi and Noto
- Buffered extract bounds: `[14.85, 36.60, 15.25, 37.10]`
- `osmium extract --strategy complete_ways` retains complete intersecting ways;
  some retained nodes can extend beyond the extraction box
- `osrm-extract` plus `osrm-contract`, default two preparation threads;
  `OSRM_PREPARE_JOBS=1` reduces parallelism

The buffer reduces artificial cut-edge routes. It cannot guarantee that the
fastest legal route between two interior points never leaves the extract.
Outside the service box, or more than 250 metres from a usable road, the response
explicitly uses the local approximation. Extend and re-benchmark the graph before
expanding the service area. Never merely widen the manifest to cover missing data.
The output directory must be new; failed preparation is not a deployable dataset.

Keep the complete graph set and manifest together. Make a new versioned directory
for each update; never replace files underneath a running memory-mapped engine.
After copying verified artifacts, restart under the usual operator process and
retain the prior dataset/binary for rollback. Prefer a rollout between shifts;
review outstanding routes because road times can change existing ETA feasibility.
Persisted onboard deadlines are intentionally not reset by changing routing mode. Do not delete an active dataset.

## Enable explicitly on the target host

Measure available RAM, swap, CPU, disk and the API's normal peak before choosing to
enable road routing. Deploy a client that renders `travel_estimate` and honours
`estimates_available` first: older clients can ignore additive fields and would
not show fallback or unavailable-ETA notices. Keep approximate mode while those
older clients are in use. Add these settings to the operator-managed configuration only
when ready:

```sh
ARRIVAU_ROUTING=embedded-osrm
ARRIVAU_OSRM_DATASET=/absolute/maps/pachino-YYYY-MM-DD/manifest.json
```

Run the `--features embedded-osrm` build. A normal build rejects native mode with
an actionable error. Unset both values (or use `ARRIVAU_ROUTING=approximate` without
a dataset path) for the existing air-line estimate. Existing Docker/systemd
examples remain default approximate builds. No extra listening port is needed.

A configured graph loads once. Native calls run on a dedicated worker, with an
8-request bounded queue, at most one native operation at a time, and a two-second
caller deadline. A timed-out native call is not unsafely interrupted; later queued
requests whose callers have gone away are skipped. Overload, missing coverage or
query failure yields a labelled approximation, never an external routing request.

One combined driver-and-stops matrix is reused across candidate permutations.
A 16-entry LRU caches complete native matrices, keyed by all exact coordinates
including the driver, with no rounding. A changed GPS point therefore gets a new
matrix. A bounded 256-point cache avoids repeating successful nearest-road checks.
A combined table is deliberate: binding 0.8.2 discards table hints, and OSRM's
component-snapping choices depend on all input points. Separately cached stop
matrices and a new driver row could otherwise choose inconsistent components.
At most 35 unique points are accepted (32 committed stops, a new pair and driver). Matrices and queues are bounded;
the graph itself still requires memory. For mixed coverage, one combined table covers all supported points and unknown cells alone use the labelled approximation. Native null/disconnected entries in that matrix remain unreachable and cannot produce a feasible assignment. On overload/failure, the exact ordered full-query native cache entry is reused if available, including any unreachable nulls. Otherwise the whole-query approximation is explicitly labelled. No table is reused for a changed GPS point, point set or order. No historical raw-coordinate null cache overrides later native evidence, because OSRM component snapping can change with the point set.

## API and UI contract

Routes expose `travel_estimate` with `mode` (`approximate`, `embedded_osrm`, or
`approximate_fallback`), `approximate`, `notice`, `map_date`, and `attribution`.
Italian route notices distinguish air-line estimates and temporary/out-of-area
fallback from OSRM road estimates. Fallback is explicit even when a route can be
planned. OSRM durations are rounded up to whole seconds. A directed matrix is not
symmetrized. Neither missing entries nor unreachable legs become zero-cost travel.

## Test the actual native path

```sh
export OSRM_BACKEND_PATH=/absolute/build/osrm-6.0.0
./scripts/test-embedded-routing.sh
```

This prepares the checked-in fictional OSM fixture and invokes the real native
engine. It checks one-way asymmetry, disconnected/null legs, bounded snapping,
out-of-coverage fallback and a fresh matrix after a driver movement. It cannot pass using the
binding's mock or remote engines. `.github/workflows/embedded-routing.yml` builds
the pinned C++ SDK and runs this test in addition to native-feature lint and API
unit/HTTP tests. To avoid duplicate runner spend, this workflow is limited to relevant backend/routing changes on ready-for-review PRs (or explicit manual dispatch), without retaining generated SDK/binary caches until their complete bundled notice inventory is verified. Drafts and a redundant post-merge push do not run it. The real native check must pass before merging a native change. Normal CI still verifies the default non-native build.

## Memory and map licensing

Run the built-in local benchmark on the target, separately from production:

```sh
cargo run --release --locked --manifest-path api/Cargo.toml --features embedded-osrm \
  --bin arrivau-routing-benchmark -- /absolute/maps/pachino-YYYY-MM-DD/manifest.json 1000
```

It opens no database or port. It measures native initialization (including dataset
checksum verification), 1,000 three-stop queries with changing driver coordinates, current
Linux RSS/PSS/anonymous/file-backed memory and peak RSS. It aborts if it receives
an approximation rather than native results. An optional final argument holds the
process alive for 0–300 seconds for external measurement. A fourth argument chooses
3–34 stops; use `1000 0 34` for the maximum 35×35 matrix-size stress. Checksumming reads all
graph files and warms the filesystem cache before queries; do not describe this as
a cold-cache query benchmark.

Measure preprocessing separately from idle runtime and repeated matrix queries.
Report peak RSS, current RSS/PSS, anonymous versus file-backed pages, graph disk
size and cache state. File-backed mmap pages can contribute both to process RSS
and the system's reclaimable page cache; do not add them together as independent
memory demand. `free` on a busy shared machine is not a reliable per-process
measurement, and a warm small-region result is not a guarantee for another host.

OpenStreetMap data is © OpenStreetMap contributors, available under
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
Keep `ATTRIBUTION.txt` with prepared data and show the returned attribution in the
client. See [OpenStreetMap attribution](https://www.openstreetmap.org/copyright)
for database use and redistribution obligations. Synthetic CI roads are fictional
and contain no OpenStreetMap-derived geometry.

## Third-party notices and distribution boundary

Arrivau's original code remains governed by the root proprietary LICENSE. OSRM,
its Rust bridge and map data retain their separate licences; see
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). This change distributes source
and measurement documentation, not native SDK/binary or map bundles. Native CI
rebuilds its SDK in the ephemeral runner instead of caching or uploading it.
Before distributing a native binary, SDK/container or derived map bundle, prepare
and verify the complete applicable third-party licence/notice inventory for that
artifact. The currently listed components are not an exhaustive bill of materials.
