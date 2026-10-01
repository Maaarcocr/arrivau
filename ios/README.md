# Native iOS sketch

SwiftUI, iOS 17+, no third-party runtime dependencies. Dispatcher and driver demo roles share the Rust API in this repository. This is a local prototype, not a production delivery app.

## Run on a Mac

Requirements: Xcode 16+ with an iOS 17+ simulator runtime, XcodeGen, Rust/Cargo for the API.

1. Start the API from the repository root using its README instructions, with `ARRIVAU_DEMO=1` and a local database.
2. `cd ios && xcodegen generate`
3. Open `Arrivau.xcodeproj` and run the `Arrivau` scheme on an iPhone simulator in Debug.
4. The login screen defaults to `http://localhost:8080`, connecting to the Mac's loopback API. Choose Driver 1, start a shift and explicitly enable location sharing. For manual simulator use choose a custom Pachino location (latitude `36.7163`, longitude `15.0908`) under Simulator → Features → Location → Custom Location. Alternatively add `--uitesting` to Debug launch arguments for deterministic Pachino samples; the UI clearly labels simulated location.
5. Switch to Dispatcher, create a delivery, open it, suggest drivers, then assign Driver 1. Switch back to Driver 1 to work the ordered pickup and drop-off stops. Role switches stop local tracking but do not end server-side shifts or discard assigned work.

No remote API host is permitted by this demo. A physical device cannot reach the Mac using `localhost`; a secure authenticated deployment and a reviewed configuration change are prerequisites for real-device end-to-end use. Release builds have no HTTP ATS exception. Demo tokens are public fixture strings, never production secrets; no token storage or production login is supplied.

## Tests

From the repository root, prefer `./scripts/test-ios.sh` to start a fresh backend and run both native test targets. Or generate the project and run:

```sh
xcodebuild test -project ios/Arrivau.xcodeproj \
  -scheme Arrivau \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

Use an installed simulator name. The UI suite requires a running API on `localhost:8080` and a fresh demo database, with Driver 1 off shift and no work. The test scheme fixes `ARRIVAU_API_URL` to `http://localhost:8080`; change its test environment variable in `project.yml` and regenerate to use another loopback port. Do not run the UI suite against a database you care about: it creates deliveries, starts/ends a shift, shares simulated coordinates, assigns, picks up and completes work. There is no test-only reset endpoint.

- `ArrivauTests`: snake_case/Unix-second contract decoding and encoding, coordinates/form validation, next-stop/state/ready-time guards, loopback URL policy, bearer/HTTP/error handling using URLProtocol
- `ArrivauUITests`: real API dispatcher-to-driver lifecycle and persisted completion, plus cancelled creation and invalid remote-host rejection
- `--uitesting` replaces only location sensor input in Debug; all API requests and writes remain real

The Linux authoring environment has no Apple SDK, so native execution runs in GitHub Actions on macOS. Xcode 16.4 compiled the app and passed all 11 unit tests and both UI tests; see `docs/verification.md` and the current Actions run for exact results. Real-device background behavior remains unverified.

## Location and lifecycle

Two distinct opt-ins: “Share location while on shift” starts standard location updates after a successful shift start and When In Use permission. “Continue with screen locked” allows that started session to continue while locked or using Maps. `UIBackgroundModes: location`, `allowsBackgroundLocationUpdates` and the visible iOS location indicator implement this capability. New tracking sessions and permission requests start only in the foreground. Polling deliveries and routes stays foreground-only at five seconds.

No Always permission is requested: Apple supports continued standard updates with When In Use authorization for a foreground-started session using background location capability. This does not guarantee recovery after force-quit, OS termination or reboot. It also does not provide push, background route polling, a durable offline upload queue or a proven delivery SLA. The last server position is retained when tracking stops and marked stale after five minutes. Server suggestions reject stale locations.

CoreLocation uses continuous updates without a distance filter and requests approximately 100 m accuracy. Only fresh sensor samples (under one minute old) are submitted, at most once every 30 seconds. Cached positions are never reposted to make the server timestamp look fresh. iOS may still withhold or pause delivery of useful samples; verify stationary, moving, locked-screen, Maps handoff, revoked permission, poor network, low-power and battery behavior on a physical device before deployment. Review battery/accuracy tradeoffs. Failed uploads are surfaced; the next fresh sample retries naturally.

Disabling sharing, successfully ending a shift, or switching roles stops the manager and cancels pending uploads. A rejected shift end keeps the active shift and its existing opt-ins. Leaving the foreground pauses tracking unless the screen-lock option was explicitly enabled. An in-flight request already accepted by the server cannot be withdrawn.

Primary Apple references: [background location updates](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates), [location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services), [local-network ATS configuration](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## Planning limits

The native map shows stop pins. Apple Maps opens external turn-by-turn directions for the next stop only. The Rust planner uses approximate distances and constant speed, not a live road matrix or traffic. The server remains authoritative for feasibility, capacity, deadlines, maximum onboard time, pickup readiness and the next allowed action. Infeasible committed work remains visible with warnings.

## Main-screen screenshots from GitHub Actions

The real-backend lifecycle UI test saves these named PNG screenshot attachments with `keepAlways`, so they survive successful runs as well as failures:

- `01-dispatcher-jobs`: populated dispatcher list after the demo delivery is assigned
- `02-new-delivery`: filled delivery form before submission, with the keyboard dismissed
- `03-driver-route`: the assigned driver's real ordered route and native map
- `04-driver-shift`: on-shift controls and confirmed opt-in location reporting

The fixture uses `Pizzeria Pachino Demo`, the sample Pachino pickup/drop-off, a ready time in the past and a deadline one hour ahead. Only sensor coordinates are simulated; delivery creation, assignment, location persistence, pickup and completion all use the running Rust API. Each capture first scrolls to and checks its visible screen anchor. Screenshot timestamps and map tiles can vary; this is UI capture, not pixel-diff testing.

The Xcode `.xcresult` artifact contains the attachments. GitHub Actions exports the named screenshots for separate download/sharing; the export step must include successful attachments, rather than only failures. Failure screenshots and an accessibility hierarchy remain separate diagnostics.
