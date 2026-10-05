# Arrivau API v1

Pilot API base: your configured HTTPS root origin. Isolated demo base: `http://127.0.0.1:8080`. JSON uses snake_case. Timestamps are UTC Unix seconds (integers), coordinates decimal degrees. IDs are strings. All routes except `GET /health`, `POST /v1/session` and `POST /v1/invites/redeem` require `Authorization: Bearer <token>`.

Demo-only principals (enabled explicitly by `ARRIVAU_DEMO=1`): token `demo-dispatcher` has dispatcher role; `demo-driver-1` / `demo-driver-2` have driver role and matching IDs `driver-1` / `driver-2`. The additional `demo-dual` token identifies `dual-1` with both capabilities in the separate `demo-review` team. These tokens never authenticate in production mode. The API fails closed unless an explicit demo or fully configured production mode is selected. Bind loopback by default; managed hosts require both trusted-TLS-proxy and nonloopback opt-ins. Never expose raw HTTP or use public fixture tokens outside local development.

Response examples retain the legacy fields; identity responses also include the additive fields described below. API errors: `{"error":"human-readable reason"}` with suitable 400/401/403/404/409/422/429 status. Responses have `Cache-Control: no-store`; request bodies are bounded to 16 KiB.

- `POST /v1/session` (production, no bearer): body `{"username":"dispatcher","password":"<private password>"}` → 201 `{"token":"<opaque bearer>","expires_at":1791117600,"user":{"id":"dispatcher-1","name":"Centrale","role":"dispatcher"}}`. Invalid credentials return generic 401; throttling returns 429. Configured accounts and invite-created drivers use the same login endpoint
- `GET /v1/session` (authenticated) → `{"expires_at":1791117600,"user":{"id":"dispatcher-1","name":"Centrale","role":"dispatcher"}}`. Demo expiry is null
- `DELETE /v1/session` (authenticated) → 204; revokes that production token immediately. Expired/revoked tokens return 401
- `POST /v1/invites` (production, dispatcher capability) body `{"name":"Nome corriere"}` → 201 `{"id":"<UUID>","token":"<64 lowercase hex>","expires_at":1791204000,"name":"Nome corriere","role":"driver","team_id":"pilot","team_name":"Squadra pilota"}`. Name trimmed, 1–240 UTF-8 bytes, no control characters. Team derives solely from the issuer session. Driver-only capability, no optional client role/team fields. Token returned once, expires exactly 24 hours after issuance
- `DELETE /v1/invites/{id}` (production, dispatcher capability) → 204, idempotently revokes a pending invite within the caller's team using its non-secret UUID. A foreign-team/missing ID is a no-op; it never disables an already-created account
- `POST /v1/invites/redeem` (production, public) body `{"token":"<invite secret>","username":"new.driver","password":"<chosen password>"}` → 201 with the login session response and server-derived `user.roles:["driver"]`, `user.team_id` and `user.team_name`. Username normalized lowercase/trimmed, 1–64 ASCII letters/digits/dots/underscores/hyphens, first character alphanumeric, raw username maximum 64 bytes; password 12–1024 UTF-8 bytes. The token determines display name and team. Invalid/used/revoked/expired token → 400; unavailable username → 409 leaves invite usable; extra fields → 400; throttling → 429. All invitation endpoints unavailable in demo mode
- `GET /health` → `{"status":"ok"}`
- `GET /v1/me` → `{"id":"dispatcher-1","name":"Dispatcher","role":"dispatcher"}` (driver principals use matching IDs and name `Driver 1` etc.)
- `GET /v1/restaurants` (dispatcher) → own-team saved restaurants: `{id,name,address,coordinate,created_at}`
- `POST /v1/restaurants` (dispatcher) body `{name,address,coordinate}` → 201 Restaurant. Text 1–240 characters and valid coordinate required; supports Idempotency-Key
- `GET /v1/drivers` (dispatcher) → array of Driver in the caller’s team
- `GET /v1/shift` (driver) → caller Driver, including persisted shift/location state
- `POST /v1/shift` (driver) body `{"active":true,"capacity":2}` → Driver. Capacity integer 1–8. Ending a shift with assigned/onboard work is rejected (409).
- `POST /v1/location` (driver) body `{"lat":36.7163,"lng":15.0908}` → Driver. Active shift required.
- `GET /v1/deliveries` → array of Delivery; dispatcher sees their team’s deliveries, driver-only accounts see their own only. Dual-capability accounts receive team deliveries, with the Corriere view filtering their own assignments
- `POST /v1/deliveries` (dispatcher) → 201 Delivery. Body: `{"shop_name":"Pizzeria","pickup_address":"Via Roma 1, Pachino","pickup":{"lat":36.7163,"lng":15.0908},"dropoff_address":"Via Garibaldi 8, Pachino","dropoff":{"lat":36.7210,"lng":15.1000},"restaurant_id":"<saved restaurant id>","deadline_at":1790877600,"load_units":1,"max_ride_seconds":1800}`. Validate nonempty bounded text, valid finite coordinates, bounded deadline, load 1–8, max ride 60–7200 seconds. Created job initially pending, unassigned and readiness unknown. Optional restaurant_id is server-resolved within the caller’s team; pickup fields become an immutable snapshot. Legacy ready_at input remains accepted as an estimate.
- `POST /v1/deliveries/{id}/readiness` (dispatcher) body `{"ready_in_minutes":0,"expected_revision":0}` → Delivery. Minutes 0 confirms now, 1–120 estimates future readiness. Revision conflicts and post-pickup edits return409. Ready-now auto-assigns immediately; future readiness is assigned by the server timer. Exact retries preserve the original timestamp. See [readiness and dispatch](readiness-and-dispatch.md).
- `POST /v1/deliveries/{id}/assign` (dispatcher) body `{"driver_id":"driver-1"}` → Delivery. Active shift/location reported within the last 300 seconds required; target driver's whole proposed route must be feasible before commit. Reassignment also rejects newly introduced violations in the previous driver's remaining route, while allowing already-present warnings so dispatch can recover work from stale or late routes. At most 32 outstanding stops per driver. Cannot reassign picked-up/completed jobs; return 409/422 rather than silently violating constraints.
- `POST /v1/deliveries/{id}/status` (assigned driver only) body `{"status":"picked_up"}` or `{"status":"delivered"}` → Delivery. State transitions only assigned→picked_up→delivered. Unknown readiness or pickup before a known ready_at rejected; delivery before pickup rejected. Driver may only act on their currently suggested next stop (409 otherwise), so app/route do not drift.
- `GET /v1/route` (driver) → Route for caller
- `GET /v1/drivers/{id}/route` (dispatcher) → Route
- `GET /v1/deliveries/{id}/suggestions` (dispatcher) → array of Suggestion, feasible active drivers sorted by incremental pickup-priority/travel cost. Infeasible drivers and drivers whose location is older than 300 seconds are omitted.

