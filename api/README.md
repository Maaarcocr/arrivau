# Rust API: supervised team-isolated pilot

The loopback fixture demo and individually authenticated phone pilot are separate
modes and use separate SQLite databases. This repository prepares an operator-run
pilot; it does not deploy a service or provision real accounts.

## Isolated simulator demo

From the repository root:

```sh
./scripts/api-dev.sh
```

The script explicitly selects demo mode, binds `127.0.0.1:8080`, and defaults to
`arrivau-demo.sqlite3`. `ARRIVAU_DEMO=1` remains a legacy explicit opt-in. Demo
mode seeds two original fixture drivers plus an isolated dual-role review fixture
and accepts public demo bearer strings.
Never proxy it, bind it to a LAN, or enter customer data. Non-loopback binding
is rejected even when production ingress flags are supplied. It cannot load a
production account configuration, and demo databases cannot become pilot databases.

## Operator-managed pilot accounts

Use one account per person, with stable IDs that are never recycled for someone
else. Driver-capable account IDs are also driver IDs in domain records. One database
and configuration hold operator-managed private teams. Each account has exactly
one team; there is no platform-wide administrator API.

Create a private, operator-managed JSON file outside the repository:

```json
{
  "fleet_id": "your-fleet-id",
  "session_ttl_seconds": 43200,
  "accounts": [
    {
      "id": "dispatcher-unique-id",
      "username": "dispatcher-login",
      "name": "Dispatcher name",
      "role": "dispatcher",
      "password_hash": "REPLACE_WITH_INDIVIDUAL_ARGON2ID_HASH"
    },
    {
      "id": "driver-unique-id",
      "username": "driver-login",
      "name": "Driver name",
      "role": "driver",
      "password_hash": "REPLACE_WITH_DIFFERENT_INDIVIDUAL_ARGON2ID_HASH"
    }
  ]
}
```

The old configuration above remains supported: `fleet_id` is both the stable
deployment ID and default/legacy team ID, and `role` grants one capability. To add
an isolated team, supply `teams: [{"id":"...","name":"..."}]` (including the
original fleet ID) and `team_id` on its accounts. Accounts can use
`roles: ["dispatcher", "driver"]` for both capabilities. An optional `role` must
belong to those capabilities; otherwise dispatcher is the dual-role default.
The implicit legacy team display name is its ID; explicitly list it to give it
a friendly name. See [the complete configuration and migration guide](../docs/teams-and-review.md).

These placeholders deliberately fail validation. No production account/password
is supplied in the repository. Generate each hash locally:

```sh
cargo run --locked --manifest-path api/Cargo.toml --bin arrivau-password-hash
```

On a terminal the helper hides input and asks for confirmation. It also accepts
stdin for an operator's secure provisioning flow. Never put passwords in command
arguments, environment variables, shell history, chat, logs, or committed files.
The helper prints only the PHC hash; protect that output and the configuration
with owner-only filesystem permissions. Use unique, strong individual passwords
from a password manager. The helper requires at least 12 UTF-8 bytes and uses
Argon2id v19, 19 MiB memory, two iterations, one lane, random 16-byte salt, and
32-byte output. Configuration validation rejects weaker hash parameters.

Configure 1–100 accounts, including a dispatcher. IDs/usernames contain 1–64 ASCII
letters, digits, dot, underscore or hyphen, starting with a letter or digit;
usernames must be lowercase. Session
TTL must be 300–86400 seconds. Teams and capabilities come exclusively from this configuration.
There is no open signup, role/team-selection endpoint, or password-reset endpoint. A configured account with dispatcher capability may issue one-use driver-only invitations for its own team; invited accounts are persisted in SQLite and must not be copied into this configuration. See [invitation operation and account deletion](../docs/invites.md).

## Production-mode configuration

```sh
ARRIVAU_MODE=production \
ARRIVAU_DB_PATH=/absolute/persistent/fleet.sqlite3 \
ARRIVAU_AUTH_CONFIG=/absolute/private/accounts.json \
ARRIVAU_ADDR=127.0.0.1:8080 \
ARRIVAU_TLS_PROXY=1 \
./api/target/release/arrivau-api
```

Build first with `cargo build --release --locked --manifest-path api/Cargo.toml`.
`ARRIVAU_TLS_PROXY=1` is an operator assertion, not TLS validation performed by the
Rust HTTP process. Set it only after configuring trusted HTTPS ingress. The
recommended upstream is loopback behind a same-host TLS reverse proxy.

