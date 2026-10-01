# Arrivau

A small, local-first prototype for a delivery fleet around Pachino: a Rust API and one native SwiftUI iOS app with dispatcher and driver roles.

**This is a working starter, not a production dispatch service.** Authentication uses public demo identities, routes use an approximate distance model, and background location support still needs real-device verification. Do not put real customer data in it or expose the server to the internet.

## What's in this repository

- `api/`: Rust / Axum HTTP API, SQLite state, constrained insertion planner, role checks and real HTTP integration tests
- `ios/`: SwiftUI app, Core Location on-shift/background lifecycle, Maps handoff, unit tests and XCUITest workflow; generate the Xcode project with XcodeGen
- `docs/api-contract.md`: shared JSON contract for iOS and a future dispatcher web client
- `scripts/`: development and verification commands
- `.github/workflows/ci.yml`: Linux backend checks and macOS simulator test job

## Start the API

Requires the [official Rust toolchain](https://www.rust-lang.org/tools/install) and a C compiler for bundled SQLite. The repository pins its tested Rust version in `rust-toolchain.toml`.

```sh
./scripts/api-dev.sh
```

This starts `127.0.0.1:8080` and writes `arrivau.sqlite3` in the repository root. Stop with Ctrl-C; jobs, shifts, locations and assigned stop order survive a restart. `ARRIVAU_DB_PATH` chooses a separate database. `ARRIVAU_ADDR` selects a loopback address/port. The executable refuses to run without `ARRIVAU_DEMO=1` and refuses public binding.

Health check:

```sh
curl http://127.0.0.1:8080/health
curl -H 'Authorization: Bearer demo-dispatcher' http://127.0.0.1:8080/v1/drivers
```

## Run the native app

Requires a Mac with Xcode, an iOS 17+ simulator, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd ios
xcodegen generate
open Arrivau.xcodeproj
```

Run the `Arrivau` scheme on an iPhone simulator while the API is running. The default API address is the host Mac's loopback interface, reachable from the simulator. The demo is deliberately limited to loopback, so a physical iPhone is not a supported target until real authentication and HTTPS are introduced.

See `ios/README.md` for app details and test launch options.

## Try a delivery

1. Open Driver 1, start a shift and opt into on-shift location sharing (simulate a location near Pachino in Xcode)
2. Switch to Dispatcher and create a delivery; fixture addresses/coordinates are examples and are not geocoded
3. Inspect suggested drivers, choose Driver 1 and assign the job
4. Switch to Driver 1, refresh, and follow the ordered route
5. At the ready time, mark the next pickup, then mark the next drop-off
6. End the shift after all active jobs finish; the app stops location updates when off shift or signed out

On a fresh database the drivers are off shift. The backend will not suggest an off-shift driver or one without a location reported in the last five minutes. Dispatchers cannot update driver statuses on their behalf. Driver 2 cannot read or update Driver 1's jobs.

## Verify

Backend format, lint, unit/planner and real HTTP tests:

```sh
./scripts/check.sh
```

Black-box smoke against a disposable API database:

```sh
ARRIVAU_DB_PATH=/tmp/arrivau-smoke.sqlite3 ./scripts/api-dev.sh
# In another terminal:
python3 scripts/e2e.py
```

Use a fresh database for the smoke test, because it assumes Driver 1 has no earlier active work. It writes and completes one clearly labeled fixture delivery. Unit/HTTP integration tests create isolated temporary databases and ephemeral TCP ports.

On macOS, the combined native app → HTTP API workflow is:

```sh
./scripts/test-ios.sh
```

This generates the project, builds the API, starts a disposable database/server, chooses an available iPhone simulator, and runs the app's unit and UI tests. Pass `SIMULATOR_UDID` to select a particular installed simulator. The UI test launches with deterministic fixture location and drives the real API; production UI does not silently send this fixture coordinate.

The macOS job also captures four populated main screens and publishes an `arrivau-ios-screenshots` artifact. On GitHub, open Actions → Verify API and iOS → the run → Artifacts. The same command writes PNGs under `ios/build/screenshots/` locally. Captures use fixture deliveries and simulated Pachino location, while state changes still use the real API.

See [verification notes](docs/verification.md) for exactly which checks were run when this starter was created. A configured CI job is not evidence that it has passed.

## Scope and safety

- Role authorization and driver isolation are implemented, but demo bearer strings are public and offer no real identity verification. Production needs authenticated accounts, revocation and HTTPS
- SQLite is appropriate for this single-process small-fleet sketch. There is no multi-tenant data partitioning, concurrent multi-instance scheduler, audit log or backup service
- Assignment is a human-confirmed action; suggestions do not automatically dispatch a driver
- Route suggestions minimize incremental approximate driving time within an insertion heuristic. They are not guaranteed globally optimal and do not know road restrictions, traffic, closures or vehicle type
- Readiness, pickup-before-drop-off, load capacity, deadline and maximum in-vehicle time constrain proposed routes. Existing late routes remain visible with warnings
- Time and location changes can invalidate an earlier plan; drivers and dispatchers must review warnings. Real-world safety, food handling and driving decisions remain with people
- The app polls while foregrounded. Push notifications, reliable background delivery notifications and offline queues need separate implementation. Background Core Location has an explicit opt-in/code path, but must be verified on a signed physical device
- Addresses are manually entered with coordinates. There is no geocoding vendor integration, customer marketplace, payment flow or production deployment
- Location sharing is driver opt-in while on shift; background sharing can be enabled explicitly for phone locking/Maps use. Ending a shift/signing out stops app location reporting. The most recent point stays in the local database; there is no location history feed
- Maps opens only when the user taps directions and then shares that stop's coordinates with Apple Maps

## Next practical iteration

1. Add a real identity provider and per-fleet roles, HTTPS, audit events and retention/deletion policy
2. Replace the `travel_seconds` estimate with a road-time matrix provider, including attribution and API-key management on the server
3. Test on a real iPhone with a signed build; verify background location while locked/using Maps, then add APNs, reconnection and idempotent/offline status actions
4. Trial with a small fleet and compare suggested routes against actual pickup readiness, service time and travel time

The JSON API is independent of SwiftUI, so a web dispatcher can be added without replacing the driver app.
