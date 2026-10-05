# In-app Google navigation

This change prepares the SDK integration. Live activation remains incomplete
until compatible destination entry and per-destination provenance are in place;
there is no global configuration flag that permits existing Apple-derived data.

Arrivau uses Google's native iOS Navigation SDK for turn-by-turn guidance to the
driver's **next server-authorized stop**. Guidance is separate from the Rust
delivery planner: it must not reorder jobs, mark pickup/delivery complete, or
replace the server's readiness and timing rules. GPS arrival is not confirmation.

The SDK is initialized only when the driver opens navigation. An absent API key
leaves guidance unavailable; ordinary builds, login and delivery controls still
work. A configured key alone does not establish that destination data may be sent
to Google. See the destination-source and release gates below.

## Dependencies and platform

`ios/project.yml` pins these official Swift Package Manager packages:

- `https://github.com/googlemaps/ios-navigation-sdk`, product `GoogleNavigation`,
  exact version **11.2.0**
- `https://github.com/googlemaps/ios-maps-sdk`, product `GoogleMaps`, exact version
  **11.2.0**, also constraining Navigation's otherwise open-ended Maps dependency

XcodeGen generates the ignored Xcode project. Do not vendor SDK binaries or commit
generated projects. The app retains iOS 17 and CI's Xcode 26.6/iOS 26 SDK. Google's
11.x release requires at least iOS 16 and Xcode 26. Package resolution needs
network access even with no API key. See [release notes](https://developers.google.com/maps/documentation/navigation/ios-sdk/release-notes)
and [the pinned manifest](https://github.com/googlemaps/ios-navigation-sdk/blob/11.2.0/Package.swift).

Both Info.plist templates include location/motion usage descriptions and the
`location`/`audio` background modes. The Always location description is SDK setup
metadata; it does **not** request or grant Always authorization. The app uses an
explicitly started When In Use session. Background capability is not consent:
guidance must pause without the driver's explicit screen-lock opt-in. The motion
description supports SDK 11's altitude-related sensor use. Google URL query
schemes permit SDK attribution links; they are not an external navigation fallback.
Sources: [Xcode setup](https://developers.google.com/maps/documentation/navigation/ios-sdk/xcode-setup),
[routing and motion authorization](https://developers.google.com/maps/documentation/navigation/ios-sdk/route),
[Apple location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services).

## Owner setup, outside this repository

This integration and its scripts do not create a Google Cloud project, billing
account, key, permission grant, paid service or upload. An authorized owner must:

1. Review applicable Google Maps Platform terms and billing for an appropriately
   configured Google Cloud project. Enable **Navigation SDK** and **Maps SDK for
   iOS**. Destination requests are billable; review current pricing and configure
   suitable quota/budget alerts.
2. Restrict the key to **iOS applications** and the exact installed bundle ID.
   The default development ID is `dev.arrivau.app`. The existing archive workflow
   requires the owner's registered `ARRIVAU_BUNDLE_ID`; restrict the key to that
   actual signed ID instead. Prefer separate development/production keys.
3. Restrict API access to **Navigation SDK** and **Maps SDK for iOS**. Server IP
   and HTTP referrer restrictions do not replace iOS app restrictions. Verify
   restrictions with the intended signed build.
4. Supply the key through the private local environment or the existing manual
   TestFlight workflow's optional repository secret
   `ARRIVAU_GOOGLE_MAPS_API_KEY`. Never paste it into tracked source, a PR, issue,
   shell argument, screenshot or build log.

The distributed app necessarily contains its key. Private configuration/logs are
hygiene measures; API/bundle restrictions, quotas and monitoring protect against
misuse. References: [setup overview](https://developers.google.com/maps/documentation/navigation/ios-sdk/setup-overview),
[API security](https://developers.google.com/maps/api-security-best-practices),
[current Navigation pricing](https://developers.google.com/maps/documentation/navigation/ios-sdk/pricing).

## Private local configuration

`ARRIVAU_GOOGLE_MAPS_API_KEY` defaults to an empty build setting; the app reads it
from its built Info.plist. Do not pass the key to `xcodebuild` as a build setting
or put it in an xcconfig: Xcode can print resolved configuration values.

Make it available as an environment variable using your approved local secret
management process, then run from the repository root:

```sh
set +x
python3 scripts/navigation-config.py --configuration Debug
unset ARRIVAU_GOOGLE_MAPS_API_KEY
(cd ios && xcodegen generate)
```

The helper writes `ios/Config/Navigation.local/Info-Debug.plist`, ignored by Git
and mode `0600`. It copies the tracked template and replaces only the key,
preserving version, bundle ID and API-origin substitutions. It never echoes the
key and rejects unsafe characters. Blank input generates a blank key; no-key CI
does not need private configuration.

For a local app build, pass only the generated **file path**:

```sh
xcodebuild build -project ios/Arrivau.xcodeproj -scheme Arrivau \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  INFOPLIST_FILE="$PWD/ios/Config/Navigation.local/Info-Debug.plist"
```

For Xcode Run, select the **Arrivau application target**, Build Settings →
Packaging → Info.plist File, and set the Debug value to
`Config/Navigation.local/Info-Debug.plist`. This changes only the ignored
generated project; XcodeGen regeneration resets it. Do not apply the override to
test targets. Regenerate private configuration after tracked template changes.
Delete it when no longer needed; build products also contain the key.

`scripts/archive-ios.sh` reads the optional environment variable, generates a
temporary Release Info.plist, removes the key from Xcode's environment and passes
only the plist path. An exit/signal trap deletes the temporary configuration.
It still validates the owner's pilot settings and **does not upload**. The
resulting archive remains on the owner's machine.

Manual TestFlight does the same inside its private temporary directory; existing
cleanup removes configuration, signing files and build products. An unset secret
produces a build with navigation unavailable. No push or PR triggers that
workflow. Its main-only signing opt-in and separately selected upload action
remain required. Adding a key neither authorizes publication nor satisfies the
following release gates.

## Destination data and release gates

Do not send Apple Maps search results to Google. Apple's developer agreement
defines Map Data to include addresses and coordinates and restricts combining
it with a non-Apple map. Existing restaurant/job addresses and coordinates
selected using `MKLocalSearch` are Apple-derived. Re-geocoding those stored
formatted addresses with another provider does not establish independent
provenance. Unknown/legacy sources must fail closed for Google navigation;
an operator-wide flag cannot relabel existing data.

Only destinations with independently established, compatible provenance may be
used. Verify each destination, including restaurant pickup snapshots, existing
drop-offs and restored/retried creation data. Provenance must survive server
storage and route responses. Resolve this before Google guidance is enabled for
actual work; configuring a key is insufficient. See [Apple's agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/),
Map Data definition and Attachment 6, particularly sections 2.2–2.5.

Before distributing a Google-enabled pilot or App Store build:

- Review Google terms and the app's public terms/privacy notice for destination,
  location and SDK data sent to Google. App terms must explain the Google Maps
  features and link the [Google Maps additional terms](https://maps.google.com/help/terms_maps/)
  and [Google Privacy Policy](https://policies.google.com/privacy). Preserve all
  attribution, SDK first-use terms/driver-awareness flow and access to SDK
  open-source licenses. Do not obscure navigation UI or required disclaimers.
- Google supplies SDK privacy manifests. Generate and inspect Xcode's
  **aggregate privacy report for the actual archive**, including both SDKs.
  Reconcile the app manifest, public privacy policy and App Store Connect answers
  with actual behavior; pre-SDK declarations are not proof no update is needed.
- Re-evaluate Apple's export-compliance answers for the new binaries. This
  integration does not establish an encryption exemption for SDK 11.2.0. Its
  notices include BoringSSL, which alone does not determine exemption. A previous
  app's `ITSAppUsesNonExemptEncryption=false` declaration is not evidence for the
  changed binary. The existing pilot declaration is retained, not newly certified
  by this change. Review SDK/vendor information, distribution territories
  (including any applicable France requirements), and the actual archive before
  upload; do not infer a legal classification from dependency names. The bundle
  verifier checks the declared value, not its legal correctness.
- Verify destination provenance, API restrictions, billing/quotas and the
  physical-device checks below. No-key simulator CI does not verify a live-key
  Google-enabled release.

References: [Google Maps Platform Terms §3.2.2](https://cloud.google.com/maps-platform/terms),
[Navigation policies](https://developers.google.com/maps/documentation/navigation/ios-sdk/policies),
[Google's Apple privacy guidance](https://developers.google.com/maps/documentation/navigation/ios-sdk/apple-privacy-policy),
[Apple export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).

## Acceptance checks

Offline configuration/safety tests:

```sh
python3 -m unittest discover -s scripts -p 'test_navigation_config.py'
python3 -m unittest discover -s scripts -p 'test_testflight_ci.py'
```

The TestFlight tests use synthetic files and fake Apple tools. They verify
private injection, absence of keys from arguments/output, empty-key support and
cleanup, not real signing, Google authorization or paid routing.

Run the full native unit/UI suite and unsigned Release build on macOS for the
final commit. Then use a physical iPhone and a permitted test destination, with a
passenger/tester operating the UI safely:

1. Missing/invalid/restricted key, unknown/Apple-derived destination, denied
   location, reduced precision, declined Google terms and motion permission.
   Check readable Italian outcomes, retry/close, and no unintended server writes
   or external Maps launch.
2. Fresh GPS fix, route calculation, map following, Italian voice, mute/unmute,
   volume and Bluetooth/audio interruptions. Check visible attribution/legal
   text and that app controls do not obscure SDK UI.
3. A safe off-route detour/reroute; no route, poor network, recovery and waiting
   for GPS. Retrying must not leave overlapping sessions or unnecessarily repeat
   destination requests.
4. Background/lock with opt-in off/on; foreground resume, disabling opt-in,
   low-power mode and permission revocation. Observe actual GPS indicators,
   voice, stopped sessions and battery behavior.
5. Repeated open/close, cancel during permission/terms/routing, logout,
   account/view switch, end shift and a changed next stop. Stale callbacks must
   not revive guidance for an old account or destination.
6. Arrival must not complete a pickup/delivery. The driver explicitly confirms
   the allowed action; the next trip uses the new first stop. Google traffic/ETA
   must not be presented as the Rust planner's ETA.

Physical-device, live-key, billing, privacy and export checks remain deployment
gates until recorded for the actual release candidate.