## Team identity and dual capabilities

Every `user`/`/me` response adds `roles`, `team_id`, and `team_name`, for example:

```json
{"id":"review-operator","name":"App Review","role":"dispatcher","roles":["dispatcher","driver"],"team_id":"apple-review","team_name":"App Review"}
```

`role` remains a recognized primary role for legacy clients; the complete
server-authoritative capability list is `roles`. An older client sees only its
primary screen. Updated clients accept legacy identities that omit the new fields
and retain their single-role behavior. They must not infer extra capabilities.
The account/team cannot be changed by a request body or the native view switch.

All protected reads, mutations and retry lookups are scoped to the authenticated
team. Foreign driver/delivery IDs are unavailable even when guessed; suggestions,
assignment, routes and location never cross teams. Both-capability accounts can
use dispatcher endpoints and their own driver endpoints; `/status` still requires
the same account to be the delivery’s assigned driver. Readiness fields extend Delivery/Route additively; legacy fields remain decodable.


Driver: `{"id":"driver-1","name":"Driver 1","active":true,"capacity":2,"location":{"lat":36.7163,"lng":15.0908},"location_updated_at":1790874000}`. location and location_updated_at can be null. Start/stop shift and location updates persisted.

Delivery: all POST fields above plus `{"id":"...","status":"pending","driver_id":null,"created_at":1790874000,"picked_up_at":null,"delivered_at":null}`. status enum pending/assigned/picked_up/delivered. driver_id and completion timestamps nullable. Additional fields: readiness_state (unknown/estimated/ready, missing means legacy estimated), readiness_revision (missing means0), readiness_updated_at, onboard_deadline_at, restaurant_id and dispatch_waiting_reason. The numeric ready_at MUST be ignored when readiness_state=unknown.

