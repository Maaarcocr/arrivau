# Native iOS pilot

The normal app now signs in to a configured HTTPS pilot service using individual credentials and server-assigned team memberships and capabilities. It securely stores expiring sessions in the Keychain, restores them only after server verification, revokes on reachable logout, and clears private state/GPS on signout or expiry. Release has no demo chooser or fixture tokens.

Start with [the pilot runbook](../docs/pilot-runbook.md) and [TestFlight/signing guide](../docs/testflight.md). `ARRIVAU_API_URL` is a non-secret build setting embedded in Info.plist; when blank, the login screen asks for the HTTPS root origin. Set your own team and registered bundle ID when archiving. `scripts/archive-ios.sh` validates configuration and only builds an archive.

For simulator development, launch the Debug app with `--demo`. `--uitesting` implies the isolated loopback demo. These flags and environment fixture overrides are compiled out of Release. The older detailed workflow below describes this explicit demo/test mode; physical phones use the pilot login.

The icon and privacy manifest live in `Resources/`. Recheck privacy declarations against the deployed service and App Store Connect disclosures. The operator must verify a signed build on physical devices; neither an unsigned Release build nor simulator UI tests establish background GPS or TestFlight readiness.

## Local demo implementation and test reference

# Native iOS sketch

SwiftUI, iOS 17+, no third-party runtime dependencies. Dispatcher and driver demo roles share the Rust API in this repository. The following section covers only the isolated local demo.

## Run on a Mac

Requirements: Xcode 26+ with an iOS 17+ simulator runtime, XcodeGen, Rust/Cargo for the API.

1. Start the API from the repository root using its README instructions, with `ARRIVAU_DEMO=1` and a local database.
2. `cd ios && xcodegen generate`
3. Open `Arrivau.xcodeproj` and run the `Arrivau` scheme on an iPhone simulator in Debug.
4. Add `--demo` to the Debug launch arguments. The demo login screen defaults to `http://localhost:8080`, connecting to the Mac's loopback API. Choose Corriere 1 and tap **Avvia turno e condividi posizione**. This button explicitly opts into foreground location sharing. For manual simulator use choose a custom Pachino location (latitude `36.7163`, longitude `15.0908`) under Simulator → Features → Location → Custom Location. Alternatively add `--uitesting` to Debug launch arguments for deterministic Pachino samples; the UI clearly labels simulated location.
5. Switch to Gestisci le consegne, tap **Nuova consegna**, choose pickup and destination from Maps search, then **Scegli il corriere**. Driver suggestions load automatically in the same flow; tap **Assegna a Corriere 1**. Switch back to Corriere 1 to work the ordered pickup and drop-off stops. Switching demo accounts stops local tracking but does not end server-side shifts or discard assigned work. For one dual-capability account, use the in-session Centrale / Corriere picker; existing explicit location consent continues across these views, and a visible status/stop control remains available.

No remote API host is permitted by this demo. A physical device cannot reach the Mac using `localhost`; use the HTTPS pilot login described above. Release builds have no HTTP ATS exception and compile out public demo fixture tokens. Pilot sessions use the Keychain; passwords are not saved.

## Tests

From the repository root, prefer `./scripts/test-ios.sh` to start a fresh backend and run both native test targets. Or generate the project and run:

```sh
xcodebuild test -project ios/Arrivau.xcodeproj \
  -scheme Arrivau \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

Use an installed simulator name. The UI suite requires a running API on `localhost:8080` and a fresh demo database, with Corriere 1 off shift and no work. The test scheme fixes `ARRIVAU_API_URL` to `http://127.0.0.1:8080`; change its test environment variable in `project.yml` and regenerate to use another loopback port. Do not run the UI suite against a database you care about: it creates deliveries, starts/ends a shift, shares simulated coordinates, assigns, picks up and completes work. There is no test-only reset endpoint.

