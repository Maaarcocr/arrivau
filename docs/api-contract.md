# Arrivau API v1

API base: `http://127.0.0.1:8080`. JSON uses snake_case. Timestamps are UTC Unix seconds (integers), coordinates decimal degrees. IDs are strings. All routes except `GET /health` require `Authorization: Bearer <token>`.

Demo-only principals (enabled explicitly by `ARRIVAU_DEMO=1`): token `demo-dispatcher` has dispatcher role; `demo-driver-1` / `demo-driver-2` have driver role and matching IDs `driver-1` / `driver-2`. Production authentication is intentionally not implemented: server must refuse startup unless demo mode is explicitly enabled. Bind loopback by default. Never use these tokens or plain HTTP outside local development.

Responses below are complete stable contracts. API errors: `{"error":"human-readable reason"}` with suitable 400/401/403/404/409/422 status.

- `GET /health` → `{"status":"ok"}`
- `GET /v1/me` → `{"id":"dispatcher-1","name":"Dispatcher","role":"dispatcher"}` (driver principals use matching IDs and name `Driver 1` etc.)
- `GET /v1/drivers` (dispatcher) → array of Driver
- `GET /v1/shift` (driver) → caller Driver, including persisted shift/location state
- `POST /v1/shift` (driver) body `{"active":true,"capacity":2}` → Driver. Capacity integer 1–8. Ending a shift with assigned/onboard work is rejected (409).
- `POST /v1/location` (driver) body `{"lat":36.7163,"lng":15.0908}` → Driver. Active shift required.
- `GET /v1/deliveries` → array of Delivery; dispatcher sees all, driver sees their own only
- `POST /v1/deliveries` (dispatcher) → 201 Delivery. Body: `{"shop_name":"Pizzeria","pickup_address":"Via Roma 1, Pachino","pickup":{"lat":36.7163,"lng":15.0908},"dropoff_address":"Via Garibaldi 8, Pachino","dropoff":{"lat":36.7210,"lng":15.1000},"ready_at":1790874000,"deadline_at":1790877600,"load_units":1,"max_ride_seconds":1800}`. Validate nonempty bounded text, valid finite coordinates, deadline >= ready, load 1–8, max ride 60–7200 seconds. Created job initially pending and unassigned.
- `POST /v1/deliveries/{id}/assign` (dispatcher) body `{"driver_id":"driver-1"}` → Delivery. Active shift/location reported within the last 300 seconds required; target driver's whole proposed route must be feasible before commit. Reassignment also rejects newly introduced violations in the previous driver's remaining route, while allowing already-present warnings so dispatch can recover work from stale or late routes. At most 32 outstanding stops per driver. Cannot reassign picked-up/completed jobs; return 409/422 rather than silently violating constraints.
- `POST /v1/deliveries/{id}/status` (assigned driver only) body `{"status":"picked_up"}` or `{"status":"delivered"}` → Delivery. State transitions only assigned→picked_up→delivered. Pickup before ready_at rejected; delivery before pickup rejected. Driver may only act on their currently suggested next stop (409 otherwise), so app/route do not drift.
- `GET /v1/route` (driver) → Route for caller
- `GET /v1/drivers/{id}/route` (dispatcher) → Route
- `GET /v1/deliveries/{id}/suggestions` (dispatcher) → array of Suggestion, feasible active drivers sorted by incremental travel seconds. Infeasible drivers and drivers whose location is older than 300 seconds are omitted.

Driver: `{"id":"driver-1","name":"Driver 1","active":true,"capacity":2,"location":{"lat":36.7163,"lng":15.0908},"location_updated_at":1790874000}`. location and location_updated_at can be null. Start/stop shift and location updates persisted.

Delivery: all POST fields above plus `{"id":"...","status":"pending","driver_id":null,"created_at":1790874000,"picked_up_at":null,"delivered_at":null}`. status enum pending/assigned/picked_up/delivered. driver_id and completion timestamps nullable.

Route: `{"driver_id":"driver-1","stops":[{"delivery_id":"...","kind":"pickup","address":"...","coordinate":{"lat":36.7163,"lng":15.0908},"arrival_at":1790874000,"departure_at":1790874060}],"travel_seconds":180,"finish_at":1790874240,"feasible":true,"warnings":[]}`. kind pickup/dropoff. Stops ordered for execution. Arrival_at includes readiness wait (scheduled service start); departure includes 60 second handling time. Deadline/freshness tested at dropoff arrival. Travel model is explicitly approximate Haversine × 1.3, 25 km/h constant; route heuristic does not claim road/traffic optimum. If a committed route is infeasible due to time passing or its driver location is more than 300 seconds old, `feasible=false` and warnings, retaining executable stops; don't silently hide work. Empty route has stops [] and feasible true.

Suggestion: `{"driver_id":"driver-1","incremental_travel_seconds":180,"route":{...}}`.

The app refreshes every 5 seconds while foregrounded, plus after writes. Push, real road travel matrices and production login are future integrations. Location reporting is opt-in while on shift, with an explicit background Core Location capability/code path for locking the phone or using Maps; device execution is unverified. Stopping shift/signing out stops updates. UI simulator can opt into deterministic location through launch argument `--uitesting` only, using local demo tokens. No customer contact/payment details are collected.