A managed host whose TLS proxy reaches a private container interface may use
`ARRIVAU_ADDR=0.0.0.0:8080` plus **both** `ARRIVAU_TLS_PROXY=1` and
`ARRIVAU_ALLOW_NON_LOOPBACK=1`. Configure the host to prevent direct public access
to this cleartext HTTP port; all outside traffic must use the HTTPS proxy. The
binary does not read `PORT`, infer proxy trust from forwarded headers, obtain
certificates, or terminate TLS itself. Never use the opt-in on an exposed VPS
HTTP port. Missing mode, conflicting demo flags, missing config, relative database
paths, weak/placeholder password hashes, and unsafe binds fail closed.

Use one running API process and durable storage with private filesystem access.
SQLite WAL contains customer addresses, latest coordinates, delivery state, session
hashes, login counters and idempotency records. Protect the database, WAL/SHM files,
configuration and backups together. Do not put SQLite on ephemeral container disk
or an unsupported network filesystem. A mode/fleet marker rejects cross-mode or
cross-fleet database reuse; legacy demo data is not imported into a pilot.

## Sessions and account changes

- `POST /v1/session` with `{ "username": "...", "password": "..." }` returns
  HTTP 201 with `{ "token": "...", "expires_at": 1790000000, "user":
  { "id": "...", "name": "...", "role": "driver", "roles": ["driver"],
    "team_id": "...", "team_name": "..." } }`
- `GET /v1/session` with `Authorization: Bearer <token>` returns `user` and
  `expires_at`; `GET /v1/me` retains the original user-only response
- `DELETE /v1/session` revokes the presented session and returns HTTP 204
- Missing, invalid, revoked or expired credentials return 401; wrong roles return
  403. Existing JSON error shape is `{ "error": "message" }`
- Sessions use 32 cryptographically random bytes, are stored only as SHA-256
  hashes, expire at a fixed deadline, and survive process restarts. Each account
  retains at most ten live sessions; no automatic refresh is implemented
- Changing a configured account's hash, username, name or capabilities, or removing it,
  revokes its sessions on the next restart. Team reassignments of previously bound
  account IDs are rejected rather than silently transferring access/history.
  Restart is required to apply config
  edits. Removing a driver disables new assignments but preserves route/history
  for dispatcher recovery. Resolve/reassign outstanding work before removal
- For an emergency lost-device revocation, change that individual's hash or remove
  their account, then restart the service. Other unchanged users retain sessions
- Login attempts, including unknown usernames, are limited to ten per username
  per five minutes and sixty overall per minute, persisted through restart. HTTP
  429 means wait; a maximum of two concurrent Argon2 checks bounds CPU/memory
- Add ingress/IP rate limiting, request timeouts and monitoring at the TLS proxy.
  The simple per-account limit can be deliberately exhausted by an attacker
- Session responses and API data use `Cache-Control: no-store`; tokens/passwords
  are never application-logged. Do not configure a proxy to log authorization or
  request bodies

Production accepts no demo bearer tokens and seeds no fixture drivers. Account
login is unavailable in demo mode. Demo session identity has `expires_at: null`;
its public fixture tokens cannot truly be revoked and must never leave loopback.

Invited accounts can be disabled and all their sessions revoked with the offline operator helper documented in `docs/invites.md`. Disabling preserves their team/history and is not account deletion. Removing a team from configuration disables its invited accounts on restart without relabeling their records.

## Durable retry contract

`POST /v1/restaurants`, `POST /v1/deliveries`, `POST /v1/deliveries/{id}/readiness`, `POST /v1/deliveries/{id}/assign`, and
`POST /v1/deliveries/{id}/status` accept `Idempotency-Key` with 8–128 ASCII letters,
digits, dot, underscore or hyphen. A fresh UUID per intended action is recommended.
Persist and resend the same key **and exact request** after a timeout or disconnect.
Do not automatically mint a new key when the server may already have committed.

The original successful response and request fingerprint commit in the same SQLite
transaction as the domain mutation. Repeating the same authenticated account's key
and request returns the original response, even after restart/new login. Reusing a
key for a different endpoint, target or body returns 409. Team/account scopes are
independent, and capability/team/ownership checks still apply. Keys are optional for legacy
clients; requests without a key keep the original strict transition behavior.

Only successful writes are recorded; rejected requests can be corrected and retried.
A replay response may describe an older delivery state, so refresh deliveries/route
afterwards. Idempotency records are retained with the pilot database and are not
silently expired. Do not independently prune them while clients can retry old actions.

## Domain behavior and limits

