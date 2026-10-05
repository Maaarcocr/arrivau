# In-app Google navigation

Google Places supplies new destination selection; Google Navigation supplies in-app guidance. Real use requires the two configured keys and device checks below. Existing Apple-selected addresses are never relabelled automatically.

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
- `https://github.com/googlemaps/ios-places-sdk`, product `GooglePlaces`, exact **11.2.0**

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

1. In the Google Cloud project, confirm the billing account's payments-profile
   country and applicable EEA/non-EEA Maps terms. Enable billing and **Navigation
   SDK**, **Maps SDK for iOS**, and **Places API (New)**. Set budget alerts and
   appropriate API quotas; alerts alone do not cap charges.
2. Create an **iOS-only key**, restricted to the exact signed bundle ID
   (`com.rudilosso.arrivau` for the current pilot; `dev.arrivau.app` only for
   default development builds). Restrict its APIs to the three above. Store it
   as repository secret **ARRIVAU_GOOGLE_MAPS_API_KEY** for the existing manual
   archive workflow, or provide it privately to the local build helper below.
3. Create a **separate server key**, restricted to **Places API (New)** and the
   server's verified public outbound IP addresses. Set runtime environment
   **ARRIVAU_GOOGLE_PLACES_SERVER_KEY** on the API server. Do not assume an inbound
   host IP is the outbound IP. Never use the iOS key on the server or embed the
   server key in the app. The server uses HTTPS only with redirects disabled.
4. Use a coordinated maintenance window. Finish outstanding legacy deliveries,
   stop new restaurant/order creation and restrict API access, then take a
   consistent database/configuration backup using the pilot runbook. Deploy the
   new API first while access remains restricted, install the matching new iOS
   build on **every** pilot phone, configure both Google keys, and verify the
   complete flow with synthetic work. Only then reopen access and resume work.
   Freshly select legacy locations using original customer records; old saved
   restaurants remain visible but cannot silently become Google places.
   **Mixed versions are unsupported:** the old server rejects the new IDs and
   omitted coordinates; the old iOS model cannot decode null Google coordinates
   from the new server. This release has no minimum-client-version enforcement,
   so the operator must verify all pilot devices before resuming. Existing legacy
   reads/completion are not a promise that new creation works across versions.
   Schema version 6 blocks binary downgrade. Restore the verified pre-upgrade
   backup only before new writes resume; restoring it afterward would lose work
   and requires an explicit data-recovery plan.
5. Complete the actual signed-iPhone checks below, privacy disclosures and
   release classification review before distributing. The scripts do not upload
   or deploy automatically; a PR merge is not a live rollout.

No keys should be pasted into chat, tracked source, issues, command arguments,
logs or screenshots. API key creation and billing setup are owner-managed steps.

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

Do not pass `INFOPLIST_FILE`, the app bundle ID or provisioning settings globally
to `xcodebuild`: they also affect Google SDK resource targets.

For a local Debug build or Xcode Run, select the **Arrivau application target**, Build Settings →
Packaging → Info.plist File, and set the Debug value to
`Config/Navigation.local/Info-Debug.plist`. This changes only the ignored
generated project; XcodeGen regeneration resets it. Do not apply the override to
test or SDK resource targets. Build the resulting project normally without a
global plist override. Regenerate private configuration after tracked template changes.
Delete it when no longer needed; build products also contain the key.

`scripts/archive-ios.sh` reads the optional environment variable, generates a
temporary Release Info.plist, removes the key from Xcode's environment and
generates a private XcodeGen overlay containing **Arrivau-target-only** Release
settings. Signing and plist overrides never apply to SDK or test targets. An
exit/signal trap deletes the temporary configuration and generated project.
It still validates the owner's pilot settings and **does not upload**. The
resulting archive remains on the owner's machine.

Manual TestFlight does the same inside its private temporary directory; existing
cleanup removes configuration, signing files and build products. Archive mode
allows an unset key and produces a build with navigation unavailable; **upload
mode requires a configured iOS key**. The fixed configured/missing status checks
presence only, not API restrictions, billing, key validity or the server key.
No push or PR triggers that workflow. Its main-only signing opt-in and separately selected upload action
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

New autocomplete results are displayed transiently with Google attribution.
The selected Place ID is durable; the label/address saved by Arrivau is the
original user-entered text, not Google's formatted prediction. The client makes
an Essentials ID/coordinate Details request to terminate the autocomplete
session and discards its coordinates. The server independently resolves the ID
using its own key and an ID/location-only field mask. The first uncached
selection therefore makes two Details requests; cached server results avoid
subsequent duplicate resolution.

The server's bounded SQLite TEMP cache uses memory only, expires at 29 days
(with a guard band below Google's 30-day maximum), and is emptied on restart.
Google coordinates are stripped from durable jobs, restaurants, idempotency
snapshots and completed history. OSRM queries containing Google destinations use
request-local caches instead of persistent matrix/snap caches. Provider failure
keeps ordered stops, returns missing coordinates, hides timing and blocks unsafe
assignment; it never replaces a location with a guessed point. Google guidance
uses only the server's first stop Place ID, so it can still calculate its own
route when the scheduler's coordinate cache is unavailable.

New Google points use Google overview maps. Old Apple-only records retain their
existing Apple map; mixed-source routes show the ordered list without combining
map content. No OSRM route geometry is drawn on the Google navigation map.
Google place IDs may be retained; other content has additional restrictions.
Review applicable [EEA guidance](https://developers.google.com/maps/comms/eea/places)
and [Places policies](https://developers.google.com/maps/documentation/places/ios-sdk/policies).

Current list-price baseline (USD, before applicable taxes, checked 2026-10-05):
Autocomplete Requests: 10,000/month free, then $2.83/1,000 at the first paid tier;
Place Details Essentials: 10,000/month free, then $5/1,000; Navigation: 1,000
requested destinations/month free, then $25/1,000. Native Maps SDK is listed
with unlimited free usage. Autocomplete session billing, account agreements,
volume and the two-Details first-selection behavior affect actual totals. See
[Google pricing](https://developers.google.com/maps/billing-and-pricing/pricing).

Before distributing a Google-enabled pilot or App Store build:

- Review Google terms and the app's public terms/privacy notice for destination,
  location and SDK data sent to Google. App terms must explain the Google Maps
  features and link the [Google Maps additional terms](https://maps.google.com/help/terms_maps/)
  and [Google Privacy Policy](https://policies.google.com/privacy). Preserve all
  attribution, SDK first-use terms/driver-awareness flow and access to SDK
  open-source licenses. Do not obscure navigation UI or required disclaimers.
- Google supplies SDK privacy manifests. The manual workflow validates the
  actual signed archive and exported IPA against the reviewed 11.2.0 declarations
  and retains only a sanitized JSON summary with manifest hashes and declared
  categories/reasons. Missing, changed or inconsistent manifests block upload.
  This is a declaration audit, not Apple's aggregate report or a runtime/privacy
  certification. Where Xcode Organizer is available, also generate and inspect
  its **Privacy Report** for the actual archive. Reconcile the app manifest, public privacy policy and App Store Connect answers
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
private injection, app-target scoping, absence of keys from arguments/output,
archive-only empty-key support, missing-key upload rejection, manifest audit
gates and cleanup. They do not validate real signing, Google authorization or
paid routing. CI additionally archives the real app with synthetic configuration
and verifies that Google resources contain none of the app's private settings.

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
