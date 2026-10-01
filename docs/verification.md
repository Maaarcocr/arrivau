# Verification record

Verified on 2026-10-01 in Linux using rustc 1.99.0 (b940084d7 2026-09-28). Native stages below remain unexecuted.

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
| iOS Swift compile / simulator unit tests | Not run: this execution environment is Linux with no Xcode SDK or simulator |
| XCUITest app-to-server workflow | Written for macOS; not run here |
| GitHub Actions | Configured; no remote repository run has been observed |

The iOS project should be treated as unverified until the macOS job completes successfully. Source review and YAML/plist validation cannot substitute for Xcode compilation or a simulator run.
