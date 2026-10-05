# Pilot screenshot feedback: acceptance checklist

One PR covers the complete screenshot-feedback pass. Automatic CI runs all native
unit tests and two concise UI smoke cases, exporting nine representative screens.
The detailed UI journeys and their additional screenshots remain available
manually. Inspect the actual candidate PNGs before merging. Reference phone screenshots are not
published or committed.

| Feedback | Implementation / verification |
| --- | --- |
| Login has too much explanatory copy | `ux-pilot-login`: Arrivau, username, password, Accedi, secondary invite entry and privacy access |
| Invitation competes with sign-in | `ux-invite-entry`: separate entry form; invalid link, cancel, reopen and signup interruption tests preserve the login context |
| Server configuration should not be routine | Pilot login/signup have no server input; HTTPS build setting remains authoritative; Debug override needs `--developer-settings`; local demo remains available |
| Profile icon unexpectedly signs out | `ux-account`: profile opens Account; explicit Esci, eligible deletion and privacy actions; opening/closing and interruption do not sign out; active-shift exit uses an explicit Cancel/Esci alert |
| Signout during a shift must be understandable | `ux-active-logout`: active-shift logout confirmation explains that local sharing stops while the server shift and deliveries remain; cancellation preserves the current assignment |
| Shift and sharing screens repeat technical explanations | `ux-new-shift`, `04-driver-shift`: concise status, immediate sharing control, screen-lock choice, latest position and end-shift action |
| Screen-locked sharing should work by default during an explicitly started shift | Start disclosure and iOS permission cover it; unit/UI tests require both sharing flags after new start. Restored, resumed or previously foreground-only choices never gain background consent automatically |
| Driver home buries the map and next action | `03-driver-route`, `dual-account-corriere`: visible overview, compact next stop/timing, one pickup/dropoff action, expandable remaining stops |
| Empty driver home should be simpler | `ux-driver-waiting`: short waiting state with shift controls; no repeated operational paragraphs |
| Warnings are duplicated and overwhelming | Compact approximation, late/stale-GPS and failure notices remain actionable; detailed route warnings are expandable, with source attribution retained |
| Cleanup should apply throughout the app | Shorter dispatcher, invite, address-selection and recovery copy; destructive deletion, privacy and uncertain-response warnings remain explicit |
| Keep the working Google integration | Existing next-stop navigation and return/arrival tests remain; source restrictions and Google attribution are unchanged |

## Required automated checks

- Full Rust format, lint, unit, real HTTP, script and deployment-image checks
- Unsigned Release archive and app-only signing checks
- Every native unit test
- Two UI smoke cases: minimal pilot login/invite entry; real dual-account role,
  shift, active logout cancel/confirm, next-stop pickup/delivery and shift end
- Nine smoke screenshots, including the start disclosure and logout alert

The smoke fixture seeds one delivery through the existing loopback-only demo API,
using its locally resolved Google Place IDs. Role, shift, logout, pickup and
completion remain actual UI actions with real server-state assertions. The known
logout interaction is not removed or bypassed by this split.

For the longer restaurant/address, repeated navigation, interruption and invite
journeys, run `./scripts/test-ios.sh --full` on a Mac with a fresh demo database,
or select **full** in the verification workflow's manual **UI coverage to run**
input. `--smoke` is the automatic CI selection. The no-argument local command
still runs full coverage; the optional `--diagnose-login-first` remains manual.
No new recurring automation or TestFlight upload is added.

On the last detailed run, 244 unit tests took 7.5 seconds and nine UI cases took
15 minutes 18 seconds (including two early-stopped logout cases). These are
observed test-execution times, excluding runner queueing and builds; smoke runtime
must be measured by its own CI run.

## Physical-device release checks

Simulator fixtures prove layout and app state transitions, not live Google tiles,
GPS or background reliability. On the next signed build, verify real Google
search/guidance, locked-screen location, denied/revoked permissions, poor network,
foreground-only opt-out, stop/end/logout, force-quit recovery and large Dynamic
Type. Deploy the matching one-sentence privacy correction before distributing
the changed consent flow. This PR does not deploy or upload a TestFlight build.
