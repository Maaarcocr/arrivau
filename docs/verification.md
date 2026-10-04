# Current pilot verification

The phone-pilot changes add authentication/session/role negative tests, endpoint/session/race/retry tests, release-configuration checks, a container build and an unsigned generic-iOS Release build. Consult the draft PR and the exact head commit's CI before treating these as passed; the historical results below predate the pilot changes.

Never established by CI: owner-hosted HTTPS, persistent-volume deployment/restore, signed physical-iPhone behavior, background GPS while locked/terminated, Apple signing, TestFlight processing or beta review. The manual checklist is in [pilot-runbook.md](pilot-runbook.md).

## Local readiness and restaurant verification (2026-10-04)

The readiness/automatic-dispatch/saved-restaurant changes passed local Rust formatting,
Clippy with warnings denied, all 58 Rust tests, and 44 Python/script tests. The
real-process HTTP smoke also passed both the legacy manual flow and the new saved
restaurant → unknown readiness → estimate → ready-now → automatic assignment →
pickup/dropoff flow. The API implementation reviewed was local commit `9d12486`.

The tests include future-ETA dispatch by the server timer after restart without
mobile polling, team/role/revocation rejection, immutable restaurant pickup
snapshots, idempotent retries, all-late assignment, a full car delivering first,
no-GPS assignment with unavailable ETAs, fixed-cohort queue fairness under new
arrivals, and pickup-anchored cumulative detour limits. Read-only independent API
and iOS reviews found no remaining confirmed blocker in their reviewed scope.

All 19 Swift source/test files passed structural parsing. This is **not** an Apple
SDK type-check, simulator run, screenshot review or unsigned Release build. Those
stages had not run at this local checkpoint. The exact published head must pass
native CI before merge. Pay particular attention to restaurant-sheet
closure, unavailable-ETA presentation, and notices on otherwise feasible routes.

No hosting deployment, database migration on a live system, TestFlight upload or
physical-device test was performed.

## Team-scoped invitation draft

The invitation changes add real HTTP/SQLite checks for additive schema v4, configured-account compatibility, server-controlled team/driver capability, dual-capability issuers, foreign-team revoke/identity rejection, immutable account/session bindings, replay/concurrent redemption, username races, session-insert rollback, expiry during hashing, persistent rate limits and live-disable races. Default local verification on Rust 1.99.0 passed formatting, warnings-as-errors Clippy, 84 Rust tests and 44 Python/script tests. The embedded-OSRM build also passed warnings-as-errors Clippy, 88 Rust tests and 2 deterministic native graph/HTTP tests using the pinned OSRM 6.0.0 toolchain; no external routing service was used.

The iOS change adds 45 invite model/unit tests and 2 native form tests. Static Swift syntax/plist checks and independent read-only API/iOS review passed; native build/tests require the exact draft-PR head's macOS CI. Signed-device link dispatch/share-sheet behavior and deployed-HTTPS signup remain manual checks. Existing routing/readiness/team tests are retained, and public CI still withholds raw Xcode diagnostics/results.

Passing CI does not remove the [account-deletion release gate](invites.md#app-store-release-gate). No merge, live invitation, production migration/deployment or TestFlight upload is part of this draft.

## Historical demo verification

# Verification record

Verified on 2026-10-01 in Linux using rustc 1.99.0, and in GitHub Actions on macOS with Xcode 16.4 and an iOS 18.5 simulator.

| Check | Result |
| --- | --- |
| Rust format | Passed: cargo fmt --check |
| Rust Clippy, all targets, warnings denied | Passed |
| Rust unit/planner and real HTTP tests | Passed: 18 tests, comprising 6 planner tests and 12 real TCP/SQLite integration tests |
| Black-box server smoke via Python | Passed: real process + HTTP create/suggest/assign/pickup/drop-off and permission/transition checks |
| API restart persistence probe | Passed: completed job and timestamps, driver shift and last location identical after process restart |
| Startup safety gates | Passed: missing ARRIVAU_DEMO=1 and non-loopback binding both refused |
| Shell/Python syntax and CI YAML/plist parsing | Passed |
| iOS app compile | Passed on macOS/Xcode 16.4 |
| Native unit tests | Passed: 11 tests covering model/API/URL policy and next-stop guards |
| Real app-to-server XCUITest | Passed: 2 tests, including full dispatcher → assignment → driver pickup/drop-off and canceled form/invalid-host flows |
| Main-screen screenshots | Four real simulator PNGs captured and visually checked: dispatcher, delivery form, driver map/stops, shift/location |
| Screenshot exporter | Five regression tests passed, plus exact-byte extraction verified against the four real captured PNGs |
| Physical-device background location | Not run; locked-screen, Maps handoff, poor network, revoked permission and battery behavior still need device testing |

The [first complete native-flow run](https://github.com/Maaarcocr/arrivau/actions/runs/36899061027) passed all native tests and captured the screens, but its post-test exporter failed because successful result bundles had a compact attachment index. The exporter now handles both observed result formats and fails visibly if an expected screen is absent. The [latest Actions result](https://github.com/Maaarcocr/arrivau/actions/workflows/ci.yml) is authoritative for the current commit's aggregate status and downloadable screenshot artifact.

The fixture location is deterministic only under the Debug UI-test flag. All delivery, assignment, location persistence and status requests use the real Rust HTTP server and a fresh SQLite database. Simulator test success does not prove background GPS behavior on a physical iPhone.

