# Team-scoped invitations and account deletion

This change prepares a separate app/API rollout. It does not deploy the API, upload a new app build, change the existing TestFlight build, create live invitations, or grant Apple beta access.

## Account deletion

An invite-created account can open **Elimina account**, review the linked-delivery count (including active deliveries), enter their current password and explicitly confirm irreversible deletion. A canceled dialog sends no deletion request. This is immediate hard deletion, not a delayed workflow or deactivation. If an assignment, readiness or delivery status changes after the preview, the server rejects the old confirmation and requires a fresh review.

The confirmed transaction removes the invited account and password hash, its driver/profile/location row, every session, its immutable identity binding, all deliveries currently assigned to that driver (including completed and picked-up deliveries), related route stops on every affected route, and cached idempotency responses that reference the removed account/deliveries. Team-owned restaurants, other drivers, other teams and unrelated deliveries remain. The schema does not track delivery creators; deletion does not invent creator ownership or erase unrelated team records. Deleting an active delivery does not notify a restaurant/customer or recover a physical order: the confirmation warns that those deliveries will disappear.

For surviving dispatchers' affected requests, only a one-way hash of their team/account/request-key tuple remains as an anti-replay reservation. It contains no deleted account/delivery IDs, request or response payload. The old response row is removed; replay returns a conflict instead of recreating a deleted order. Deleted-account request rows are removed outright because all of that account's sessions are revoked.

Self-service deletion is available only to durable invite-created accounts. Operator-configured accounts remain in the separate protected auth file and cannot honestly be erased by this endpoint; the API rejects that operation and the app does not present the self-delete action for them. This does not claim that ending a session deletes an operator-managed identity.

