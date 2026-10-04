# Arrivau

A Rust API and native Italian SwiftUI app for a **supervised, single-fleet delivery pilot** around Pachino. One app supports dispatcher and driver accounts. The server owns roles, assignments, shift state and routes.

The code now has an explicit production/pilot mode with individual passwords, expiring/revocable sessions, HTTPS app configuration and persistent SQLite. It remains a small prototype: route times are approximate, notifications require the foreground app, and background location must be checked on real devices. It is not ready for unsupervised dispatch or a broad public launch.

## Start a real-phone pilot

Follow [the pilot runbook](docs/pilot-runbook.md) for:

1. Deploying one API process behind HTTPS with a fresh persistent database
2. Provisioning one dispatcher account and separate driver accounts
3. Configuring a signed iPhone build with your endpoint, team and bundle ID
4. Running the two-phone delivery and interruption checklist

[The TestFlight guide](docs/testflight.md) includes an archive-only command and the explicit upload handoff. [Manual GitHub Actions signing/upload](docs/testflight-ci.md) is also prepared for building without a connected Mac; it requires owner-supplied signing assets and an explicit upload choice. No server, Apple account, credentials or TestFlight build is created automatically. The owner supplies hosting and Apple signing/access.

Deployment templates: `deploy/Dockerfile`, `deploy/arrivau.service`, `deploy/pilot.env.example`, `deploy/Caddyfile.example`. Read [API configuration](api/README.md) before using them. Keep account files, password hashes, sessions and databases out of Git/logs.

## What is included

- `api/`: Axum HTTP API, Argon2id authentication, opaque sessions, server role checks, SQLite state and constrained insertion planner
- `ios/`: iOS 17+ SwiftUI app, HTTPS login, Keychain sessions, map-selected delivery addresses, on-shift Core Location, Italian UI, unit/UI tests and release icon/privacy resources
- `docs/api-contract.md`: JSON contract for the native app and a future dispatcher client
- `scripts/`: local demo, verification, screenshot export and archive preparation
- `.github/workflows/ci.yml`: Rust/HTTP checks, container build, macOS native tests and unsigned Release device build using Xcode 26.6

## Isolated local demo

For development only, use the [official Rust toolchain](https://www.rust-lang.org/tools/install), pinned in `rust-toolchain.toml`, and a C compiler for bundled SQLite:

```sh
./scripts/api-dev.sh
```

The demo binds to `127.0.0.1:8080` and writes `arrivau-demo.sqlite3` locally. `ARRIVAU_DB_PATH` chooses another demo database. Public binding is rejected in demo mode; the three demo bearer strings are intentionally public and never authenticate in production. Database mode/fleet checks keep demo and pilot data separate.

On a Mac with Xcode 26+ and XcodeGen:

```sh
brew install xcodegen
cd ios
xcodegen generate
open Arrivau.xcodeproj
```

For the local simulator chooser, add `--demo` to the Debug scheme's launch arguments and run while the demo API is running. Normal Debug and all Release launches show the pilot login instead. A physical phone must use the HTTPS pilot flow, not the loopback demo.

In demo mode, sign in as Corriere 1, start the shift and simulate a Pachino location. Switch to the dispatcher, create a map-selected delivery, choose a driver and assign it. Switch back to Corriere 1, resume sharing and complete pickup then drop-off in route order. Finish work before ending the shift. The server excludes off-shift drivers and positions older than five minutes from suggestions.

## Verify the code

Backend format, lint, unit/planner, real HTTP integration tests and configuration/script tests:

```sh
./scripts/check.sh
```

Black-box demo smoke (fresh disposable database; in separate terminals):

```sh
ARRIVAU_DB_PATH=/tmp/arrivau-smoke.sqlite3 ./scripts/api-dev.sh
python3 scripts/e2e.py
```

On macOS, run the native app against a disposable real API and simulator:

```sh
./scripts/test-ios.sh
```

The script generates the Xcode project, builds/starts the API, selects an installed iPhone simulator and runs unit/UI tests. `SIMULATOR_UDID` selects a particular device. Explicit test flags provide deterministic GPS/place-search fixtures; ordinary app use requires genuine permission and selected Maps results. Screenshots are written under `ios/build/screenshots/` and attached to CI runs.

The CI also builds the Release configuration for a generic physical iOS device without signing. This catches code hidden by Debug-only paths; it does not prove signing, physical GPS, hosted TLS or TestFlight processing. See [verification notes](docs/verification.md) and the exact commit's CI results.

## Pilot limits and safety

- Individual operator-provisioned accounts, one fleet and one server process. No self-service signup/reset, multitenancy, audit-log service, billing or customer marketplace
- SQLite survives process restart on a persistent local disk; the operator owns backups, restore tests, retention, security and monitoring. Do not scale replicas or use network storage
- Dispatcher assigns manually. Only the assigned driver can confirm pickup/drop-off, in committed stop order; driver isolation is enforced server-side
- Route suggestions use Haversine distance × 1.3 at 25 km/h. They are not road routing, traffic-aware or globally optimal; safety, food handling and driving decisions remain with people
- Readiness, pickup-before-drop-off, capacity, deadline and maximum ride time constrain suggestions. Time/location changes can invalidate plans; keep human supervision and review warnings
- The foreground app polls about every five seconds. There is no APNs or guaranteed suspended-app notification delivery, and no general offline queue
- Delivery creation retains its idempotency key and request securely for uncertain-response recovery. Check current state before manually replacing a job. Connectivity errors are visible rather than silently treated as success
- GPS starts only after explicit sharing consent on an active shift. Separate background opt-in supports locking/Maps, subject to iOS behavior. Ending the shift or signing out stops local reporting. The most recent point remains on the server; no location history feed is built
- Apple Maps search sends the query to Apple; opening directions shares the selected stop coordinates. The app does not include paid routing/geocoding providers
- Physical-device and background/network/battery checks must pass before using real customer work. Start with synthetic deliveries and inform participants about stored location/address data

The HTTP contract is independent of SwiftUI, so a future dispatcher web client can share it after its own security/UI work.
