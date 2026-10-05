# Team-scoped driver invitations and account deletion

This change prepares a separate app/API rollout. It does not deploy the API, upload a new app build, change the existing TestFlight build, create live invitations, or grant Apple beta access.

## Account deletion

An invited driver can open **Elimina account**, review the linked-delivery count (including active deliveries), enter their current password and explicitly confirm irreversible deletion. A canceled dialog sends no deletion request. This is immediate hard deletion, not a delayed workflow or deactivation. If an assignment, readiness or delivery status changes after the preview, the server rejects the old confirmation and requires a fresh review.

The confirmed transaction removes the invited account and password hash, its driver/profile/location row, every session, its immutable identity binding, all deliveries currently assigned to that driver (including completed and picked-up deliveries), related route stops on every affected route, and cached idempotency responses that reference the removed account/deliveries. Team-owned restaurants, other drivers, other teams and unrelated deliveries remain. The schema does not track delivery creators; deletion does not invent creator ownership or erase unrelated team records. Deleting an active delivery does not notify a restaurant/customer or recover a physical order: the confirmation warns that those deliveries will disappear.

For surviving dispatchers' affected requests, only a one-way hash of their team/account/request-key tuple remains as an anti-replay reservation. It contains no deleted account/delivery IDs, request or response payload. The old response row is removed; replay returns a conflict instead of recreating a deleted order. Deleted-account request rows are removed outright because all of that account's sessions are revoked.

Self-service deletion is available only to durable invite-created accounts. Operator-configured accounts remain in the separate protected auth file and cannot honestly be erased by this endpoint; the API rejects that operation and the app does not present the self-delete action for them. This does not claim that ending a session deletes an operator-managed identity.