This implementation provides an in-app deletion path for accounts created by the invite flow, following [Apple's account-deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/). It is not an assurance of App Review acceptance or legal compliance. The existing manual disable command is a separate recovery tool and intentionally retains history.

Confirmed deletion also clears that team’s temporary Google Places coordinate and failure caches. In-flight results and refresh snapshots from before deletion cannot repopulate them. This does not erase shared restaurant or other delivery records; their locations are resolved again when needed. Other teams’ caches are unchanged.

Deletion removes records from the active database, not every historical copy or storage byte. Backups, SQLite WAL/free pages, previously exported data and other devices' cached displays are not remotely purged. Restoring an older backup can restore deleted data; the operator must reconcile deletions before reopening a restored service. This feature does not introduce an automatic backup-retention or forensic-erasure system.

## Smallest operator flow

1. A trusted operator provisions a single-use invitation in the intended production database with an explicit configured team, display name, `driver` or `dispatcher` role, expiry and a hash of a cryptographically random secret. Issuance is outside the HTTP API; the former in-app create/revoke endpoints are no longer available
2. Share the link privately with the intended recipient. Anyone holding the secret can claim the invitation until it expires or is removed by the operator. Verify the recipient and role before sharing
3. The recipient installs an invitation-capable Arrivau build through the separately authorized TestFlight process. They open the link, or choose “Hai un invito?” and paste the whole link or its 64-character code
4. They verify the configured HTTPS server and choose their lowercase username and private password (at least 12 UTF-8 bytes). The account opens with the invitation's saved role, off shift. Starting a shift/location sharing remains a separate explicit action

The shareable format is `arrivau://invite?token=<64 lowercase hex>`. It is a custom app scheme, not a universal HTTPS link: some messaging apps do not make it tappable, and iOS cannot reserve the scheme exclusively to this app. Use the copy/paste fallback if needed and share only in a trusted channel. There is no website landing page, email integration or associated-domain requirement. Links cannot configure a server or send credentials to a URL embedded in the invite. Use the operator's independently verified HTTPS origin; invitations work only against their issuing API/database.

No account can select its team or capabilities at signup. The API takes them only from the stored invitation. A dispatcher has both `dispatcher` and `driver` capabilities, with `dispatcher` as the primary role; a driver invitation remains driver-only. The same role and capabilities are returned by signup, authenticated session lookup and normal login, including after restart. Existing configured dual-role accounts keep their view switch. Receiving a link while already signed in does not silently change accounts. Canceling signup does not invalidate the invitation unless it has already been submitted/consumed.

## Deployment and existing pilot safety

Back up the current persistent SQLite database (using the runbook's consistent backup procedure) and auth configuration before an intentional upgrade. Run the final commit's backend and native CI. Deploy the new API first, then distribute the new app, with explicit owner approval for each operational action. Older apps still use unchanged login/session and delivery contracts; new invitation actions require the new API.

Schema v7 adds a constrained `role` column to `invited_accounts`. New redemptions save the invitation's role in the same transaction as the identity, profile, consumed invitation and session. Existing role-aware unused invitations retain their exact rows across upgrade and every subsequent restart. Configured identities/password hashes stay in the auth file; invited identities, salted password hashes, roles and disabled status stay in the database. Immutable account/team bindings and the prior deletion anti-replay and Google-coordinate protections remain. No new credentials or invitation secrets are seeded. Do not replace or clear the deployed database, migrate from a demo DB, or add invited identities to the auth configuration.

Older account rows have no durable record of the redeemed invitation's role. Migration assigns `driver`, the safe historical default. In particular, an affected dispatcher account already created by the broken role-aware release cannot be automatically repaired: the invitation was consumed and no authoritative role was saved. A username, display name, driver profile or old session is not proof of dispatcher authorization. A verified operator must explicitly approve any correction to that specific account after checking its intended team and privileges, preserve its identity/history, and revoke its old sessions. This change performs no production correction and includes no automatic upgrade to dispatcher.

For the older issuer-bound invitation schema, startup atomically preserves every existing row in the inert `legacy_invites_v7` archive, including its issuer and fingerprint, then creates the active role-aware table. Archived secrets are never redeemable. Their original issuer restrictions cannot be silently removed; a verified operator must separately review and issue any replacement invitation. Consumed/revoked rows are not recreated. Unrecognized invitation schemas, or missing role/invitation metadata in a v7 database, fail closed without committing a partial migration.

Startup fails closed if a configured account ID/username collides with an invited identity, including a disabled identity. Resolve the conflicting configuration; do not delete either person's history. Unchanged role-aware invited accounts and their sessions survive restart. Changing an account's effective capabilities or removing a configured account invalidates its sessions. In particular, an older dispatcher-only session must be replaced by normal login when upgrading to dispatcher-plus-driver semantics; unchanged driver sessions remain valid.

Current operator-provisioned invitations have no issuer account dependency. Redemption rejects an unconfigured team without consuming its invitation or creating an account. Removing a team from configuration also disables its invited accounts and clears their sessions at restart. Re-adding the same team permits a new login without moving history; a still-unused, unexpired role-aware invitation for that team becomes eligible again.

Earlier binaries reject schema v7 instead of reloading dispatchers as drivers or deleting unused invitations. Never manually lower `user_version`. Plan an outage and compatible backup recovery rather than silently downgrading an active pilot. Any database restore must account for deliveries created and accounts deleted after its snapshot. Keep SQLite private and backed up because it owns invited password hashes and any archived invitation metadata.

## Lost responses and retry

A submit may commit even if the phone loses its connection, the app closes, or session storage fails. The app does not automatically replay uncertain redemption. Return to normal login and use the same chosen username/password on the same server. If login fails, contact the dispatcher/operator before requesting another invite. Expired, revoked and consumed codes all show a generic invalid-invite result; the server never reveals the previous recipient.

A known username collision leaves the invitation usable with a different username. A successful signup consumes it forever. Names/usernames never select a team. Usernames remain globally unique because login does not ask for a team. At most 100 invited accounts (including disabled identities) are allowed per team. Redemption has global/token/username limits and shares the existing two-worker password-hashing bound. Ingress rate limits still apply. Issuance and revocation are operator responsibilities; this API does not provide an invitation administration dashboard or issue/revoke endpoints.

## Disable an invited account

Use the operator tool for emergency revocation, a lost phone or a departed driver. Resolve/reassign outstanding work first when possible. Disabling stops access immediately, sets the driver off shift and revokes sessions while preserving driver/job/route history. Picked-up work may need human recovery; the tool does not finish, cancel or reassign deliveries.

After a consistent backup, preferably stop the API briefly and run as the same database owner:

```sh
cargo run --release --locked --manifest-path api/Cargo.toml \
  --bin arrivau-disable-invited-account -- /absolute/private/pilot.sqlite3 lowercase-username
```

The container image also includes `/usr/local/bin/arrivau-disable-invited-account`. It opens an existing production database only, uses the exact lowercase username, and never handles a password. Repeating disabling is safe. Configured users remain managed in the auth file; this tool rejects those names. Restart the API when finished. Disabled usernames remain reserved; there is no self-service reset/reactivation or credential migration in this small flow. For a replacement identity, choose a new username and preserve old work records.

## Verification before real invitations

- With disposable fixtures, configured driver/dispatcher/dual-role login succeeds; unchanged driver sessions survive upgrade, while sessions gaining capabilities require normal login
- Both driver and dispatcher signup support an immediate authenticated request, normal login and restart with their original team and saved role
- Unused role-aware invitations survive v6-to-v7 upgrade and repeated restarts; legacy issuer-bound rows remain archived and inert; role-less accounts never gain inferred dispatcher privileges
- The possession of a valid operator-provisioned invite is required for signup; demo mode, extra role/id/team fields, malformed/removed/expired codes and replay cannot create accounts
- Concurrent redemption creates one account; username conflicts do not consume the code; the stored invitation controls name, role and team
- A review-team invitation never grants live-team access; supplied team/roles, ID guessing and cross-team delivery mutations cannot bypass the boundary
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

