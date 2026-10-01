# Rust API

A local-development starter for a two-driver Pachino fleet. The root README and
`../docs/api-contract.md` describe setup and the shared iOS wire contract.

## Run and verify

```sh
ARRIVAU_DEMO=1 cargo run --manifest-path api/Cargo.toml
cargo test --manifest-path api/Cargo.toml --locked
cargo clippy --manifest-path api/Cargo.toml --all-targets --locked -- -D warnings
cargo fmt --manifest-path api/Cargo.toml -- --check
```

Run those commands from the repository root. `ARRIVAU_DB_PATH` defaults to
`arrivau.sqlite3`; `ARRIVAU_ADDR` defaults to `127.0.0.1:8080`. The executable
refuses startup without `ARRIVAU_DEMO=1` or with a non-loopback bind address.

## Design

- Axum/Tokio HTTP service; role checks on every supported protected route
- SQLite WAL persistence for drivers, jobs, completion timestamps, and ordered
  route stops. Demo driver seeding uses `INSERT OR IGNORE`, preserving shifts and
  locations across restarts. Assignment/reassignment/status updates use SQLite
  transactions. JSON domain bodies have indexed ownership/status columns
- A single guarded SQLite connection intentionally serializes small-fleet
  writes and route planning. Before larger deployment, use a blocking worker or
  database pool, migrations, pagination, and realistic performance/load tests
- Insertion checks every pickup/dropoff pair around existing stops, preserving
  existing relative order. Simulation considers initial onboard load, pickup
  readiness, capacity at each pickup, delivery deadlines, and elapsed ride time
  from the pickup service start or actual persisted pickup timestamp
- Travel uses Haversine × 1.3 at constant 25 km/h; each stop adds 60 seconds of
  handling. No traffic, one-way streets, road accessibility, breaks, or global
  optimization are modeled. Readiness waits and handling count toward freshness
- Target routes must be fully feasible and have no more than 32 outstanding
  stops. Locations are fresh for 300 seconds; missing/stale locations block
  assignment and omit the driver from suggestions. Existing route stops remain
  visible when time or GPS freshness makes their estimates infeasible
- Reassignment also checks the source route: removing stops may make another
  pickup earlier and increase food age during a later readiness wait. A new
  violation rejects the move. Existing warning identities may remain so that
  dispatch can recover work from an already-late or stale-location driver
- Drivers can complete only the currently committed next stop. Readiness is
  enforced for pickup. Late real-world completions remain recordable. This
  starter does not geofence completion or prove the driver physically arrived

## Tests

`tests/http_e2e.rs` launches an ephemeral TCP listener against a real temporary
SQLite file; no mocked HTTP server or in-memory database is used. A clock is
injected only to make readiness, expiry, and location-age tests deterministic.
Coverage includes auth/roles, JSON errors, ownership, transitions, full delivery
flow, restart persistence, atomic rejection/reassignment, concurrent dispatch,
route ordering, old-route freshness regressions, stale-driver recovery, and the
odd-count 32-stop boundary. Planner unit tests cover geometry and constraints.

## Before production

Replace the demo gate/tokens with verified user authentication and tenant-scoped
authorization; deploy HTTPS, secure device credentials, migrations/backups,
observability, rate limits, idempotency keys, retention controls, and a real road
travel-time provider. Revalidate local transport and food-handling requirements.
Do not expose this demo to a network or use it for live customer operations.