This implementation provides an in-app deletion path for accounts created by the invite flow, following [Apple's account-deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/). It is not an assurance of App Review acceptance or legal compliance. The existing manual disable command is a separate recovery tool and intentionally retains history.

Confirmed deletion also clears that team’s temporary Google Places coordinate and failure caches. In-flight results and refresh snapshots from before deletion cannot repopulate them. This does not erase shared restaurant or other delivery records; their locations are resolved again when needed. Other teams’ caches are unchanged.

Deletion removes records from the active database, not every historical copy or storage byte. Backups, SQLite WAL/free pages, previously exported data and other devices' cached displays are not remotely purged. Restoring an older backup can restore deleted data; the operator must reconcile deletions before reopening a restored service. This feature does not introduce an automatic backup-retention or forensic-erasure system.

## Smallest operator flow

1. An account with dispatcher capability opens the invitation action in Centrale, enters the driver's display name, and creates a driver invitation for its own displayed Squadra
2. Share the resulting link privately using the iPhone share sheet. Anyone holding the link can claim this single-use invitation; confirm the recipient before sending. It expires after 24 hours. The displayed invitation can also be revoked before use
3. The recipient installs an invitation-capable Arrivau build through the separately authorized TestFlight process. They open the link, or choose “Hai un invito?” and paste the whole link or its 64-character code
4. They verify the configured HTTPS server and choose their lowercase username and private password (at least 12 UTF-8 bytes). The account opens as a driver, off shift. Starting a shift/location sharing remains a separate explicit action

The shareable format is `arrivau://invite?token=<64 lowercase hex>`. It is a custom app scheme, not a universal HTTPS link: some messaging apps do not make it tappable, and iOS cannot reserve the scheme exclusively to this app. Use the copy/paste fallback if needed and share only in a trusted channel. There is no website landing page, email integration or associated-domain requirement. Links cannot configure a server or send credentials to a URL embedded in the invite. Use the operator's independently verified HTTPS origin; invitations work only against their issuing API/database.

No account can select its team or capabilities at signup. The API fixes invited accounts to driver-only in the issuer's team; an issuer with both capabilities can invite from Centrale, but cannot issue a dual-role invitation. Dispatcher/dual-role accounts still require the operator-managed configuration. Existing configured dual-role accounts keep both capabilities and their view switch. Receiving a link while already signed in does not silently change accounts. Canceling signup does not invalidate the invitation unless it has already been submitted/consumed.

## Deployment and existing pilot safety

Back up the current persistent SQLite database (using the runbook's consistent backup procedure) and auth configuration before an intentional upgrade. Run the final commit's backend and native CI. Deploy the new API first, then distribute the new app, with explicit owner approval for each operational action. Older apps still use unchanged login/session and delivery contracts; new invitation actions require the new API.

Schema v5 is additive: `invited_accounts`, `invites` and minimal anti-replay tables/indexes are created if absent. While an invited identity exists, it has an immutable `account_teams` binding; database triggers prevent relabeling invites, accounts or sessions across teams. Schema v5 prevents older binaries from ignoring the deletion anti-replay reservations and resurrecting erased orders. Configured identities/password hashes stay in the existing auth file; invited identities, salted password hashes and disabled status stay in the persistent database. No new credentials or invitation secrets are seeded. Existing driver, session, route and delivery records are retained. Do not replace or clear the deployed database, migrate from a demo DB, or add invited identities to the auth configuration.

Startup fails closed if a configured account ID/username collides with an invited identity, including a disabled identity. Resolve the conflicting configuration; do not delete either person's history. Unchanged invited accounts and their sessions survive restart; removing a configured account still invalidates that account's sessions as before. Changing/removing the issuing configured account or its dispatcher capability permanently invalidates unconsumed invitations on restart; restoring the previous config does not resurrect those secrets. Invited accounts already created remain members of their original team. Removing that team from configuration disables their login and clears their sessions; re-adding the same team permits a new login without moving any history.

Earlier binaries, including the invite-only draft, reject schema v5 rather than silently invalidating invited users or interpreting their data incorrectly. Plan an outage and compatible backup recovery rather than silently downgrading an active pilot. Any database restore must account for deliveries created after its snapshot. Keep SQLite private and backed up because it now also owns invited password hashes.

## Lost responses and retry

A submit may commit even if the phone loses its connection, the app closes, or session storage fails. The app does not automatically replay uncertain redemption. Return to normal login and use the same chosen username/password on the same server. If login fails, contact the dispatcher/operator before requesting another invite. Expired, revoked and consumed codes all show a generic invalid-invite result; the server never reveals the previous recipient.

A known username collision leaves the invitation usable with a different username. A successful signup consumes it forever. Issuance is not idempotent: if its response is lost, the undisclosed invitation expires automatically; issuing another can create a second pending invite. Do not repeatedly tap creation. The server caps issuance and pending invites. A displayed UUID can revoke a pending invite within the same team without placing its secret in an HTTP path; a dispatcher in another team cannot revoke it. Names/usernames never select a team. Usernames remain globally unique because login does not ask for a team. At most 100 invited accounts (including disabled identities) and 100 pending invitations are allowed per team. Issuance is limited to 20 attempts per dispatcher/hour; redemption has global/token/username limits and shares the existing two-worker password-hashing bound. Ingress rate limits still apply. The displayed UUID can revoke a pending invite; there is no broad administration dashboard in this change.

## Disable an invited account

Use the operator tool for emergency revocation, a lost phone or a departed driver. Resolve/reassign outstanding work first when possible. Disabling stops access immediately, sets the driver off shift and revokes sessions while preserving driver/job/route history. Picked-up work may need human recovery; the tool does not finish, cancel or reassign deliveries.

After a consistent backup, preferably stop the API briefly and run as the same database owner:

```sh
cargo run --release --locked --manifest-path api/Cargo.toml \
  --bin arrivau-disable-invited-account -- /absolute/private/pilot.sqlite3 lowercase-username
```

The container image also includes `/usr/local/bin/arrivau-disable-invited-account`. It opens an existing production database only, uses the exact lowercase username, and never handles a password. Repeating disabling is safe. Configured users remain managed in the auth file; this tool rejects those names. Restart the API when finished. Disabled usernames remain reserved; there is no self-service reset/reactivation or credential migration in this small flow. For a replacement identity, choose a new username and preserve old work records.

## Verification before real invitations

- With disposable fixtures, configured dispatcher/driver/dual-role login remains valid across upgrade; invited signup and normal login survive restart with immutable team membership
- No bearer, a driver bearer, demo mode, extra role/id fields, malformed/revoked/expired codes and replay cannot create privileged accounts
- Concurrent redemption creates one account; username conflicts do not consume the code; the server controls name, driver-only capability and team
- A review-team invitation never grants live-team access; foreign-team revocation, supplied team/roles, ID guessing and cross-team delivery mutations cannot bypass the boundary
- Cancellation, repeated submission, logout and late network responses cannot install a stale session; lost responses explain normal-login recovery
- Exercise link opening and pasted-code fallback on the signed device build, with the exact deployment origin; test cancel/back and opening a link while signed in
- Verify external TestFlight access separately. A working Arrivau invitation is not an Apple testing invitation

## Deletion checks

- Wrong password, missing/stale confirmation and cancel leave all data intact
- Only the authenticated invited account can delete itself; supplied user/team IDs and configured/demo accounts cannot widen the action
- Total/active counts match the same team-bound snapshot consumed in the transaction
- Completed, assigned and picked-up linked deliveries are removed consistently, with no dangling route stops or cached response resurrecting them
- Assignment, readiness, pickup and automatic dispatch races either commit before the reviewed deletion or fail safely; unrelated team data stays intact
- After success, sessions/GPS/private views clear; lost responses are reported as uncertain and are never automatically retried