- `ArrivauTests`: snake_case/Unix-second contract decoding and encoding, coordinates/form validation, next-stop/state/ready-time guards, HTTPS and isolated-loopback URL policies, bearer/HTTP/error handling using URLProtocol, pilot session restore/expiry/revocation and pending-action recovery
- `ArrivauUITests`: real API dispatcher-to-driver lifecycle and persisted completion, plus cancelled creation and invalid remote-host rejection
- `--uitesting` replaces location sensor input and address-search results in Debug; all API requests and writes remain real

The Linux authoring environment has no Apple SDK, so native execution runs in GitHub Actions on macOS. The historical baseline build was verified with Xcode 16.4; the pilot CI now selects Xcode 26.6; see `docs/verification.md` for that baseline and the Actions run for the exact current commit for updated results. The current suite also covers confirmed-state recovery and address selection. Real-device background behavior remains unverified.

## Location and lifecycle

Two distinct opt-ins: **Avvia turno e condividi posizione** starts the shift and standard location updates after When In Use permission. Returning to an already active shift offers **Riprendi condivisione posizione**. Existing sharing controls remain in the shift sheet. “Continua con lo schermo bloccato” allows that started session to continue while locked or using Maps. `UIBackgroundModes: location`, `allowsBackgroundLocationUpdates` and the visible iOS location indicator implement this capability. New tracking sessions and permission requests start only in the foreground. Polling deliveries and routes stays foreground-only at five seconds.

No Always permission is requested: Apple supports continued standard updates with When In Use authorization for a foreground-started session using background location capability. This does not guarantee recovery after force-quit, OS termination or reboot. It also does not provide push, background route polling, a durable offline upload queue or a proven delivery SLA. The last server position is retained when tracking stops and marked stale after five minutes. Server suggestions reject stale locations.

CoreLocation uses continuous updates without a distance filter and requests approximately 100 m accuracy. Only fresh sensor samples (under one minute old) are submitted, at most once every 30 seconds. Cached positions are never reposted to make the server timestamp look fresh. iOS may still withhold or pause delivery of useful samples; verify stationary, moving, locked-screen, Maps handoff, revoked permission, poor network, low-power and battery behavior on a physical device before deployment. Review battery/accuracy tradeoffs. Failed uploads are surfaced; the next fresh sample retries naturally.

Disabling sharing, successfully ending a shift, or signing out/switching demo accounts stops the manager and cancels pending uploads. Switching Centrale / Corriere views within one server-authorized dual account preserves existing foreground/background opt-ins without starting tracking, starting or ending a shift, or changing the bearer. Only the driver's explicit actions may enable sharing; either view can stop it through the visible status/stop control. Session restoration never restores location opt-ins. A rejected shift end keeps the active shift and its existing opt-ins. Leaving the foreground pauses tracking unless the screen-lock option was explicitly enabled. An in-flight request already accepted by the server cannot be withdrawn.