- Server-enforced team boundaries, dispatcher/driver capabilities and driver ownership on protected routes
- Dual-capability accounts can dispatch and operate their own driver profile in one team; dispatcher permission never authorizes completing another driver’s stops
- SQLite serializes small-fleet planning and writes. Assignment, reassignment,
  completion, ordered route stops and retry records commit transactionally
- The insertion planner checks capacity, readiness, pickup-before-dropoff, deadline,
  elapsed onboard time and the previous driver's route when reassigning
- Default travel is Haversine × 1.3 at 25 km/h plus 60 seconds per stop. Optional
  [embedded OSRM](../docs/embedded-routing.md) adds regional offline road times and
  one-way restrictions, with explicit approximate fallback and no live traffic.
  Native queries release SQLite and revalidate the snapshot before committing.
  Human review remains required
- A driver's location must be at most 300 seconds old for new assignments. Existing
  work stays visible with warnings. At most 32 outstanding route stops are allowed
- Drivers complete only their committed next stop; pickup readiness is enforced.
  Late real-world completions remain recordable. There is no arrival geofence
- Latest location only, no location history. Ending shifts/signing out stops client
  updates; account logout does not end a shift or cancel work
- No multi-instance scheduling, audit trail, automated backups, retention/deletion
  service, APNs, durable offline queue or live road-time provider is claimed

## Verification

```sh
cargo fmt --manifest-path api/Cargo.toml -- --check
cargo clippy --locked --manifest-path api/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path api/Cargo.toml
```

Tests use actual ephemeral TCP listeners, temporary on-disk SQLite, fake clocks and
explicit test-only passwords. Coverage includes original dispatch/planning flows,
individual login, role isolation, fixture rejection, expiry, logout, restart,
password/account revocation, login limits, database mode/fleet separation, team isolation,
legacy migration/restart, dual-role self-assignment, startup
misconfiguration, and durable/conflicting create/assignment/completion retries.
Physical-iPhone behavior and a real TLS deployment require the separate operator
acceptance checklist; a passing Rust test suite does not establish those outcomes.

## Restaurants and automatic readiness dispatch

New orders have unknown readiness and no driver selection. Save/select a restaurant, then report ready-now or ready-in-minutes later. The server assigns ready work immediately or from its bounded five-second timer, including least-bad timing fallbacks with visible warnings. See [readiness, resource bounds, compatibility and rollout](../docs/readiness-and-dispatch.md). Schema version 5 also protects invite-account state and prevents unsafe older-backend rollback; take a verified backup before upgrading. The default remains approximate; configure the separately tested [embedded routing feature](../docs/embedded-routing.md) to use regional road times.


## Google Places server configuration

Set `ARRIVAU_GOOGLE_PLACES_SERVER_KEY` to an operator-managed, server-only key
restricted to Places API (New) and the deployment's egress IP(s). Do not reuse the
bundle-restricted iOS key, put it in source, or log outbound request headers. Key
creation, API enablement and billing activation are separate owner setup steps.
Without this key, Google destination creation/refresh fails closed; legacy
coordinate-only API workflows remain available with no Google navigation ID.

New requests provide Google Place IDs and original user-authored text. The server
requests only Place Details `id,location` (Essentials). Provider names/addresses are
not requested or retained. IDs are durable; resolved coordinates live only in a
SQLite TEMP table with `temp_store=MEMORY`, and expire at 29 days (a margin below the 30-day ceiling) or on restart.
Refresh has four workers, a nine-second total budget and a 30-second failure
backoff; both transient cache tables are capped at 4,096 entries.
Google-bearing OSRM calculations bypass long-lived matrix/snap caches.
They are removed from durable delivery, restaurant and idempotency JSON, including
completed/history snapshots. No separate disk cache, WAL or backup purge job is
needed for these locations. Disable body logging/caching outside the API too.

The dispatch timer purges expired cache rows even while clients are idle. Routing
and dispatch refresh missing entries before planning. An outage retains ordered
stops but suppresses ETA availability and blocks new routing-based assignments.
Deploy null-aware native clients with schema 6; downgrade is rejected. See the
[wire contract](../docs/api-contract.md#google-places-destinations-and-location-retention-schema-6).

Verification: `cargo test --locked --manifest-path api/Cargo.toml` includes an
actual loopback HTTP Details transport test and API integration tests using a fake
provider. They cover field masks, redirects/errors, provenance, team scoping,
expiry, restart/retry behavior, unavailability and legacy compatibility without
paid APIs or real keys. Synthetic `arrivau-test-pachino-*` selections are restricted
to explicit demo mode; production always rejects them.
