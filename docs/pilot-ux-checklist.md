# Pilot screenshot feedback: acceptance checklist

One PR covers the complete screenshot-feedback pass. The required native suite
exports the following synthetic-data screenshots; inspect the actual PNGs from
the candidate commit before merging. Reference phone screenshots are not
published or committed.

| Feedback | Implementation / verification |
| --- | --- |
| Login has too much explanatory copy | `ux-pilot-login`: Arrivau, username, password, Accedi, secondary invite entry and privacy access |
| Invitation competes with sign-in | `ux-invite-entry`: separate entry form; invalid link, cancel, reopen and signup interruption tests preserve the login context |
| Server configuration should not be routine | Pilot login/signup have no server input; HTTPS build setting remains authoritative; Debug override needs `--developer-settings`; local demo remains available |
| Profile icon unexpectedly signs out | `ux-account`: profile opens Account; explicit Esci, eligible deletion and privacy actions; opening/closing and interruption do not sign out |
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
- Full native unit/UI suite, including repeated role switches, active assignments,
  stop/resume, account dismissal, canceled logout, invite entry/signup cancellation,
  invalid links, HTTPS validation, repeated route expansion and interruptions
- All required named screenshot exports, then actual image inspection

Ordinary CI runs the full native suite once. The previously temporary duplicate
focused login probe is no longer run first; its manual script option and failure
diagnostics remain available. No required checks are skipped.

## Physical-device release checks

Simulator fixtures prove layout and app state transitions, not live Google tiles,
GPS or background reliability. On the next signed build, verify real Google
search/guidance, locked-screen location, denied/revoked permissions, poor network,
foreground-only opt-out, stop/end/logout, force-quit recovery and large Dynamic
Type. Deploy the matching one-sentence privacy correction before distributing
the changed consent flow. This PR does not deploy or upload a TestFlight build.