Route: `{"driver_id":"driver-1","stops":[{"delivery_id":"...","kind":"pickup","address":"...","coordinate":{"lat":36.7163,"lng":15.0908},"arrival_at":1790874000,"departure_at":1790874060}],"travel_seconds":180,"finish_at":1790874240,"feasible":true,"warnings":[]}`. kind pickup/dropoff. Stops ordered for execution. Arrival_at includes readiness wait (scheduled service start); departure includes 60 second handling time. Deadline/freshness tested at dropoff arrival. Default travel is Haversine × 1.3 at 25 km/h; optional embedded OSRM supplies regional driving durations. Every route adds `travel_estimate: {mode, approximate, notice, map_date, attribution}`. Mode is `approximate`, `embedded_osrm`, or `approximate_fallback`; show the Italian notice and OSM attribution, including mixed/native partial fallback. The route heuristic does not claim traffic awareness or global optimality. If a committed route is infeasible due to time passing or its driver location is more than 300 seconds old, `feasible=false` and warnings, retaining executable stops; don't silently hide work. Empty route has stops [] and feasible true. Additive notices contains soft pickup-target warnings without changing feasible. estimates_available=false means all numeric ETA projections must be hidden because the driver start is unknown or a road leg is unreachable. An unreachable leg is a hard routing constraint even for least-bad timing fallback; structural stops remain visible for recovery. Automatic dispatch may commit warning-bearing least-bad timing routes, while preserving capacity, precedence and reachable-road constraints. Planning-state 409 means refresh and retry after concurrent changes; already committed idempotent actions replay without waiting for native routing. Physical drop-off completion does not require routing.

Suggestion: `{"driver_id":"driver-1","incremental_travel_seconds":180,"route":{...}}`.

The app refreshes every 5 seconds while foregrounded, plus after writes. Push remains a future integration; offline road-time matrices are available with the explicit embedded OSRM feature. Location reporting is opt-in while on shift, with an explicit background Core Location capability/code path for locking the phone or using Maps; device execution is unverified. Stopping shift/signing out stops updates. UI simulator can opt into deterministic location through launch argument `--uitesting` only, using local demo tokens. No payment details are collected; delivery addresses and current driver locations are persisted and require appropriate operator privacy handling.


## Retry and session contract

`POST /v1/restaurants`, `POST /v1/deliveries`, `POST /v1/deliveries/{id}/readiness`, `POST /v1/deliveries/{id}/assign` and `POST /v1/deliveries/{id}/status` accept `Idempotency-Key` (use a UUID). A key is scoped to the authenticated team and principal, method/path and canonical request body. The original response is committed in the same SQLite transaction as the domain write and survives restart. Repeating the exact request returns the original response; reusing a key for a different operation/body returns 409. Keep the same key while the result is uncertain. This is not an offline queue. Shift changes set a desired state; location reporting uses the next fresh sample.

The native app persists an uncertain creation's exact body/key scoped to HTTPS origin, team ID and user ID, and retains assignment/status keys while the current process reconciles. It does not replay credentials across redirects. The app never infers capabilities or membership from a login or view choice in pilot mode. Tokens expire at the server's Unix timestamp; the app clears private state and stops local GPS on expiry/401/signout. Remote revocation cannot be guaranteed while the phone is offline, so session TTL and operator revocation remain part of the safety boundary.

A legacy endpoint/account-only pending creation is quarantined when explicit team identity becomes available: the app shows its original details and blocks creation/retry until the user has verified the server outcome and deliberately clears that local recovery record. It never silently replays an unscoped request into a new team.

