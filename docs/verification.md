# Verification record

Verified on 2026-10-01 in Linux using rustc 1.99.0 (b940084d7 2026-09-28). The first GitHub macOS run also compiled the native app and executed the tests noted below; full UI-flow verification is still in progress.

| Check | Result |
| --- | --- |
| Rust format | Passed: cargo fmt --check |
| Rust Clippy, all targets, warnings denied | Passed |
| Rust unit/planner and real HTTP tests | Passed: 18 tests, comprising 6 planner tests and 12 real TCP/SQLite integration tests |
| Black-box server smoke via Python | Passed: real process + HTTP create/suggest/assign/pickup/drop-off and permission/transition checks |
| API restart persistence probe | Passed: completed job and timestamps, driver shift and last location identical after process restart |
| Shell syntax, Python syntax and CI YAML parse | Passed |
| Startup safety gates | Passed: missing ARRIVAU_DEMO=1 and non-loopback binding both refused |
| iOS configuration | Passed: project YAML + Debug/Release plist parsing and source review; this is not an Xcode build |
| iOS Swift compile / simulator unit tests | Passed on GitHub macOS/Xcode 16.4: native app compiled and 11 unit tests passed |
| XCUITest app-to-server workflow | Initial runs: cancel/invalid-host UI test passed; lifecycle was blocked by a SwiftUI toggle test tap hitting the label instead of its nested switch. Targeted activation fix and screenshot-enabled rerun in progress |
| GitHub Actions | [Initial run](https://github.com/Maaarcocr/arrivau/actions/runs/36896819365): Linux passed; native UI assertion under repair |

The complete iOS delivery workflow remains unverified until its macOS job passes. Physical-device background location behavior is separate and remains unverified. See the repository’s [Actions](https://github.com/Maaarcocr/arrivau/actions) for current commit results.
