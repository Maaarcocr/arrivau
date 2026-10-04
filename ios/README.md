# Native iOS pilot

The normal app now signs in to a configured HTTPS pilot service using individual credentials and server-assigned team memberships and capabilities. It securely stores expiring sessions in the Keychain, restores them only after server verification, revokes on reachable logout, and clears private state/GPS on signout or expiry. Release has no demo chooser or fixture tokens.

Start with [the pilot runbook](../docs/pilot-runbook.md) and [TestFlight publishing steps](../README.md#publish-to-testflight). `ARRIVAU_API_URL` is a non-secret build setting embedded in Info.plist; when blank, the login screen asks for the HTTPS root origin. `scripts/archive-ios.sh` validates configuration and only builds a local archive.

For simulator development, launch the Debug app with `--demo`. `--uitesting` implies the isolated loopback demo. These flags and environment fixture overrides are compiled out of Release. The older detailed workflow below describes this explicit demo/test mode; physical phones use the pilot login.

The icon and privacy manifest live in `Resources/`. Recheck privacy declarations against the deployed service and App Store Connect disclosures. The operator must verify a signed build on physical devices; neither an unsigned Release build nor simulator UI tests establish background GPS or TestFlight readiness.

## Invite-only corriere signup

**App Store rollout gate:** this follow-up adds in-app account creation but not account deletion. [Apple requires an in-app path to initiate account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/) for apps supporting creation. Keep this work out of the publication build until a compliant deletion flow and associated data-retention behavior are implemented and verified; signout or invite revocation is not account deletion.

A signed-in pilot dispatcher taps **Invita un corriere**, enters the driver’s name and creates an invitation. **Condividi invito** opens the native share sheet. The target **Squadra** is shown before creation and sharing. It comes only from the dispatcher’s authenticated session; a mismatched or malformed team response is rejected before sharing. Each link is a bearer secret, grants only the server-defined `driver` role in that team, expires after 24 hours, and can be redeemed once. Send it only to the intended recipient. While that invitation is displayed, **Revoca invito** can revoke it by its non-secret UUID; revocation cannot delete an account already created. Closing the sheet forgets the secret locally, so share or revoke it before leaving. Lost creation responses are not automatically retried; an unshared invitation expires on the server.

The recipient installs Arrivau, opens `arrivau://invite?token=<64 lowercase hex characters>`, and chooses a username and password. If a messaging app does not open custom schemes, paste the link or token into **Hai ricevuto un invito?** on the login screen. This is a custom URL scheme, not an HTTPS universal link or a deferred App Store install flow. An app installed by another vendor can register the same scheme; share privately and check that Arrivau opens. An already signed-in recipient is never logged out or switched automatically.

The link cannot configure a server: extra parameters (including endpoint overrides), fragments, paths, user info, ports, percent-encoded tokens and duplicate query keys are rejected. The configured or explicitly entered HTTPS origin remains authoritative, and no HTTP redirects are followed. Supply and verify the pilot server separately; no credentials are sent until the recipient taps **Crea account e accedi**. Username rules: 1–64 ASCII characters, starting with a lowercase letter or digit, followed by lowercase letters, digits, `.`, `_` or `-`. Password limits are 12–1024 UTF-8 bytes.

Successful signup requires explicit, valid team identity and exactly one `driver` capability (no dispatcher/dual grants), then installs the returned opaque login session in the existing Keychain path. Existing dual-account view switching and team/account/endpoint-scoped delivery and restaurant recovery remain unchanged. Invitation secrets and passwords are never persisted in defaults or Keychain. Cancellation, repeated submission, session restoration, logout and late responses retain the session-generation guards. If signup’s result is uncertain, the UI stops redemption retries and directs the recipient to normal **Accedi** with the same credentials on the same server. The account may already exist. This reminder is held only in memory; after relaunch, a used invitation is still rejected by the server and the login path remains available.

`InviteTests` cover strict parsing, request bodies and bearer isolation, account/session installation and recovery races. `InviteFlowUITests` cover pasted-link rejection, interruption, cancel/reopen and local HTTPS validation using an isolated pilot screen. The current native UI harness runs its real backend in demo mode, where invites are unavailable: these invite UI checks do not claim a live HTTPS end-to-end signup, native share-sheet delivery or installed-app deep-link launch verification. Run the full simulator suite on macOS, then verify these device flows against the deployed HTTPS pilot before rollout.

## Local demo implementation and test reference

# Native iOS sketch

SwiftUI, iOS 17+, no third-party runtime dependencies. Dispatcher and driver demo roles share the Rust API in this repository. The following section covers only the isolated local demo.

## Run on a Mac

Requirements: Xcode 26+ with an iOS 17+ simulator runtime, XcodeGen, Rust/Cargo for the API.

1. Start the API from the repository root using its README instructions, with `ARRIVAU_DEMO=1` and a local database.
2. `cd ios && xcodegen generate`
3. Open `Arrivau.xcodeproj` and run the `Arrivau` scheme on an iPhone simulator in Debug.
4. Add `--demo` to the Debug launch arguments. The demo login screen defaults to `http://localhost:8080`, connecting to the Mac's loopback API. Choose Corriere 1 and tap **Avvia turno e condividi posizione**. This button explicitly opts into foreground location sharing. For manual simulator use choose a custom Pachino location (latitude `36.7163`, longitude `15.0908`) under Simulator → Features → Location → Custom Location. Alternatively add `--uitesting` to Debug launch arguments for deterministic Pachino samples; the UI clearly labels simulated location.
5. Switch to Centrale, tap **Nuova consegna**, select a saved restaurant (or **Aggiungi ristorante** and choose its address with Maps), choose the destination, then **Crea consegna**. Creation does not ask for food readiness or a driver. Open the order when its readiness is known and choose **Pronta ora** or **Pronta tra X minuti**. The server assigns an eligible driver automatically when ready; a future estimate waits until its time. Switch back to Corriere 1 to work the ordered pickup and drop-off stops. Switching demo accounts stops local tracking but does not end server-side shifts or discard assigned work. For one dual-capability account, use the in-session Centrale / Corriere picker; existing explicit location consent continues across these views, and a visible status/stop control remains available.

No remote API host is permitted by this demo. A physical device cannot reach the Mac using `localhost`; use the HTTPS pilot login described above. Release builds have no HTTP ATS exception and compile out public demo fixture tokens. Pilot sessions use the Keychain; passwords are not saved.

## Tests

From the repository root, prefer `./scripts/test-ios.sh` to start a fresh backend and run both native test targets. Or generate the project and run:

```sh
xcodebuild test -project ios/Arrivau.xcodeproj \
  -scheme Arrivau \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

Use an installed simulator name. The UI suite requires a running API on `localhost:8080` and a fresh demo database, with Corriere 1 off shift and no work. The test scheme fixes `ARRIVAU_API_URL` to `http://127.0.0.1:8080`; change its test environment variable in `project.yml` and regenerate to use another loopback port. Do not run the UI suite against a database you care about: it saves restaurants, creates deliveries, updates readiness, starts/ends a shift, shares simulated coordinates, automatically assigns, picks up and completes work. There is no test-only reset endpoint.

- `ArrivauTests`: snake_case/Unix-second contract decoding and encoding, coordinates/form validation, next-stop/state/ready-time guards, HTTPS and isolated-loopback URL policies, bearer/HTTP/error handling using URLProtocol, pilot session restore/expiry/revocation and pending-action recovery
- `ArrivauUITests`: real API restaurant selection/creation, unknown readiness at order creation, cancelled and saved estimates, automatic assignment after Ready now, dispatcher-to-driver completion, pending-job reopening, and invalid remote-host rejection
- `ReadinessStoreTests`: exact revision/body/key retries after lost or cancelled readiness responses, double taps, role/session switches, stale response guards, conflict refresh requirements, automatic assignment response application, and durable team-scoped restaurant recovery with storage failures
- `--uitesting` replaces location sensor input and address-search results in Debug; all API requests and writes remain real

The Linux authoring environment has no Apple SDK, so native execution runs in GitHub Actions on macOS. The historical baseline build was verified with Xcode 16.4; the pilot CI now selects Xcode 26.6; see `docs/verification.md` for that baseline and the Actions run for the exact current commit for updated results. The current suite also covers confirmed-state recovery and address selection. Real-device background behavior remains unverified.

## Location and lifecycle

Two distinct opt-ins: **Avvia turno e condividi posizione** starts the shift and standard location updates after When In Use permission. Returning to an already active shift offers **Riprendi condivisione posizione**. Existing sharing controls remain in the shift sheet. “Continua con lo schermo bloccato” allows that started session to continue while locked or using Maps. `UIBackgroundModes: location`, `allowsBackgroundLocationUpdates` and the visible iOS location indicator implement this capability. New tracking sessions and permission requests start only in the foreground. Polling deliveries and routes stays foreground-only at five seconds.

No Always permission is requested: Apple supports continued standard updates with When In Use authorization for a foreground-started session using background location capability. This does not guarantee recovery after force-quit, OS termination or reboot. It also does not provide push, background route polling, a durable offline upload queue or a proven delivery SLA. The last server position is retained when tracking stops and marked stale after five minutes. Manual suggestions reject stale locations; automatic assignment can retain work with a warning. Missing GPS does not invent a starting point or ETA.

CoreLocation uses continuous updates without a distance filter and requests approximately 100 m accuracy. Only fresh sensor samples (under one minute old) are submitted, at most once every 30 seconds. Cached positions are never reposted to make the server timestamp look fresh. iOS may still withhold or pause delivery of useful samples; verify stationary, moving, locked-screen, Maps handoff, revoked permission, poor network, low-power and battery behavior on a physical device before deployment. Review battery/accuracy tradeoffs. Failed uploads are surfaced; the next fresh sample retries naturally.

Disabling sharing, successfully ending a shift, or signing out/switching demo accounts stops the manager and cancels pending uploads. Switching Centrale / Corriere views within one server-authorized dual account preserves existing foreground/background opt-ins without starting tracking, starting or ending a shift, or changing the bearer. Only the driver's explicit actions may enable sharing; either view can stop it through the visible status/stop control. Session restoration never restores location opt-ins. A rejected shift end keeps the active shift and its existing opt-ins. Leaving the foreground pauses tracking unless the screen-lock option was explicitly enabled. An in-flight request already accepted by the server cannot be withdrawn.

Primary Apple references: [background location updates](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates), [location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services), [local-network ATS configuration](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## Planning limits

The native map shows stop pins. Apple Maps opens external turn-by-turn directions for the next stop only. The Rust planner defaults to approximate distances and constant speed; [optional embedded OSRM](../docs/embedded-routing.md) supplies offline road-time matrices. The app shows the exact approximation/fallback notice, source date and OpenStreetMap attribution returned by the server. There is no live traffic. The server remains authoritative for readiness, automatic assignment, capacity, deadlines, maximum onboard time and the next allowed action. Ready orders aim for pickup within 10 minutes of availability; a missed pickup target is a notice, separate from hard feasibility warnings. When no on-time route exists, the server can assign the least-bad structurally valid route and keep its timing warnings visible. A missing driver location leaves stops and allowed actions visible but sets `estimates_available=false`: the app hides travel/arrival projections and displays “Posizione non disponibile; orari da verificare”. Unreachable road legs also hide ETA projections and show “Percorso non raggiungibile; orari non disponibili”; they never qualify for automatic timing fallback. Stale known locations retain visibly qualified estimates. Genuine load/route limits or no on-shift driver keep a ready order pending with a specific Italian reason; the server retries automatically.

## Main-screen screenshots from GitHub Actions

The real-backend UI tests run with Italian language and region settings and save these named PNG screenshot attachments with `keepAlways`, so they survive successful runs as well as failures:

- `00-login`: Italian role selection
- `01-dispatcher-jobs`: populated dispatcher list after the demo delivery is assigned
- `02-new-delivery`: saved restaurant and destination selected before creation, with no readiness or driver chooser
- `03-driver-route`: the assigned driver's next stop and immediate actions
- `04-driver-shift`: on-shift controls and confirmed opt-in location reporting
- `05-driver-assignment`: confirmed-ready detail after automatic driver assignment (filename retained for export compatibility)
- `06-address-search`: native address-selection flow while adding a restaurant, with a fixture result
- `07-delivery-timing`: expanded delivery-deadline control; readiness is absent from creation

The fixture uses `Pizzeria Pachino Demo`, the sample Pachino pickup/drop-off, unknown readiness at submission and a deadline one hour ahead. It saves a 10-minute estimate, then explicitly confirms ready now and verifies automatic assignment. Location sensor and Maps search inputs are deterministic fixtures; delivery creation, assignment, location persistence, pickup and completion all use the running Rust API. Each capture first scrolls to and checks its visible screen anchor. Screenshot timestamps and map tiles can vary; this is UI capture, not pixel-diff testing.

The local Xcode `.xcresult` bundle contains attachments and may also contain unrelated simulator-service credentials. Never upload raw result bundles or simulator diagnostics. GitHub Actions publishes only the allowlisted check-status summary and named app screenshots; the exporter includes successful screenshots rather than only failures. Keep other local failure diagnostics private.


The same export also requires `dual-account-centrale` and `dual-account-corriere`, showing the private team label and the same-account view picker.

## Minimal everyday flow

- Driver home prioritizes the next stop, directions and pickup/drop-off completion. The ordered map, completed rows and shift/privacy controls are secondary. Capacity uses the driver's existing server setting; it is not a task required before every shift.
- Dispatcher home puts pending work first. Creation selects a saved team restaurant plus destination. Adding a restaurant uses a Maps-selected address and coordinate with an editable name; selecting it reuses the exact saved pickup snapshot and restaurant ID. Nothing defaults silently to a sample address.
- Creation defaults only the delivery deadline (one hour), one load unit and a 30-minute maximum ride. The optional timing disclosure changes the deadline, never food readiness.
- New orders are “Da definire” until the dispatcher opens them and chooses **Pronta ora** or **Pronta tra X minuti** (1–120). An elapsed forecast remains a **stima**; only explicit Ready now is **confermata**. Pickup needs known readiness whose timestamp has arrived.
- The server assigns automatically when ready, including when a forecast reaches its time. Unknown/future/pending orders do not show a driver chooser. **Cambia corriere** remains a deliberate optional override after assignment. Pickup/delivery ETA, target notices and route warnings are visible on assigned details and the driver route.
- Uncertain readiness retries retain the original minutes, revision and idempotency key for the current session. Conflicts require authoritative refresh before a new attempt. A stale revision never replaces newer local readiness. Legacy pending orders need an explicit readiness action to activate automatic assignment.
- Restaurant creation saves its exact body/key in team/account/endpoint-scoped Keychain recovery before sending. Relaunch or switching accounts cannot turn a retry into another creation or send it to another team. Cancelling a restaurant/address/estimate sheet before submission sends no write; successful restaurant selection preserves the saved record for later orders.
- Raw coordinates, route scoring, capacity, sync timestamps and development configuration are absent from the everyday screens. Demo connection settings and limitations remain available from the role chooser.
- Maps search sends the entered query to Apple and requires connectivity. Empty/error results stay editable; cancelling search keeps the previous selection. The app does not fall back to invented coordinates.

## Italian presentation

All app-owned screens, accessibility labels, validation and location-permission explanations are Italian. The app advertises Italian as its development language and uses `it_IT` for in-app date and time formatting. Demo identity labels are translated only when both the known ID and original seeded name match; entered business names and addresses are preserved. API status values, role identifiers, error strings and route warning payloads remain unchanged on the wire. A presentation adapter translates known server messages and shows an Italian fallback for unknown failures. Uncertain creation outcomes use a typed flag instead of matching translated error text.

The UI suite keeps cancellation, repeated-submit and pending-job reopening coverage, and checks repeated details expansion plus background/foreground interruptions. Physical-device location behavior still needs the validation described above.


## One account, two views and one team

The authenticated principal supplies `roles`, `team_id` and `team_name`. Missing `roles` falls back only to the legacy single `role`; an explicit empty/malformed capability list cannot grant that legacy privilege. Only accounts authorized for both functions see the Centrale / Corriere picker. The team label stays visible and cannot change membership. Dispatcher reads remain team-wide; the driver view filters work to the authenticated account's own driver ID and uses its own shift/route endpoints.

The Debug demo has a separate **Centrale e corriere** account (`demo-dual`, driver `dual-1`, `demo-review` / `Squadra revisione`). It is isolated from the original demo team. Public demo tokens, chooser and sensor fixtures remain compiled out of Release. This fixture is not an App Review production credential; see [the review-team runbook](../docs/teams-and-review.md) for supervised server provisioning.

Recovery records use endpoint + team + account identity, independent of selected view. A pre-team record cannot prove its original team, so it is quarantined: original addresses, readiness and request reference remain visible, but new creation/retry is blocked. After checking the original server outcome with the operator, the user may open **Ho verificato la consegna** and confirm removal of that one local recovery record. The confirmation warns that recreating an existing job could duplicate it and never deletes or replays server work. Cancel leaves the record intact. The removal checks the displayed request, current session/team and unchanged storage record; storage errors retain the block. Signing out does not silently discard uncertain work.

Additional tests cover same-session dual views, own-driver filtering, disabled hidden actions, stale refresh/suggestion responses, blocked mid-mutation switching, team-scoped replay, legacy review cancellation/confirmation/errors/stale contexts, restored/reduced capabilities, and logout/expiry stopping tracking even from Centrale. The real-API dual UI lifecycle creates, marks ready, receives automatic self-assignment, picks up and delivers within the isolated review team, checks repeated/background switches and explicit pause/resume, and verifies original-demo data is unchanged. Native/macOS CI remains required; Linux structural parsing does not establish an Apple SDK build or simulator pass.
