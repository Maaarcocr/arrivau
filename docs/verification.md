# Current pilot verification

The phone-pilot changes add authentication/session/role negative tests, endpoint/session/race/retry tests, release-configuration checks, a container build and an unsigned generic-iOS Release build. Consult the draft PR and the exact head commit's CI before treating these as passed; the historical results below predate the pilot changes.

Never established by CI: owner-hosted HTTPS, persistent-volume deployment/restore, signed physical-iPhone behavior, background GPS while locked/terminated, Apple signing, TestFlight processing or beta review. The manual checklist is in [pilot-runbook.md](pilot-runbook.md).

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

