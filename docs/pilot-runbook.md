# Supervised two-phone pilot

This branch prepares code for a **private teams, one server process, and dispatcher/driver capabilities (including dual-role accounts)**. It does not deploy a service, register an Apple account, install signing credentials, upload a build or enroll testers. Start with synthetic deliveries. A successful simulator run does not establish physical-device or TestFlight readiness.

## 1. Server prerequisites and boundaries

Choose a Linux host you manage, a domain with DNS pointing to it, a valid publicly trusted HTTPS certificate, a persistent local disk, and a backup destination. Use the same-host HTTPS reverse proxy pattern below, or the explicitly gated managed-host option. Expose only HTTPS (and port 80 if your certificate issuer needs it); the Rust API defaults to loopback. Do not enable port-forwarding to port 8080, use a shared/public HTTP proxy to the API, or put `ARRIVAU_DEMO=1` on this host. `ARRIVAU_TLS_PROXY=1` is an operator acknowledgement, not automatic TLS verification.

Build with the pinned toolchain, run the checks, and install the binary as `/opt/arrivau/arrivau-api`:

```sh
./scripts/check.sh
cargo build --release --locked --manifest-path api/Cargo.toml
```

Create a dedicated `arrivau` system user. Create `/var/lib/arrivau` owned by that user with mode `0700` and `/etc/arrivau` with mode `0750`. Keep the executable and service configuration root-owned. The deployment files are templates, not an automated installation:

- `deploy/arrivau.service`: systemd service, unprivileged execution, restrictive umask, restart on failure and write access only to the data directory
- `deploy/pilot.env.example`: production mode, absolute database path, auth-config path and explicit trusted TLS-proxy acknowledgement
- `deploy/Caddyfile.example`: HTTPS origin forwarding to the loopback service, body-size limit, no-store and security headers; replace the sample domain

Install the environment file as `/etc/arrivau/pilot.env` and the account configuration as `/etc/arrivau/auth.json`; make them root-owned, group `arrivau`, mode `0640`. Install the service unit and configure the proxy using the official systemd/Caddy documentation for your host. Review firewall and DNS yourself. Never commit the filled-in files, password hashes, tokens, signing keys or production database.

For a brand-new pilot, use a **fresh database path**. For an existing deployment, retain its database and follow [the team migration and upgrade order](teams-and-review.md); never replace live data to enable teams. A persisted mode/fleet marker rejects reuse of demo data in production. Keep one process and one local SQLite database; do not use network storage, autoscaling replicas, or multiple instances against the same fleet.

### Managed host / container alternative

For a platform such as Render, configure one paid web-service instance and a persistent disk. Use `deploy/Dockerfile` with the repository root as build context (or native Rust build command `cargo build --release --locked --manifest-path api/Cargo.toml`, start `api/target/release/arrivau-api`). The runtime container runs as UID/GID `10001`; its mounted data directory must be writable by that user. Do not copy credentials into the image.

Set `ARRIVAU_MODE=production`, `ARRIVAU_TLS_PROXY=1`, `ARRIVAU_ALLOW_NON_LOOPBACK=1`, `ARRIVAU_ADDR=0.0.0.0:10000`, `ARRIVAU_DB_PATH=/var/data/pilot.sqlite3`, and `ARRIVAU_AUTH_CONFIG=/etc/secrets/auth.json`. Mount the disk at `/var/data` and supply the filled account JSON through the provider's protected secret-file facility, never through Git. Set `/health` as the health-check path. Verify that all public traffic is HTTPS and the container port is reachable only through the provider's trusted ingress; these flags do not encrypt raw HTTP or make an arbitrary public socket safe. On another platform use its actual port/disk/secret paths.

