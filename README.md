# Arrivau

A Rust API and native Italian SwiftUI app for a **supervised, team-isolated delivery pilot** around Pachino. One app supports dispatcher, driver and dual-role accounts. Each account belongs to a private team (Squadra). The server owns roles, assignments, shift state and routes.

The code now has an explicit production/pilot mode with individual passwords, expiring/revocable sessions, HTTPS app configuration and persistent SQLite. It remains a small prototype: road routing is an opt-in embedded feature with explicit approximate fallback, notifications require the foreground app, and background location must be checked on real devices. It is not ready for unsupervised dispatch or a broad public launch.

## Start a real-phone pilot

Follow [the pilot runbook](docs/pilot-runbook.md) for:

1. Deploying one API process behind HTTPS with a fresh persistent database
2. Provisioning team-scoped dispatcher, driver or dual-role accounts
3. Configuring a signed iPhone build with your endpoint, team and bundle ID
4. Running the two-phone delivery and interruption checklist

Use the [TestFlight publishing steps](#publish-to-testflight) for the configured GitHub-hosted build workflow. Complete the backend and physical-device checks before using real customer work.

Deployment templates: `deploy/Dockerfile`, `deploy/arrivau.service`, `deploy/pilot.env.example`, `deploy/Caddyfile.example`. Read [API configuration](api/README.md) before using them. Keep account files, password hashes, sessions and databases out of Git/logs.

For an existing pilot or an isolated Apple review account, follow [Teams and App Review](docs/teams-and-review.md). Deploy the backward-compatible backend migration first, retain the original fleet ID and data, then use the updated app for dual-role view switching.

## Publish to TestFlight

Use [Actions → Manual TestFlight](https://github.com/Maaarcocr/arrivau/actions/workflows/testflight.yml) with the existing repository signing secrets and Actions variables:

1. Check that `main` contains the intended changes and its ordinary verification CI is green
2. Choose **Run workflow**, branch **main**, and a build number from **1–9999** that has not already been uploaded for the current app version (`0.2.0`)
3. Choose **archive** to verify signing and packaging without uploading, or **upload** to send the signed build to App Store Connect. If enabled, approve the configured `testflight` environment gate after reviewing the source SHA and action
4. After upload, check processing in App Store Connect, resolve any export-compliance/privacy questions accurately, and add the processed build to the intended TestFlight group. External testing may require Beta App Review
5. Install on both pilot phones and complete the [delivery](docs/pilot-runbook.md#5-run-one-supervised-delivery) and [interruption/device checks](docs/pilot-runbook.md#6-required-interruptiondevice-checks)

The workflow requires `TESTFLIGHT_SIGNING_ENABLED=true` and runs only by manual dispatch from `main`. It uses the configured `ARRIVAU_TEAM_ID`, `ARRIVAU_BUNDLE_ID` and HTTPS `ARRIVAU_API_URL`; no credentials belong in Git, chat or logs. Signing credentials and temporary binaries are cleaned up, and an archive run retains no IPA artifact. Keep signing assets current through the repository's protected settings.

For an optional local Mac archive, run `./scripts/archive-ios.sh` with the same team, bundle and API settings plus `ARRIVAU_BUILD_NUMBER`. This command archives only; it does not upload.

A successful upload confirms transfer to Apple, not completed processing, tester access or public release. Check the [workflow](.github/workflows/testflight.yml), [Apple upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) and [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) when troubleshooting. Hosted HTTPS, backups and real-device behavior are covered by the [pilot runbook](docs/pilot-runbook.md).

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

The demo binds to `127.0.0.1:8080` and writes `arrivau-demo.sqlite3` locally. `ARRIVAU_DB_PATH` chooses another demo database. Public binding is rejected in demo mode; the demo bearer strings are intentionally public and never authenticate in production. Database mode/fleet checks keep demo and pilot data separate.

On a Mac with Xcode 26+ and XcodeGen:

```sh
brew install xcodegen
cd ios
xcodegen generate
open Arrivau.xcodeproj
```

For the local simulator chooser, add `--demo` to the Debug scheme's launch arguments and run while the demo API is running. Normal Debug and all Release launches show the pilot login instead. A physical phone must use the HTTPS pilot flow, not the loopback demo.

In demo mode, sign in as Corriere 1, start the shift and simulate a Pachino location. Switch to the dispatcher, save a restaurant from a Maps-selected address, create an order using that restaurant and a destination, then open it and mark it ready. The server assigns a driver automatically. Switch back to Corriere 1, resume sharing and complete pickup then drop-off in route order. Finish work before ending the shift. The server excludes off-shift drivers; stale or unavailable positions are explicitly flagged.

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

- Individual operator-provisioned accounts, one team per account and one server process. Server-enforced team isolation; no self-service signup/reset, public team administration, audit-log service, billing or customer marketplace
- SQLite survives process restart on a persistent local disk; the operator owns backups, restore tests, retention, security and monitoring. Do not scale replicas or use network storage
- Dispatchers save restaurants, create unassigned orders, and later mark them ready now or in a number of minutes. The server assigns automatically when readiness arrives, including least-bad timing fallbacks with warnings. Only the assigned driver confirms pickup/drop-off
- The default travel model is Haversine × 1.3 at 25 km/h. [Optional embedded OSRM](docs/embedded-routing.md) provides offline road-time matrices with a separately prepared regional map. Approximation/fallback is labelled, traffic is not live, and the insertion planner is not globally optimal; people retain safety, food handling and driving decisions
- Pickup aims for ten minutes after readiness, with a five-minute cumulative extra-onboard-delay policy. Impossible timing is flagged rather than leaving ready work unassigned; physical capacity, precedence and the 32-stop bound remain mandatory. See [readiness and dispatch](docs/readiness-and-dispatch.md)
- The foreground app polls about every five seconds. There is no APNs or guaranteed suspended-app notification delivery, and no general offline queue
- Delivery creation retains its idempotency key and request securely for uncertain-response recovery. Check current state before manually replacing a job. Connectivity errors are visible rather than silently treated as success
- GPS starts only after explicit sharing consent on an active shift. Separate background opt-in supports locking/Maps, subject to iOS behavior. Ending the shift or signing out stops local reporting. The most recent point remains on the server; no location history feed is built
- Apple Maps search sends the query to Apple; opening directions shares the selected stop coordinates. The app does not include paid routing/geocoding providers
- Physical-device and background/network/battery checks must pass before using real customer work. Start with synthetic deliveries and inform participants about stored location/address data

The HTTP contract is independent of SwiftUI, so a future dispatcher web client can share it after its own security/UI work.

## License

Arrivau's original code and documentation are proprietary, with all rights reserved.
See [LICENSE](LICENSE). Public visibility does not grant an open-source license;
GitHub's viewing and forking rights and third-party licenses still apply.