Primary Apple references: [background location updates](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates), [location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services), [local-network ATS configuration](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## Planning limits

The native map shows stop pins. Apple Maps opens external turn-by-turn directions for the next stop only. The Rust planner uses approximate distances and constant speed, not a live road matrix or traffic. The server remains authoritative for feasibility, capacity, deadlines, maximum onboard time, pickup readiness and the next allowed action. Infeasible committed work remains visible with warnings.

## Main-screen screenshots from GitHub Actions

The real-backend UI tests run with Italian language and region settings and save these named PNG screenshot attachments with `keepAlways`, so they survive successful runs as well as failures:

- `00-login`: Italian role selection
- `01-dispatcher-jobs`: populated dispatcher list after the demo delivery is assigned
- `02-new-delivery`: filled delivery form before submission, with the keyboard dismissed
- `03-driver-route`: the assigned driver's next stop and immediate actions
- `04-driver-shift`: on-shift controls and confirmed opt-in location reporting
- `05-driver-assignment`: suggested driver and assignment action
- `06-address-search`: native address-selection flow with a fixture result
- `07-delivery-timing`: expanded date and time controls

The fixture uses `Pizzeria Pachino Demo`, the sample Pachino pickup/drop-off, a ready time at submission and a deadline one hour ahead. Location sensor and Maps search inputs are deterministic fixtures; delivery creation, assignment, location persistence, pickup and completion all use the running Rust API. Each capture first scrolls to and checks its visible screen anchor. Screenshot timestamps and map tiles can vary; this is UI capture, not pixel-diff testing.

The Xcode `.xcresult` artifact contains the attachments. GitHub Actions exports the named screenshots for separate download/sharing; the export step must include successful attachments, rather than only failures. Failure screenshots and an accessibility hierarchy remain separate diagnostics.


## Minimal everyday flow

- Driver home prioritizes the next stop, directions and pickup/drop-off completion. The ordered map, completed rows and shift/privacy controls are secondary. Capacity uses the driver's existing server setting; it is not a task required before every shift.
- Dispatcher home puts pending work first. Creation needs only pickup and destination; the selected Maps result supplies its routing point and pickup name together. Nothing defaults silently to a sample address.
- Timing defaults to ready now and due within one hour; expand the timing section only to change it. The small-delivery defaults remain one load unit and a 30-minute maximum ride. Server route validation remains authoritative.
- Creation leads directly to an automatically loaded suggestion. Assignment is still a deliberate tap, and a failed assignment retains the pending delivery rather than creating it again.
- Raw coordinates, route scoring, capacity, sync timestamps and development configuration are absent from the everyday screens. Demo connection settings and limitations remain available from the role chooser.
- Maps search sends the entered query to Apple and requires connectivity. Empty/error results stay editable; cancelling search keeps the previous selection. The app does not fall back to invented coordinates.

## Italian presentation

All app-owned screens, accessibility labels, validation and location-permission explanations are Italian. The app advertises Italian as its development language and uses `it_IT` for in-app date and time formatting. Demo identity labels are translated only when both the known ID and original seeded name match; entered business names and addresses are preserved. API status values, role identifiers, error strings and route warning payloads remain unchanged on the wire. A presentation adapter translates known server messages and shows an Italian fallback for unknown failures. Uncertain creation outcomes use a typed flag instead of matching translated error text.

The UI suite keeps cancellation, repeated-submit and pending-job reopening coverage, and checks repeated details expansion plus background/foreground interruptions. Physical-device location behavior still needs the validation described above.


## One account, two views and one team

The authenticated principal supplies `roles`, `team_id` and `team_name`. Missing `roles` falls back only to the legacy single `role`; an explicit empty/malformed capability list cannot grant that legacy privilege. Only accounts authorized for both functions see the Centrale / Corriere picker. The team label stays visible and cannot change membership. Dispatcher reads remain team-wide; the driver view filters work to the authenticated account's own driver ID and uses its own shift/route endpoints.

The Debug demo has a separate **Centrale e corriere** account (`demo-dual`, driver `dual-1`, `demo-review` / `Squadra revisione`). It is isolated from the original demo team. Public demo tokens, chooser and sensor fixtures remain compiled out of Release. This fixture is not an App Review production credential; see [the review-team runbook](../docs/teams-and-review.md) for supervised server provisioning.

Recovery records use endpoint + team + account identity, independent of selected view. A pre-team record cannot prove its original team, so it is quarantined: original addresses, readiness and request reference remain visible, but new creation/retry is blocked. After checking the original server outcome with the operator, the user may open **Ho verificato la consegna** and confirm removal of that one local recovery record. The confirmation warns that recreating an existing job could duplicate it and never deletes or replays server work. Cancel leaves the record intact. The removal checks the displayed request, current session/team and unchanged storage record; storage errors retain the block. Signing out does not silently discard uncertain work.

Additional tests cover same-session dual views, own-driver filtering, disabled hidden actions, stale refresh/suggestion responses, blocked mid-mutation switching, team-scoped replay, legacy review cancellation/confirmation/errors/stale contexts, restored/reduced capabilities, and logout/expiry stopping tracking even from Centrale. The real-API dual UI lifecycle creates, self-assigns, picks up and delivers within the isolated review team, checks repeated/background switches and explicit pause/resume, and verifies original-demo data is unchanged. Native/macOS CI remains required; Linux structural parsing does not establish an Apple SDK build or simulator pass.
