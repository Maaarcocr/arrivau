# Teams, dual-role accounts and App Review

## Boundary and terminology

A **team** (shown as **Squadra** in Italian) is the private workspace for dispatchers,
drivers, deliveries, routes and current driver positions. An account belongs to
exactly one team. A person can have both `dispatcher` and `driver` capabilities in
that team. No account can browse or administer other teams through the API.

Teams are provisioned by the operator in the existing private account configuration.
There is no public signup, team switcher, organization billing or team-management
screen. Future invitation signup must take the team from a server-issued invitation,
never from a registrant's freely selected team ID. Invitation/account-deletion work
is separate from this change.

Keep the real pilot and App Review in different teams. A dual-role review account
gets a driver profile with its own account ID, so one person can start a shift,
create a delivery, assign it to themselves, and complete both stops. The view
switch changes the current screen, not the account or its server permissions.

## Operator configuration

Keep `fleet_id` unchanged: it identifies the deployment and its original team.
Old account configurations continue to work, with their original single roles and
all accounts in the team whose ID equals `fleet_id`. Extended configurations list
teams and explicitly assign any additional team's accounts:

```json
{
  "fleet_id": "existing-pilot-id",
  "session_ttl_seconds": 43200,
  "teams": [
    { "id": "existing-pilot-id", "name": "Squadra pilota" },
    { "id": "apple-review", "name": "App Review" }
  ],
  "accounts": [
    {
      "id": "existing-dispatcher-id",
      "username": "existing-dispatcher-login",
      "name": "Existing dispatcher",
      "role": "dispatcher",
      "password_hash": "KEEP_EXISTING_PRIVATE_HASH"
    },
    {
      "id": "review-operator",
      "username": "review-operator",
      "name": "App Review",
      "team_id": "apple-review",
      "roles": ["dispatcher", "driver"],
      "password_hash": "REPLACE_WITH_NEW_PRIVATE_ARGON2ID_HASH"
    }
  ]
}
```

This is an intentionally invalid illustrative fragment, not a ready-to-install
account file. Retain **every** existing pilot account and its stable ID, username,
name, role and password hash. Generate the new review account's password privately
with the documented operator helper; never use any password or hash from tests,
chat, source code or a public example. Account IDs and usernames are deployment-wide
unique; they are not recycled between people or teams.

`roles` grants only `dispatcher`, `driver`, or both. The compatible `role` field
remains the primary/default view; if omitted, a dual account defaults to dispatcher.
The server decides capabilities and membership. Clients cannot gain permissions by
changing a view, a response cache or a team ID in a request.

## Existing-pilot migration and release order

1. Record the currently installed API/app versions. Schedule a short maintenance
   window and finish or supervise outstanding work. Stop the single API process;
   take a consistent protected backup of the SQLite database and any WAL/SHM files,
   plus its matching operator configuration. Verify restore on an isolated path.
2. Keep the existing `fleet_id` and database path. Start the new API first using
   the **unchanged** old account configuration. The additive migration puts all
   legacy drivers, deliveries, route stops and retry records in that original
   team, preserving IDs, route order, status, location and timestamps.
3. Verify legacy accounts with the existing TestFlight app: login/session restore,
   lists, shifts, recent location, assignment and retry recovery. Added identity
   fields are backward-compatible JSON; `role` remains a recognized single role.
4. Add the `teams` list including the original `fleet_id` team and a distinct review
   team. Keep original accounts unchanged and append the new review account with
   its explicit team ID and both roles. Restart to apply configuration. No script
   here creates real accounts or seeds a production database.
5. Install the updated app for dual-role testing. It can also read an old API's
   single-role identity. Older apps continue to see only the dual account's primary
   role; use the updated app to exercise both capabilities.
6. Verify both directions of isolation using synthetic records. The pilot cannot
   see review drivers/jobs/routes/locations and App Review cannot see pilot records,
   including by guessing IDs, assignment targets or reusing retry keys. Restart
   once more and check persistence before distributing review credentials.

An existing account/driver ID cannot be silently moved into a different team. Use
new IDs for a new person/team; never repurpose an existing review account as a pilot
account. Removing an account or changing its capabilities invalidates its sessions
at restart; retained history remains in its original team. Resolve work before
removing a driver's capability. Team identity is included in durable retry scope.

### Uncertain delivery creation saved by an older app

The new app scopes recovery records to endpoint, team and account. If it finds an
older endpoint/account-only request after the server begins returning team identity,
it cannot safely prove which team that request belongs to. It preserves the original
request for inspection and blocks new creation/retry. Do not recreate that job.
Check the original server's delivery list with the responsible operator using the
shown addresses/reference, then use the app's explicit confirmation to remove only
that local recovery record when its outcome has been reconciled. This does not
cancel, delete or replay a server delivery. Canceling the confirmation leaves the
block intact; a storage error must leave the original recovery data intact.

**Do not run an old server binary against a team-enabled database.** Older binaries
do not enforce team isolation. Rollback requires stopping traffic and restoring a
matching pre-migration backup/configuration together with its compatible binary.
A restore discards post-backup changes, so reconcile outstanding work first. Do not
change the fleet marker, hand-edit team columns, delete the database, or overwrite
production records with demo/test fixtures as a migration workaround.

## One-person review walkthrough

Prepare a separately authorized review account in the App Review team. Give Apple
its credentials and the tested HTTPS endpoint through App Store Connect's private
review fields when submission is authorized. Do not post credentials in issues,
PRs, logs or these docs.

1. Sign in and confirm the **App Review** team label. Select **Corriere**.
2. Start the shift and explicitly allow foreground location sharing. Denying
   permission remains supported; automatic assignment can queue work without GPS,
   but the app must hide unavailable ETAs and show the position warning. Fresh
   real GPS is needed for meaningful timing comparisons. Do not use simulated GPS or public demo tokens in the
   Release app.
3. Select **Centrale**. Save a clearly labelled synthetic restaurant using a nearby
   real map-selected address, then create an order with a nearby destination and no
   real customer's personal information. Choose locations near the reviewer's current position,
   rather than assuming the reviewer is physically in Pachino.
4. Open the order and mark it Pronta ora. Verify automatic assignment to the
   review account's on-shift driver profile. If it remains pending, inspect the
   visible no-active-driver/capacity/route-limit reason. Also test future readiness
   with the app closed; assignment is performed by the server timer.
5. Select **Corriere**, confirm the next stop, record pickup after readiness, then
   delivery in route order. View switches do not automatically start GPS or end
   the shift. Previously authorized sharing continues while the shift is active;
   background sharing still needs its separate explicit consent.
6. Switch repeatedly while an active delivery exists, refresh, relaunch and restore
   the session. Relaunch requires explicit location-sharing consent again. Finish
   the delivery, end the shift and sign out; local GPS must stop immediately.
7. Check that the real pilot's records and positions have remained unaffected.

Review-team records are synthetic and isolated, but still persistent. Clear them
only under an authorized retention/recovery procedure; deleting rows casually can
break route history or retry guarantees. Team isolation is an application boundary
inside one operator-managed process/database. It is not separate hosting, separate
backups, resource quotas or a compliance certification. A busy review account can
still share process resources and global login rate limits with the pilot.

## Verification boundary

CI covers Rust/real HTTP isolation and migration tests, native app unit/UI tests,
and an unsigned Release build. Review the checks for the exact proposed commit.
Physical GPS, background tracking, the production migration/backup restore, App
Review account setup, signing/upload and Apple approval require their separate
authorized operator/device steps. This implementation does not deploy, merge,
create credentials, upload a TestFlight build or submit for review.