Render supports secret files at `/etc/secrets/<filename>` and requires binding to `0.0.0.0`; its default ingress port is `10000`. A disk-backed service is single-instance and deploys with downtime. Disable auto-deploy until you have a verified backup and an intentional rollout plan. Source: [Render web services](https://render.com/docs/web-services), [secret files](https://render.com/docs/configure-environment-variables#secret-files), [persistent disks](https://render.com/docs/disks). These are setup instructions only; no provider resources have been created or tested.

## 2. Individual accounts and revocation

See `api/README.md` for the exact account JSON schema and password-hashing command. Provision one individual account per person, granting dispatcher, driver or both capabilities within one team; never share pilot logins. Keep App Review in its own team, as described in [Teams and App Review](teams-and-review.md). Use stable, unique account IDs; a driver's account ID is also their driver ID. Give accounts clear display names. Choose strong unique passwords and pass them privately to their owners. The server stores only Argon2id password hashes in the local configuration; it never has public pilot tokens.

Login creates an expiring opaque bearer session. The native app stores it in the device Keychain and verifies its identity with the server before resuming. Logout revokes that token when reachable and stops local GPS immediately. If the network is unavailable at logout, the local token is discarded and the server session remains valid until expiry or operator revocation. Account removal/password changes require a server restart; see the API guide for session invalidation behavior. Treat a lost phone as a reason to revoke the account's sessions, not just change its display name.

Before giving out the app, verify:

1. `https://YOUR-DOMAIN/health` responds successfully with no customer data
2. `/v1/me` without a token and with the public `demo-dispatcher` token returns `401`
3. Each pilot account can sign in; incorrect passwords fail without identifying which usernames exist
4. Driver accounts cannot create or assign deliveries, act for another driver, or read another driver's jobs
5. Only the proxy is reachable from outside the host; `http://YOUR-DOMAIN:8080` must not be exposed
6. Restarting the process retains deliveries and routes; authenticate again if sessions are invalidated

Do not paste passwords/tokens into command-line arguments, shell history, issue descriptions or CI logs. Use the app for login verification or a local script that prompts without echo and discards the token afterward.

## 3. Persistence, backups and recovery

The SQLite database contains delivery addresses, job notes, current driver coordinates, shifts, route order and authentication/session metadata. It is sensitive operational data. Restrict access to the host and backup location. Do not log request bodies, Authorization headers or credentials at the proxy. The supplied proxy template does not enable access logging.

For this small pilot, stop the service briefly and copy the database plus any remaining `-wal`/`-shm` sidecars together to protected backup storage. Alternatively use SQLite's online backup API/CLI; never copy just a live main database file and assume it is a consistent backup. Test restoring to an isolated host/path before relying on it. Retain one verified backup before changing the binary or account configuration. Roll back code only together with a compatible data backup.

There is no automatic data-retention/deletion service or audit trail. Decide retention with participants before real-data use, keep the pilot short, and remove test data intentionally after it ends. This is engineering guidance, not a privacy/compliance assessment.

## 4. iPhone and TestFlight preparation

Use the [TestFlight publishing steps](../README.md#publish-to-testflight) for the configured signing/upload workflow. Verify the build's HTTPS API origin and privacy disclosures against the deployed service. The app targets iOS 17+; the repository includes an opaque 1024px icon, privacy manifest and Release transport restrictions.

The app opens an Italian login screen. Enter your service's exact HTTPS origin and the assigned username/password. The server returns the role; there is no permissions picker at login. Accounts authorized for both roles have a Centrale / Corriere view switch after login. Release builds cannot use demo credentials or HTTP. The first login may need network access for Apple Maps place search later.

## 5. Run one supervised delivery

Use two phones and two different accounts. Keep both apps visible for this first check.

1. Driver: sign in, start a shift and explicitly consent to sharing the current location
2. Dispatcher: sign in, confirm the driver's recent position and active shift, save a clearly labelled synthetic restaurant with a real map-selected address, then create an order using it and a real destination; readiness remains unknown
3. Dispatcher: open the order and choose Pronta ora; confirm the server assigns it. Also test Pronta tra… with the dispatcher app closed, then reopen after the estimate and verify assignment
4. Driver: verify the next stop appears (foreground refresh is approximately every five seconds), follow directions only when safe, then confirm pickup and delivery in order
5. Dispatcher: verify status and route changes, including after restarting the server
6. Driver: finish the work, end the shift and confirm location sharing stops; sign out and confirm the app no longer shows the previous account's deliveries

## 6. Required interruption/device checks

Keep a human dispatcher in contact with the driver. Record the device model, iOS version, app build, API commit and result for every case:

- Turn networking off during restaurant/order creation, readiness, assignment/status changes. Confirm a visible error, reconnect and refresh. Retry the same pending action; check that a duplicate delivery or duplicate route stop is not created. Do not create a replacement delivery just because the first response was lost
- Sign out/in and restart the app; confirm restored sessions are checked, expired/revoked sessions return to login, and changing the API origin cannot send an old token to the new server
- Deny location permission, later grant it, stop/restart sharing and end the shift. No GPS should be sent while off shift or after logout
- Only after foreground checks pass, enable the separate background-sharing control; lock the phone, switch to Maps, lose/recover connectivity, then check location timestamps at the dispatcher
- Force-quit/reboot the driver phone: do not assume reporting resumes. Reopen the app, verify the shift and explicitly resume sharing if needed
- Test repeated taps, pending delivery form after an error, server restart, and a response arriving after signout/account change

Mutations use idempotency keys to make retries of a still-pending action safe. This is **not a durable offline action queue**. Do not continue accepting/completing work without a verified server response. After relaunch, use the saved pending-creation recovery when offered; its exact body/key is retained in the Keychain. Assignment/status keys live only for the current process, so a fresh server read is required before further route actions. Inspect current state before manually replacing a job. Keep delivery notes non-sensitive and synthetic during verification.

## Known limits

- Foreground polling, no APNs and no guaranteed background delivery notifications. A suspended dispatcher app can miss assignments/status changes until reopened
- Background GPS is opt-in and must be verified on signed physical devices; iOS can suspend/terminate it. No tracking outside an explicitly active shift
- Approximate routes, no traffic/road restrictions or global optimality guarantee; human judgement remains necessary
- Private server-enforced teams, operator-managed accounts, invite-only driver signup, no self-service reset or team-administration UI, no billing or customer app
- Database backups, service monitoring, certificate renewal, host security and retention are the operator's responsibility
- Physical phones, signing, TestFlight processing/review, hosted TLS and real-world network behavior are not covered by CI

## Invitation rollout gate

Driver invitations are scoped to the issuer's Squadra and preserve existing dual-role accounts. See [invitations](invites.md) for additive schema v4, uncertain-response recovery, backups and operator disabling. Keep the draft unpublished until its account-deletion decision and native/device checks are resolved; invitation work does not authorize live migrations or a TestFlight upload.
