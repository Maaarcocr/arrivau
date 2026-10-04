# Restaurants, readiness and automatic dispatch

## Dispatcher flow

Save a restaurant once with its name and Maps-selected address/coordinate. Each
new order selects that restaurant and its destination. The API resolves the
restaurant within the authenticated team and copies its pickup details into the
order, ignoring substituted client pickup details. The saved restaurant and the
order snapshot are separate records. This version offers add/list/select only.

Creation does not ask for food readiness or a driver. The order starts pending
with `readiness_state=unknown`. Creating it never starts the ten-minute pickup
clock. Later, the dispatcher opens it and chooses **Pronta ora** or **Pronta tra…**.
Zero minutes confirms readiness at server time; 1–120 minutes supplies an estimate.
An elapsed estimate remains labelled estimated until an explicit update; driver
pickup is allowed at or after it without a second dispatcher confirmation.

The server assigns pending work as soon as known readiness arrives. Ready-now is
handled in the same transaction as the readiness update. Future estimates and
unassigned work are checked by a server timer every five seconds, independently
of the iPhone being open, and after driver shift/location updates. Each sweep
attempts at most 32 pending jobs; a fixed-cohort rotating cursor prevents blocked orders from
starving later work. Failed/no-driver work remains visible and is retried. This
is one process with serialized SQLite transactions, not a distributed queue.

No on-shift driver yields `dispatch_waiting_reason=no_active_driver`. Genuine
capacity, structural-route or 32-stop limits yield `capacity_or_route_limit`. With embedded road routing, this generic hard-route reason also covers unreachable road legs; the app asks the dispatcher to check road access as well as capacity and stop count, rather than claiming that every vehicle is full.
Neither case pretends assignment succeeded. Dispatchers should inspect the alert
and arrange a suitable on-shift driver. No off-shift driver is silently activated.

## Selection and timing policy

The planner retains other jobs' relative stop order and evaluates legal insertion
positions for the new pickup/dropoff. Capacity, pickup-before-dropoff and presence
of every committed stop are mandatory. A full car can deliver first, then collect.
It never reassigns already picked-up work or removes orders to improve a score.

For known positions, fully feasible routes are preferred. The finite operating
cost is travel seconds + twice restaurant-ready waiting seconds + eight times
pickup seconds beyond the ten-minute target. An insertion also pays each extra
second of delay to already-onboard deliveries. Added cost is measured against the
current committed route. Deterministic tie breaks use travel/finish and driver ID.
The ten-minute target concerns scheduled pickup service start, with a 60-second
handling allowance afterward; exactly ten minutes is still on target.

An onboard order gets an absolute delay guard from its committed dropoff ETA plus
five minutes, capped by its delivery deadline and actual pickup plus max ride
time. At pickup the planning baseline starts at the acknowledged restaurant
stop, never the already-completed approach from an old GPS fix. It does not alter
the reported GPS point. For older onboard records it is captured at the first
later planning write with a known location. It is never reset by successive insertions.
Five minutes is a developer pilot policy: half the pickup target and one-sixth of
the app's existing 30-minute default ride limit. It is not a validated industry
SLA or a user setting. Deadline and maximum ride remain independently evaluated.

If every available route misses timing constraints, automatic dispatch still
assigns the least-violating structurally safe route. Recovery first minimizes
onboard timing overruns, then all delivery/ride/guard overruns, then the finite
pickup/travel cost. Timing misses stay visible as warnings. A newly reported
readiness time is saved even when its deadline is already impossible; reordering
protects onboard work where possible and retains the entire route. The manual
reassignment endpoint retains its stricter feasibility checks.

Fresh known locations are used for ordinary estimates. Stale known locations can
be a warning-bearing fallback. With no GPS at all, the server compares remaining
committed stop counts, assigns deterministically and appends work behind existing
stops. `estimates_available=false` requires clients to hide all numeric route ETA
projections. No fabricated coordinate is stored or displayed. GPS arriving later
makes estimates available; it does not imply traffic-aware travel.

The travel model in this change remains Haversine × 1.3 at 25 km/h. This is a
small-fleet insertion heuristic, not global optimization, live traffic, or a road
network model. Human supervision remains necessary. Server scheduling does not
add APNs: a suspended driver app still cannot receive guaranteed notifications.

## API and retries

- `GET /v1/restaurants`: dispatcher-only list within the caller's team
- `POST /v1/restaurants`: `{name,address,coordinate}` → 201 restaurant; idempotent
- `POST /v1/deliveries`: optional `restaurant_id`; no `ready_at` in new app requests
- `POST /v1/deliveries/{id}/readiness`:
  `{ready_in_minutes:0..120,expected_revision:N}` → updated delivery, possibly assigned

Readiness is separate from delivery progress. Fields are `readiness_state`
(unknown/estimated/ready), `readiness_revision`, `readiness_updated_at`, and the
legacy numeric `ready_at`. Readiness updates are dispatcher/team-authorized before
idempotency replay and allowed only before pickup. Conflicting revisions return
409. Repeating the same key and exact request preserves the original timestamp;
confirming already-ready work also does not restart its pickup clock. Restaurant
creation follows the same team/account-scoped idempotency contract. The app keeps
uncertain restaurant/order creation requests in scoped protected local storage.

Route `warnings` describe invalid/uncertain constraints and determine `feasible`.
Separate `notices` include a missed pickup target without making the route
infeasible. Both arrays need presentation even when execution remains possible.

## Compatibility and rollout

Old stored delivery JSON lacking readiness fields reads as an estimated legacy
`ready_at`, with revision zero. Old create requests with `ready_at` are still
accepted as estimates, and their canonical idempotency request hashes remain
compatible. Legacy pending work is not silently auto-dispatched: an explicit
readiness update opts it into the new automatic flow. Existing assigned/onboard
work, routes and actual completion timestamps remain intact.

Unknown readiness cannot be represented by old clients' required integer field.
The numeric `ready_at` therefore remains a decode-compatibility projection of
creation time while state is unknown; it is not a cooking estimate. Every new
planner/UI readiness decision uses the authoritative state. Older apps can decode
new records but cannot label unknown readiness correctly and must be updated for
this workflow. Unknown assignment/pickup is rejected by the server.

Database schema version 3 prevents an older backend from interpreting unknown
readiness as immediate readiness. Back up and deploy the backend first, then the
app. Rolling back to an older binary requires restoring its compatible verified
backup; never manually lower `user_version`. No deployment or backup execution is
performed by this source change.

Verification covers real HTTP timer assignment after restart without client
polling, readiness/retry races, team/role rejection, restaurant snapshot isolation,
legacy JSON/replay preservation, all-late automatic assignment, full-car sequencing,
unknown GPS, bounded queue fairness and cumulative detour counterexamples. Apple
SDK unit/UI tests and unsigned Release compilation require the exact-head native
CI result; local Rust success does not establish those stages.
