# Implementation notes

## One repository, two account capabilities

The API owns delivery/driver/route state, team membership and permissions. The SwiftUI app is one binary with individual HTTPS login and server-returned dispatcher/driver capabilities, including both on one account. Every account belongs to one private team; all domain queries and mutations are scoped to that authenticated team. The public demo identity picker exists only in explicitly selected Debug demo mode. Screen visibility is convenience only: server authorization is required for every operation. There is no customer-facing marketplace.

`pending → assigned → picked_up → delivered` is the only successful job progression. The dispatcher saves restaurants, creates pending orders and reports readiness; the server automatically assigns when ready; the assigned driver alone reports pickup and drop-off, in the committed route order. Errors leave persisted state unchanged. All writes affecting planning must be checked and committed atomically so overlapping assignments cannot overbook a driver.

SQLite stores delivery fields and actual status timestamps, driver shift/capacity/current location, and ordered stop assignments. Datetimes crossing the API are UTC Unix seconds; the app shows them in the device's locale/time zone. Capacity represents load units, not number of total jobs; delivered packages stop occupying space.

## Planner model

Each job contributes a pickup and a drop-off. For each candidate active driver with a location reported in the last five minutes, insert that pair at every legal ordered position in their existing route. Simulate the route from the driver's current point and current time, accounting for:

- current onboard load and actual pickup time of packages already collected
- travel between stop coordinates
- waiting for pickup readiness
- a 60-second handling allowance at each stop
- pickup-before-drop-off and capacity at every stop
- drop-off service start by the deadline
- maximum elapsed time between pickup and drop-off

Choose using finite pickup-ready waiting and ten-minute-lateness penalties alongside added travel and onboard delay, with deterministic ties. Automatic assignment prefers feasible routes, otherwise commits the least-violating timing route with explicit warnings; physical capacity and precedence remain mandatory. Manual reassignment remains stricter. The five-minute cumulative onboard-delay guard is captured once, not reset by each insertion. See [the complete policy](readiness-and-dispatch.md). Reassignment also compares the previous driver's remaining route with its baseline and rejects newly introduced violations; existing warnings may remain so already-stale or late work can be recovered. A committed route is retained when later time changes make it late, and feasibility warnings surface the problem. Readiness edits atomically reinsert the affected pair. A bounded rotating server sweep runs every five seconds and after shift/location changes, without depending on mobile polling. No-GPS assignments append behind existing work, with estimates_available=false.

The default travel model is `Haversine distance × 1.3` at `25 km/h`. The optional [embedded OSRM backend](embedded-routing.md) injects a precomputed directed driving-time matrix, preserving unreachable nulls and explicitly labelling partial/whole approximate fallback. One native worker owns the engine; each driver-and-stops matrix is reused across all candidate insertions. Native queries run outside SQLite, and its same-process write counter is checked before transactional planning. Concurrent changes cause a bounded fresh-snapshot retry or a 409, including conservative invalidation on another team's write. No schema migration is added by routing. An insertion heuristic can miss a feasible or cheaper global reshuffle; the API must not claim optimality.

## Mobile lifecycle

The driver starts an explicit shift and opts into location permission. Location reports send the current point only while the driver shift is active and sharing is enabled. Foreground polling refreshes server state every five seconds; foreground re-entry and writes trigger refreshes. An explicit background-sharing control supports phone locking or switching to Maps using the location background mode and a visible system indicator. Ending a shift/signing out stops local updates. Ending a shift with active work is rejected to avoid stranded jobs.

This background code path is unverified on a physical device. Standard Core Location is not a guarantee of recovery after force-quit, termination or reboot. Do not claim the sketch is a reliable fleet tracker until device/network/battery tests are complete. Apple's [background-update API documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates) explains the capability and foreground-start requirements; its [authorization guidance](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services) distinguishes continuous When In Use updates from Always authorization and limited relaunch behavior.

UI testing uses an explicit launch flag to provide a fixed Pachino coordinate without requesting simulator GPS permission. The ordinary app requests real foreground location and never substitutes a made-up location silently. The backend still uses real HTTP and SQLite for UI tests.

## API evolution

See `api-contract.md`. The native app uses operator-provisioned or invite-created Argon2id accounts and expiring opaque sessions; the API enforces roles and driver ownership. Create/assign/status endpoints support scoped idempotency keys. A future web app still needs its own session/UI design and narrowly scoped CORS. Team isolation and dual-role accounts are documented in [Teams and App Review](teams-and-review.md). Event versions, broader abuse protection, audit, retention and multi-instance concurrency remain outside this supervised pilot. Read the pilot runbook for deployment and interruption checks.