Backend schema3 rejects unsafe downgrade to pre-readiness binaries. See [rollout and compatibility](readiness-and-dispatch.md#compatibility-and-rollout).

## Invite-only signup and uncertain responses

Invitation secrets are cryptorandom 32-byte values stored only as SHA-256 hashes. Redemption commits invite consumption, a team-bound driver/account, immutable identity binding and session atomically. Replays and concurrent redemption cannot create another account; signup shares the bounded Argon2 workers with login. Configured-account changes permanently invalidate outstanding invitations at restart. Existing invited accounts remain independent of their original issuer after redemption.

Limits: 20 issuance attempts per dispatcher/hour; 100 unexpired pending invites and 100 invited accounts including disabled identities per team; 60 redemption attempts/minute overall and 10 per token/username per five minutes, persisted across restart. Usernames are globally unique. Use ingress rate limiting/timeouts too.

Do not automatically replay uncertain redemption after transport failure/cancellation/lost response. The account may already exist: use normal login with the same username/password and server. Links are bearer secrets; share privately, never log them or request bodies. App links cannot change the API origin. Invite-created drivers may delete their account using the preview/confirmation contract below; offline disabling is a separate operation that retains history.


## Invited-account hard deletion

The server adds optional `can_delete_account:true` to actual invite-created principals. Omission means unsupported; configured/demo accounts are not self-deletable. This display capability never replaces endpoint authorization.

- `GET /v1/account/deletion-preview` (authenticated invited driver) → `{"delivery_count":3,"active_delivery_count":1,"confirmation":"<64-hex snapshot>"}`. Counts and the snapshot cover that account's currently linked deliveries within its team
- `DELETE /v1/account` (authenticated invited driver) body `{"password":"<current password>","confirmation":"<reviewed snapshot>"}` → 204 after an atomic hard delete. No user ID, team ID or extra fields accepted. Password confirmation failure 403, invalid/revoked session 401, changed preview 409, throttling 429. A stale preview requires rereading and explicit reconfirmation

Password verification shares the bounded Argon2 pool. Final identity/session/team/snapshot checks run under the deletion transaction, so changing assignments/status/readiness cannot silently expand the reviewed action. The full record scope and intentionally preserved shared data are documented in `invites.md`. Deleted-account tokens immediately stop authenticating; repeating deletion with them cannot perform a new action. A lost response is uncertain: never automatically replay a destructive request or claim success without confirmation.


## Google Places destinations and location retention (schema 6)

Updated native clients select destinations with Google Places. The stable ID is
server-verified through Place Details (New), requesting only `id,location`
(Details Essentials). The OSRM/approximate scheduling engine is unchanged; Google
navigation receives the current first stop's Place ID, never coordinates copied
from a legacy Apple selection. The ordered API route remains authoritative.

New fields on `POST /v1/deliveries`:

```json
{
  "shop_name": "Name entered by the dispatcher",
  "pickup_address": "Original pickup text entered by the dispatcher",
  "pickup_google_place_id": "<selected Google Place ID>",
  "dropoff_address": "Original dropoff text entered by the dispatcher",
  "dropoff_google_place_id": "<selected Google Place ID>",
  "deadline_at": 1790877600,
  "load_units": 1,
  "max_ride_seconds": 1800
}
```

- Google IDs are optional for legacy API compatibility. For each endpoint without
  an ID, a valid coordinate is still required. Such a destination remains legacy,
  with no Google navigation capability; it is never silently reclassified
- For endpoints with an ID, omit `pickup`/`dropoff`: the server ignores any
  supplied coordinates and resolves its own. Client-declared provider/freshness
  fields are rejected. Unknown, invalid, unavailable or unresolvable IDs never
  create a Google destination using client or stale coordinates
- Existing text fields must contain independently user-authored name/address
  text, not Google autocomplete predictions, formatted addresses or display names.
  The server never requests or stores Google labels. The native picker retains
  the original typed query separately from its transient prediction display
- `POST /v1/restaurants` likewise accepts `google_place_id`, independent user
  `name`/`address`, and an optional `coordinate`. A saved restaurant's server-owned
  ID and text become the delivery pickup snapshot. A legacy saved restaurant must
  be explicitly reselected in the updated native UI; no bulk licensing flag exists
- Invalid request syntax/IDs return 400. Missing server configuration or unavailable
  Details returns 503 for a new Google creation, without storing the delivery or
  restaurant. Existing idempotent commits replay without requiring the provider

Delivery responses add `pickup_google_place_id`, `dropoff_google_place_id`,
`pickup_coordinate_fetched_at` and `dropoff_coordinate_fetched_at`. Restaurant
responses add `google_place_id` and `coordinate_fetched_at`. RouteStop adds
`google_place_id` and `coordinate_fetched_at`. All default to null on legacy data.
A non-null ID identifies a server-resolved Google selection; the corresponding
fetched timestamp describes only the current temporary location, not the stable
ID's lifetime. Coordinate fields (`pickup`, `dropoff`, `coordinate`) are nullable
when no fresh Google location is available. Clients must support nulls before
Google records are created in that fleet.

There is one team-scoped, memory-only temporary location cache keyed by Place ID.
It holds the provider tag `google`, coordinate and server fetch time for strictly
less than 29 days, leaving a one-day cleanup margin before the 30-day ceiling. Both the location cache and short failure cache are capped at 4,096 entries. Expired/future-dated entries are deleted on every API storage
access and by the existing server dispatch timer even without client activity.
Process restart discards the entire cache. Google-bearing OSRM queries use only
request-local matrix/snap caches, so the native worker cannot retain coordinate
copies after this cache expires. Legacy native caching is unchanged. Coordinates and fetch timestamps are
stripped from every durable delivery, restaurant and idempotency response,
including completed history and nested snapshots, so database backups and WAL
never acquire Google location copies. IDs and original user-owned text persist.
Do not introduce request/response-body logging or external caches that defeat
these limits. Existing user/legacy coordinates follow their existing retention.

Before routing, assignment, suggestions, readiness re-planning or dispatch, the
server refreshes missing/expired Google locations for the relevant outstanding
work. Provider failure retains every committed stop in order, makes missing
coordinates null, sets `estimates_available=false` and `feasible=false`, and
prevents new assignments through that route, including least-bad timing dispatch.
All numeric ETA fields then are compatibility placeholders and must be hidden.
Physical completion still follows the existing first-stop/state-transition rules.
Listing history or restaurants alone does not cause paid lookups. Original
idempotent outcomes replay with currently available temporary coordinates or null;
replaying cannot resurrect an expired coordinate snapshot.

Schema 6 rejects downgrade to a server that would assume coordinates are permanent
and always present. Back up before upgrading and roll out null-aware clients first.
Legacy coordinate-only requests retain their canonical retry fingerprint. The two
`arrivau-test-pachino-*` synthetic IDs are recognized only in explicitly isolated
demo mode and rejected in production, even when a resolver is configured.

Server deployment: set `ARRIVAU_GOOGLE_PLACES_SERVER_KEY` separately from the iOS
bundle key, authorize Places API (New) only, and restrict it to the server's egress
IP(s). A missing key leaves Google creation/refresh unavailable, while existing
legacy jobs continue. Requests use fixed Google HTTPS URLs, an `id,location` field
mask, no redirects, four concurrent workers, a 3-second connect/8-second total
request timeout and an 8 KiB response limit. Refresh runs at most four lookups concurrently, with a nine-second total refresh
budget; missing locations stay null if it runs out. Failed lookups use a 30-second
memory-only backoff to avoid repeatedly billing/flooding a failing service.
Provider error bodies and keys are never returned or logged. Tests use injected resolvers and loopback HTTP fixtures;
no paid Google call, key creation or billing change is part of verification.

References: [Place Details field masks and billing](https://developers.google.com/maps/documentation/places/web-service/place-details),
[Places policies and attribution](https://developers.google.com/maps/documentation/places/web-service/policies).
Review applicable Google/EEA terms for the deployment's billing region before
activation; coordinate retention is a technical safeguard, not a blanket license.
