import XCTest
import Combine
@testable import Arrivau

/// Pilot authentication and durable recovery without real credentials, Keychain, or network access.
/// Run with the Debug ArrivauTests scheme on an iOS simulator; these are not physical-device tests.
@MainActor
final class PilotSessionTests: XCTestCase {
    private let endpoint = "https://pilot.arrivau.example"
    private var session: URLSession!
    private var backend: PilotSessionBackend!
    private var storage: MemorySessionStorage!
    private var store: DeliveryStore!
    private var stores: [DeliveryStore] = []

    override func setUp() async throws {
        try await super.setUp()
        backend = PilotSessionBackend()
        PilotSessionURLProtocol.backend = backend
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PilotSessionURLProtocol.self]
        session = URLSession(configuration: configuration)
        storage = MemorySessionStorage()
        store = makeStore()
    }

    override func tearDown() async throws {
        stores.forEach { $0.logout() }
        // URLSession throws an Objective-C exception if a queued logout task tries to
        // create its request after invalidation. Join every store's revocations first.
        for value in stores { await value.awaitPendingRevocations() }
        stores.removeAll()
        store = nil
        session.invalidateAndCancel()
        PilotSessionURLProtocol.backend = nil
        backend = nil
        storage = nil
        try await super.tearDown()
    }

    private func makeStore(storage supplied: SessionStorage? = nil) -> DeliveryStore {
        let result = DeliveryStore(session: session, deterministicLocation: true, mode: .pilot,
                                   storage: supplied ?? storage)
        result.apiURL = endpoint
        stores.append(result)
        return result
    }

    private func seedSavedSession(expiresAt: Int? = nil, token: String = "saved-pilot-token") {
        storage.savedSession = SavedSession(endpoint: endpoint, token: token,
                                            expiresAt: expiresAt ?? Int(Date().timeIntervalSince1970) + 3600)
    }

    private func assertSignedOut(_ value: DeliveryStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value.principal, file: file, line: line)
        XCTAssertNil(value.role, file: file, line: line)
        XCTAssertNil(value.currentDriver, file: file, line: line)
        XCTAssertNil(value.route, file: file, line: line)
        XCTAssertTrue(value.deliveries.isEmpty, file: file, line: line)
        XCTAssertTrue(value.drivers.isEmpty, file: file, line: line)
        XCTAssertFalse(value.locationSharing, file: file, line: line)
        XCTAssertFalse(value.backgroundLocationSharing, file: file, line: line)
        XCTAssertFalse(value.isMutating, file: file, line: line)
        XCTAssertFalse(value.isRestoringSession, file: file, line: line)
        XCTAssertNil(storage.savedSession, file: file, line: line)
    }

    private func useDualAccount(team: String = "review") {
        backend.withState {
            $0.user = Principal(id: "reviewer", name: "Revisione", role: "dispatcher",
                                roles: ["dispatcher", "driver"], teamId: team, teamName: "Squadra \(team)")
        }
    }

    private func teamDelivery(id: String, owner: String?, status: DeliveryStatus = .assigned) -> Delivery {
        Delivery(id: id, shopName: "Pizzeria", pickupAddress: "Via Roma 1", pickup: .pachino,
                 dropoffAddress: "Via Garibaldi 8", dropoff: .pachino, readyAt: 1, deadlineAt: 2_000_000_000,
                 loadUnits: 1, maxRideSeconds: 1800, status: status, driverId: owner,
                 createdAt: 1, pickedUpAt: nil, deliveredAt: nil)
    }

    func testPrivacyPolicyUsesSelectedThenAuthenticatedOriginWithoutCredentials() async {
        XCTAssertEqual(store.privacyPolicyURL?.absoluteString, endpoint + "/privacy")
        store.apiURL = "https://user:password@other.example/?token=secret"
        XCTAssertNil(store.privacyPolicyURL)
        store.apiURL = endpoint
        await store.login(username: "driver", password: "test-only-password")
        XCTAssertNotNil(store.principal)
        store.apiURL = "https://other.example"
        XCTAssertEqual(store.privacyPolicyURL?.absoluteString, endpoint + "/privacy")
        store.logout()
        XCTAssertEqual(store.privacyPolicyURL?.absoluteString, "https://other.example/privacy")
    }

    func testDualViewsUseOneSessionAndNeverStartShiftOrTrackingOnTheirOwn() async {
        useDualAccount()
        await store.login(username: "reviewer", password: "test-only-password")
        let saved = storage.savedSession
        XCTAssertEqual(store.role, .dispatcher)
        XCTAssertEqual(store.availableRoles, [.dispatcher, .driver])
        XCTAssertTrue(store.canSwitchRole)
        XCTAssertEqual(store.principal?.teamTitle, "Squadra review")
        for _ in 0..<3 {
            XCTAssertTrue(store.switchRole(to: .driver))
            await store.refresh(force: true)
            XCTAssertEqual(store.currentDriver?.id, "reviewer")
            XCTAssertFalse(store.locationSharing)
            XCTAssertFalse(store.backgroundLocationSharing)
            XCTAssertFalse(store.switchRole(to: .driver), "Repeated selection is a no-op")
            XCTAssertTrue(store.switchRole(to: .dispatcher))
            await store.refresh(force: true)
        }
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertEqual(backend.withState { $0.requests.filter { $0.method == "POST" && $0.path == "/v1/session" }.count }, 1)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "POST" && ["/v1/shift", "/v1/location"].contains($0.path) } })
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
    }

    func testOlderInactiveRefreshCannotRevokePendingNewStartConsent() async {
        await assertInactiveRefreshDuringNewStart(explicitStop: false)
    }

    func testExplicitStopStillRevokesNewStartConsentAfterOlderInactiveRefresh() async {
        await assertInactiveRefreshDuringNewStart(explicitStop: true)
    }

    private func assertInactiveRefreshDuringNewStart(explicitStop: Bool) async {
        backend.withState {
            $0.user = Principal(id: "driver-a", name: "Corriere", role: "driver")
        }
        await store.login(username: "driver-a", password: "test-only-password")
        XCTAssertEqual(store.currentDriver?.active, false)
        let readStarted = expectation(description: "Old inactive shift read captured")
        let shiftStarted = expectation(description: "New shift committed with response pending")
        let releaseRead = DispatchSemaphore(value: 0)
        let releaseShift = DispatchSemaphore(value: 0)
        defer { releaseRead.signal(); releaseShift.signal() }
        backend.withState {
            $0.nextReadPath = "/v1/shift"
            $0.nextReadGate = releaseRead
            $0.onNextRead = { readStarted.fulfill() }
            $0.shiftGate = releaseShift
            $0.onShift = { shiftStarted.fulfill() }
        }
        let oldRefresh = Task { await store.refresh(force: true) }
        await fulfillment(of: [readStarted], timeout: 5)
        let newStart = Task { await store.startShiftAndShareLocation() }
        await fulfillment(of: [shiftStarted], timeout: 5)
        XCTAssertTrue(store.isMutating)
        releaseRead.signal()
        await oldRefresh.value
        XCTAssertEqual(store.currentDriver?.active, false, "The older inactive response must apply before the POST returns")
        XCTAssertTrue(backend.withState { $0.active }, "The server already started the shift")
        if explicitStop { store.setLocationSharing(false) }
        releaseShift.signal()
        await newStart.value
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertEqual(store.locationSharing, !explicitStop)
        XCTAssertEqual(store.backgroundLocationSharing, !explicitStop)
        XCTAssertEqual(backend.withState {
            $0.requests.filter { $0.method == "POST" && $0.path == "/v1/shift" }.count
        }, 1)
    }

    func testLegacyForegroundOnlyConsentSurvivesDualViewsWithoutExpansion() async {
        useDualAccount()
        backend.withState { $0.active = true }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        store.setLocationSharing(true)
        for _ in 0..<3 {
            XCTAssertTrue(store.switchRole(to: .dispatcher))
            await store.refresh(force: true)
            store.setForeground(false)
            XCTAssertTrue(store.locationSharing)
            XCTAssertFalse(store.backgroundLocationSharing)
            XCTAssertTrue(store.switchRole(to: .driver))
            await store.refresh(force: true)
            await store.startShiftAndShareLocation()
            XCTAssertFalse(store.backgroundLocationSharing)
        }
        store.logout()
        XCTAssertTrue(backend.withState { $0.active }, "Logout must not end the server shift")
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "POST" && $0.path == "/v1/shift" } })
    }

    func testExplicitDriverSharingSurvivesViewsAndInterruptionUntilStopped() async throws {
        useDualAccount()
        let own = teamDelivery(id: "own", owner: "reviewer")
        let other = teamDelivery(id: "other", owner: "another-driver")
        backend.withState { $0.active = true; $0.jobs = [own, other] }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertEqual(Set(store.deliveries.map(\.id)), ["own", "other"])
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        XCTAssertEqual(store.deliveries.map(\.id), ["own"])
        let ownRoute = try XCTUnwrap(store.route)
        XCTAssertEqual(ownRoute.driverId, "reviewer")
        XCTAssertEqual(ownRoute.stops.map(\.deliveryId), ["own", "own"])
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        for _ in 0..<2 {
            XCTAssertTrue(store.switchRole(to: .dispatcher))
            await store.refresh(force: true)
            XCTAssertTrue(store.locationSharing)
            XCTAssertTrue(store.backgroundLocationSharing)
            XCTAssertEqual(store.currentDriver?.active, true)
            XCTAssertEqual(store.route, ownRoute)
            store.setForeground(false)
            XCTAssertTrue(store.locationSharing)
            XCTAssertTrue(store.backgroundLocationSharing)
            XCTAssertTrue(store.switchRole(to: .driver))
            await store.refresh(force: true)
            XCTAssertEqual(store.deliveries, [own])
        }
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        store.setLocationSharing(false)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertTrue(store.switchRole(to: .driver))
        XCTAssertFalse(store.locationSharing)
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertEqual(store.route, ownRoute)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "POST" && $0.path == "/v1/shift" } })
    }

    func testOwnDriverActionsCannotRunFromHiddenOrUnauthorizedView() async throws {
        useDualAccount()
        let own = teamDelivery(id: "own", owner: "reviewer")
        backend.withState { $0.active = true; $0.jobs = [own] }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        let before = backend.withState { $0.requests.count }
        let created = await store.create(Fixtures.newDelivery)
        let assigned = await store.assign(deliveryId: "own", driverId: "reviewer")
        let suggestions = await store.suggestions(for: "own")
        XCTAssertNil(created); XCTAssertFalse(assigned); XCTAssertNil(suggestions)
        XCTAssertEqual(backend.withState { $0.requests.count }, before)
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        await store.completeNextStop(own)
        await store.setShift(active: false, capacity: 5)
        await store.startShiftAndShareLocation()
        store.setLocationSharing(true)
        XCTAssertFalse(store.locationSharing, "Only the visible driver action can opt in")
        XCTAssertEqual(backend.withState { $0.requests.count }, before)
        XCTAssertEqual(store.route?.stops.first?.kind, .pickup)
        XCTAssertEqual(store.currentDriver?.active, true)
    }

    func testDualDispatcherLogoutImmediatelyStopsDriverOptInsAndLateSamples() async {
        useDualAccount()
        backend.withState { $0.active = true }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        XCTAssertTrue(store.locationSharing)
        store.logout()
        assertSignedOut(store)
        let writes = backend.withState { $0.locationWrites }
        store.location.onCoordinate?(.pachino)
        await store.awaitPendingRevocations()
        XCTAssertEqual(backend.withState { $0.locationWrites }, writes)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
        XCTAssertFalse(store.switchRole(to: .driver))
    }

    func testDualDispatcherExpiryStopsSharingWithoutNavigation() async {
        useDualAccount()
        backend.withState { $0.active = true; $0.expiresAt = Int(Date().timeIntervalSince1970) + 3 }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        let invalidated = expectation(description: "Dual dispatcher expiry stops driver sharing")
        let observation = store.$principal.dropFirst().filter { $0 == nil }.sink { _ in invalidated.fulfill() }
        await fulfillment(of: [invalidated], timeout: 6)
        observation.cancel()
        assertSignedOut(store)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
    }

    func testSingleRoleCannotSelectUnassignedCapability() async {
        for assigned in [UserRole.dispatcher, .driver] {
            let candidate = makeStore()
            backend.withState { $0.user = Principal(id: "single", name: "Solo", role: assigned.rawValue) }
            await candidate.login(username: "single", password: "test-only-password")
            XCTAssertFalse(candidate.canSwitchRole)
            XCTAssertFalse(candidate.switchRole(to: assigned == .driver ? .dispatcher : .driver))
            XCTAssertEqual(candidate.role, assigned)
            candidate.logout()
        }
    }

    func testDelayedRefreshCannotSignOutOrReplaceNewView() async {
        useDualAccount()
        await store.login(username: "reviewer", password: "test-only-password")
        let started = expectation(description: "Old dispatcher refresh sent")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.nextReadPath = "/v1/drivers"; $0.nextReadStatus = 401
            $0.nextReadGate = release; $0.onNextRead = { started.fulfill() }
        }
        let old = Task { await store.refresh(force: true) }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        let ownRoute = store.route
        release.signal()
        await old.value
        XCTAssertEqual(store.role, .driver)
        XCTAssertEqual(store.principal?.id, "reviewer")
        XCTAssertEqual(store.route, ownRoute)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.syncErrorMessage)
    }

    func testHiddenSuggestionsCannotSignOutAfterRepeatedViewChanges() async {
        useDualAccount()
        // Suggestions now require a locally known, eligible delivery. Seed it before
        // login so this test still exercises a real delayed unauthorized response.
        let pending = teamDelivery(id: "pending", owner: nil, status: .pending)
        backend.withState { $0.jobs = [pending] }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertEqual(store.deliveries, [pending])
        XCTAssertTrue(pending.hasKnownReadiness)
        let started = expectation(description: "Old suggestions sent")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.nextReadPath = "/v1/deliveries/pending/suggestions"; $0.nextReadStatus = 401
            $0.nextReadGate = release; $0.onNextRead = { started.fulfill() }
        }
        let old = Task { await store.suggestions(for: "pending") }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.switchRole(to: .driver))
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        release.signal()
        let result = await old.value
        XCTAssertNil(result)
        XCTAssertEqual(backend.withState {
            $0.requests.filter { $0.method == "GET" && $0.path == "/v1/deliveries/pending/suggestions" }.count
        }, 1, "The stale 401 must actually have reached the transport")
        XCTAssertEqual(store.role, .dispatcher)
        XCTAssertEqual(store.principal?.id, "reviewer")
        XCTAssertNil(store.errorMessage)
    }

    func testSwitchDuringCreateWaitsAndLateResultCannotRestoreLoggedOutTeam() async throws {
        useDualAccount()
        await store.login(username: "reviewer", password: "test-only-password")
        let started = expectation(description: "Create sent")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.createGate = release; $0.onCreate = { started.fulfill() } }
        let create = Task { await store.create(Fixtures.newDelivery) }
        await fulfillment(of: [started], timeout: 5)
        let pending = try XCTUnwrap(store.pendingCreation)
        XCTAssertFalse(store.switchRole(to: .driver), "Do not interrupt a mutation with hidden navigation")
        XCTAssertEqual(store.role, .dispatcher)
        store.logout()
        await store.awaitPendingRevocations()
        useDualAccount(team: "other")
        await store.login(username: "reviewer", password: "test-only-password")
        release.signal()
        let result = await create.value
        XCTAssertNil(result)
        XCTAssertEqual(store.principal?.teamId, "other")
        XCTAssertTrue(store.deliveries.isEmpty)
        XCTAssertNil(store.pendingCreation)
        XCTAssertTrue(storage.creations.values.contains(pending))
    }

    func testPendingCreationSurvivesViewsButCannotCrossTeamWithSameAccountID() async throws {
        useDualAccount()
        await store.login(username: "reviewer", password: "test-only-password")
        backend.withState { $0.lostCreateResponses = 1 }
        _ = await store.create(Fixtures.newDelivery)
        let pending = try XCTUnwrap(store.pendingCreation)
        let scope = CreationScope.current(endpoint: endpoint, user: try XCTUnwrap(store.principal))
        XCTAssertEqual(storage.creations[scope], pending)
        XCTAssertTrue(store.switchRole(to: .driver))
        let hiddenRetry = await store.retryPendingCreation()
        XCTAssertNil(hiddenRetry)
        XCTAssertEqual(store.pendingCreation, pending)
        store.logout()
        await store.awaitPendingRevocations()
        useDualAccount(team: "other")
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertNil(store.pendingCreation)
        XCTAssertFalse(store.legacyCreationNeedsReview)
        XCTAssertTrue(store.deliveries.isEmpty)
        store.logout()
        await store.awaitPendingRevocations()
        useDualAccount()
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertEqual(store.pendingCreation, pending)
        let replay = await store.retryPendingCreation()
        XCTAssertEqual(replay?.id, "created-1")
        XCTAssertEqual(backend.withState { $0.committedCreates }, 1)
        XCTAssertTrue(storage.creations.isEmpty)
    }

    func testLegacyPendingCreationIsQuarantinedWhenTeamCannotBeProven() async {
        useDualAccount()
        let pending = PendingCreation(idempotencyKey: "legacy-request", delivery: Fixtures.newDelivery)
        let scope = CreationScope.legacy(endpoint: endpoint, accountId: "reviewer")
        storage.creations[scope] = pending
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertTrue(store.legacyCreationNeedsReview)
        XCTAssertNil(store.pendingCreation, "An unscoped request must not become replayable in a team")
        XCTAssertEqual(store.legacyPendingCreation, pending, "Original details remain available for operator review")
        let result = await store.create(Fixtures.newDelivery)
        let retry = await store.retryPendingCreation()
        XCTAssertNil(result); XCTAssertNil(retry)
        XCTAssertEqual(storage.creations[scope], pending, "Never silently discard uncertain work")
        XCTAssertEqual(backend.withState { $0.createAttempts }, 0)
    }

    func testLegacyReviewPreparationOrCancellationDoesNotClearOrTransmit() async throws {
        useDualAccount()
        let pending = PendingCreation(idempotencyKey: "legacy-request", delivery: Fixtures.newDelivery)
        let scope = CreationScope.legacy(endpoint: endpoint, accountId: "reviewer")
        storage.creations[scope] = pending
        await store.login(username: "reviewer", password: "test-only-password")
        let requests = backend.withState { $0.requests.count }
        let review = try XCTUnwrap(store.prepareLegacyCreationReview())
        XCTAssertEqual(review.pending, pending)
        // Dismissing the confirmation simply drops this value: there is no destructive preparation.
        XCTAssertTrue(store.legacyCreationNeedsReview)
        XCTAssertEqual(storage.creations[scope], pending)
        XCTAssertEqual(backend.withState { $0.requests.count }, requests)
    }

    func testConfirmedLegacyReviewClearsOnlyTheDisplayedLocalRecord() async throws {
        useDualAccount()
        let pending = PendingCreation(idempotencyKey: "legacy-request", delivery: Fixtures.newDelivery)
        let scope = CreationScope.legacy(endpoint: endpoint, accountId: "reviewer")
        storage.creations[scope] = pending
        storage.creations["unrelated-account"] = pending
        await store.login(username: "reviewer", password: "test-only-password")
        let requests = backend.withState { $0.requests.count }
        let review = try XCTUnwrap(store.prepareLegacyCreationReview())
        XCTAssertTrue(store.clearLegacyCreationAfterReview(review))
        XCTAssertFalse(store.legacyCreationNeedsReview)
        XCTAssertNil(storage.creations[scope])
        XCTAssertEqual(storage.creations["unrelated-account"], pending)
        XCTAssertFalse(store.clearLegacyCreationAfterReview(review), "A repeated confirmation does nothing")
        XCTAssertEqual(backend.withState { $0.requests.count }, requests, "No server work is deleted or replayed")
    }

    func testLegacyClearStorageFailureKeepsRecoveryBlockedAndCanRetrySameReview() async throws {
        useDualAccount()
        let pending = PendingCreation(idempotencyKey: "legacy-request", delivery: Fixtures.newDelivery)
        let scope = CreationScope.legacy(endpoint: endpoint, accountId: "reviewer")
        storage.creations[scope] = pending
        let failing = FaultingPilotStorage(base: storage)
        failing.failCreationClear = true
        let candidate = makeStore(storage: failing)
        await candidate.login(username: "reviewer", password: "test-only-password")
        let review = try XCTUnwrap(candidate.prepareLegacyCreationReview())
        XCTAssertFalse(candidate.clearLegacyCreationAfterReview(review))
        XCTAssertTrue(candidate.legacyCreationNeedsReview)
        XCTAssertEqual(storage.creations[scope], pending)
        XCTAssertNotNil(candidate.errorMessage)
        let blocked = await candidate.create(Fixtures.newDelivery)
        XCTAssertNil(blocked)
        XCTAssertEqual(backend.withState { $0.createAttempts }, 0)
        failing.failCreationClear = false
        XCTAssertTrue(candidate.clearLegacyCreationAfterReview(review))
        XCTAssertFalse(candidate.legacyCreationNeedsReview)
    }

    func testLegacyConfirmationFromEarlierSessionCannotClearOtherTeam() async throws {
        useDualAccount()
        let pending = PendingCreation(idempotencyKey: "legacy-request", delivery: Fixtures.newDelivery)
        let scope = CreationScope.legacy(endpoint: endpoint, accountId: "reviewer")
        storage.creations[scope] = pending
        await store.login(username: "reviewer", password: "test-only-password")
        let review = try XCTUnwrap(store.prepareLegacyCreationReview())
        XCTAssertTrue(store.switchRole(to: .driver))
        XCTAssertFalse(store.clearLegacyCreationAfterReview(review))
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        XCTAssertFalse(store.clearLegacyCreationAfterReview(review), "An old confirmation cannot reappear after a round trip")
        store.logout()
        await store.awaitPendingRevocations()
        useDualAccount(team: "other")
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertFalse(store.clearLegacyCreationAfterReview(review))
        XCTAssertTrue(store.legacyCreationNeedsReview)
        XCTAssertEqual(storage.creations[scope], pending)
        let changed = PendingCreation(idempotencyKey: "newer-request", delivery: Fixtures.newDelivery)
        let currentReview = try XCTUnwrap(store.prepareLegacyCreationReview())
        storage.creations[scope] = changed
        XCTAssertFalse(store.clearLegacyCreationAfterReview(currentReview))
        XCTAssertEqual(storage.creations[scope], changed, "Do not delete a record changed since it was displayed")
        XCTAssertTrue(store.legacyCreationNeedsReview)
    }

    func testDualRestoreResetsViewAndLocationConsentAndRechecksCapabilities() async {
        useDualAccount()
        backend.withState { $0.active = true }
        await store.login(username: "reviewer", password: "test-only-password")
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        let restored = makeStore()
        await restored.restoreSession()
        XCTAssertEqual(restored.role, .dispatcher)
        XCTAssertTrue(restored.canSwitchRole)
        XCTAssertFalse(restored.locationSharing)
        XCTAssertFalse(restored.backgroundLocationSharing)
        backend.withState { $0.user = Principal(id: "reviewer", name: "Revisione", role: "dispatcher", roles: ["driver"], teamId: "review") }
        let narrowed = makeStore()
        await narrowed.restoreSession()
        XCTAssertEqual(narrowed.role, .driver)
        XCTAssertFalse(narrowed.canSwitchRole)
        XCTAssertFalse(narrowed.switchRole(to: .dispatcher))
        XCTAssertFalse(narrowed.locationSharing)
    }

    func testLoginUsesServerRoleAndPostsOnlyUsernameAndPassword() async throws {
        backend.withState { $0.user = Principal(id: "courier-42", name: "Corriere pilota", role: "driver") }
        await store.login(username: "  dispatcher-looking-name  ", password: "test-only-password")
        XCTAssertEqual(store.role, .driver, "A username must not select or elevate the server-defined role")
        XCTAssertEqual(store.principal?.id, "courier-42")
        XCTAssertFalse(store.isDemo)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        let login = try XCTUnwrap(backend.withState { $0.requests.first { $0.method == "POST" && $0.path == "/v1/session" } })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: login.body) as? [String: String])
        XCTAssertEqual(body, ["username": "dispatcher-looking-name", "password": "test-only-password"])
        XCTAssertNil(login.authorization)
        XCTAssertEqual(login.origin, endpoint)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path == "/v1/me" } })
        let saved = try XCTUnwrap(storage.savedSession)
        XCTAssertEqual(saved.endpoint, endpoint)
        XCTAssertEqual(saved.token, "pilot-token-1")
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertEqual(Set(persisted.keys), Set(["endpoint", "token", "expiresAt"]))
        XCTAssertFalse(String(data: try JSONEncoder().encode(saved), encoding: .utf8)!.contains("test-only-password"))
    }

    func testDispatcherAuthorityAlsoComesFromServer() async {
        await store.login(username: "courier-looking-name", password: "test-only-password")
        XCTAssertEqual(store.role, .dispatcher)
        XCTAssertEqual(store.principal?.id, "dispatcher-a")
        XCTAssertNil(store.currentDriver)
    }

    func testFailedLoginPersistsNeitherTokenNorPassword() async {
        backend.withState { $0.loginStatus = 401 }
        await store.login(username: "dispatcher-a", password: "incorrect-test-secret")
        assertSignedOut(store)
        XCTAssertTrue(storage.creations.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.errorMessage?.contains("incorrect-test-secret") ?? true)
        XCTAssertEqual(backend.withState { $0.requests.count }, 1, "Failed login must not fetch protected data")
    }

    func testInvalidLoginRoleEmptyTokenAndExpiredTokenAreNeverInstalled() async {
        for invalidCase in 0..<3 {
            let candidate = makeStore()
            backend.withState {
                $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: invalidCase == 0 ? "admin" : "dispatcher")
                $0.emptyLoginToken = invalidCase == 1
                $0.expiresAt = Int(Date().timeIntervalSince1970) + (invalidCase == 2 ? -1 : 3600)
            }
            await candidate.login(username: "dispatcher-a", password: "test-only-password")
            assertSignedOut(candidate)
            XCTAssertNotNil(candidate.errorMessage)
        }
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path == "/v1/deliveries" } })
    }

    func testFailedLocalInstallationClearsSavedTokenAndRevokesServerSession() async {
        let failing = FaultingPilotStorage(base: storage)
        failing.failCreationLoad = true
        let candidate = makeStore(storage: failing)
        await candidate.login(username: "dispatcher-a", password: "test-only-password")
        assertSignedOut(candidate)
        XCTAssertNotNil(candidate.errorMessage)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer pilot-token-1"])
    }

    func testRestoreValidatesSavedTokenAndUsesServerIdentityWithoutLocationOptIn() async throws {
        seedSavedSession()
        backend.withState {
            $0.user = Principal(id: "courier-42", name: "Corriere pilota", role: "driver")
            $0.active = true
        }
        await store.restoreSession()
        XCTAssertEqual(store.principal?.id, "courier-42")
        XCTAssertEqual(store.role, .driver)
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertFalse(store.canRetryRestore)
        let identity = try XCTUnwrap(backend.withState { $0.requests.first })
        XCTAssertEqual(identity.method, "GET")
        XCTAssertEqual(identity.path, "/v1/session")
        XCTAssertEqual(identity.authorization, "Bearer saved-pilot-token")
        XCTAssertEqual(storage.savedSession?.token, "saved-pilot-token")
        XCTAssertEqual(storage.savedSession?.expiresAt, backend.withState { $0.expiresAt })
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.method == "POST" && $0.path == "/v1/session" } })
        await store.restoreSession()
        XCTAssertEqual(backend.withState { $0.requests.filter { $0.method == "GET" && $0.path == "/v1/session" }.count }, 1)
    }

    func testExpiredOrEmptySavedTokenIsClearedWithoutNetworkAccess() async {
        for expired in [true, false] {
            let candidate = makeStore()
            seedSavedSession(expiresAt: Int(Date().timeIntervalSince1970) + (expired ? -1 : 3600),
                             token: expired ? "expired-test-token" : "")
            await candidate.restoreSession()
            assertSignedOut(candidate)
            XCTAssertFalse(candidate.canRetryRestore)
        }
        XCTAssertTrue(backend.withState { $0.requests.isEmpty })
    }

    func testRevokedSavedSessionIsClearedAndCannotRetryRestore() async {
        seedSavedSession()
        backend.withState { $0.identityStatus = 401 }
        await store.restoreSession()
        assertSignedOut(store)
        XCTAssertFalse(store.canRetryRestore)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(backend.withState { $0.requests.count }, 1)
    }

    func testInvalidRestoredRoleMissingExpiryAndExpiredIdentityAreCleared() async {
        for invalidCase in 0..<3 {
            let candidate = makeStore()
            seedSavedSession()
            backend.withState {
                $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: invalidCase == 0 ? "admin" : "dispatcher")
                $0.omitIdentityExpiry = invalidCase == 1
                $0.expiresAt = Int(Date().timeIntervalSince1970) + (invalidCase == 2 ? -1 : 3600)
            }
            await candidate.restoreSession()
            assertSignedOut(candidate)
            XCTAssertFalse(candidate.canRetryRestore)
        }
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path == "/v1/deliveries" } })
    }

    func testTemporaryRestoreFailureKeepsTokenWithoutGrantingAuthorityAndCanRetry() async {
        seedSavedSession()
        backend.withState { $0.identityStatus = 503 }
        await store.restoreSession()
        XCTAssertNil(store.principal)
        XCTAssertNil(store.role)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertTrue(store.canRetryRestore)
        XCTAssertEqual(storage.savedSession?.token, "saved-pilot-token")
        backend.withState { $0.identityStatus = 200 }
        await store.restoreSession(retry: true)
        XCTAssertEqual(store.role, .dispatcher)
        XCTAssertFalse(store.canRetryRestore)
        XCTAssertNil(store.errorMessage)
    }

    func testRevokedRunningSessionStopsLocationAndClearsProtectedState() async {
        backend.withState {
            $0.user = Principal(id: "courier-42", name: "Corriere pilota", role: "driver")
            $0.active = true
        }
        await store.login(username: "courier-42", password: "test-only-password")
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        XCTAssertTrue(store.locationSharing)
        XCTAssertTrue(store.backgroundLocationSharing)
        backend.withState { $0.rejectProtectedReads = true }
        await store.refresh(force: true)
        assertSignedOut(store)
        XCTAssertNil(store.lastSyncedAt)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
        XCTAssertNotNil(store.errorMessage)
    }

    func testExpiryTimerInvalidatesSessionWithoutAnotherUserAction() async {
        backend.withState {
            $0.user = Principal(id: "courier-42", name: "Corriere pilota", role: "driver")
            $0.active = true
            $0.expiresAt = Int(Date().timeIntervalSince1970) + 3
        }
        await store.login(username: "courier-42", password: "test-only-password")
        XCTAssertNotNil(store.principal)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        let invalidated = expectation(description: "Scheduled expiry clears the principal")
        let observation = store.$principal.dropFirst().filter { $0 == nil }.sink { _ in invalidated.fulfill() }
        await fulfillment(of: [invalidated], timeout: 6)
        observation.cancel()
        assertSignedOut(store)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
    }

    func testLogoutStopsLocationImmediatelyAndRevokesTheSameBearer() async {
        backend.withState {
            $0.user = Principal(id: "courier-42", name: "Corriere pilota", role: "driver")
            $0.active = true
        }
        await store.login(username: "courier-42", password: "test-only-password")
        let locationSent = expectation(description: "Opted-in location reaches test server")
        let revoked = expectation(description: "Logout revokes server session")
        backend.withState { $0.onLocation = { locationSent.fulfill() }; $0.onRevoke = { revoked.fulfill() } }
        store.setForeground(true)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        await fulfillment(of: [locationSent], timeout: 5)
        store.logout()
        assertSignedOut(store)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
        let writes = backend.withState { $0.locationWrites }
        store.location.onCoordinate?(.pachino)
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertEqual(backend.withState { $0.locationWrites }, writes, "Late sensor callbacks must not send after logout")
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer pilot-token-1"])
    }

    func testBackgroundLocationConflictStopsBothOptInsWithoutSigningOut() async {
        backend.withState {
            $0.user = Principal(id: "courier-42", name: "Corriere pilota", role: "driver")
            $0.active = true
            $0.locationStatus = 409
        }
        await store.login(username: "courier-42", password: "test-only-password")
        store.setForeground(true)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        store.setForeground(false)
        XCTAssertTrue(store.locationSharing)
        XCTAssertTrue(store.backgroundLocationSharing)
        let stopped = expectation(description: "Background location conflict disables sharing")
        let observation = store.$locationSharing.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        observation.cancel()
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
        XCTAssertEqual(store.principal?.id, "courier-42")
        XCTAssertNotNil(storage.savedSession)
        let writes = backend.withState { $0.locationWrites }
        XCTAssertEqual(writes, 1)
        store.location.onCoordinate?(.pachino)
        XCTAssertEqual(backend.withState { $0.locationWrites }, writes)
    }

    func testDelayedLoginAfterLogoutCannotRestoreUserOrPersistToken() async {
        let started = expectation(description: "Server receives login")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.onLogin = { started.fulfill() }; $0.loginGate = release }
        let login = Task { await store.login(username: "dispatcher-a", password: "test-only-password") }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        assertSignedOut(store)
        release.signal()
        await login.value
        assertSignedOut(store)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer pilot-token-1"], "Revoke the late-issued token")
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path == "/v1/deliveries" } })
    }

    func testDelayedRestoreAfterLogoutCannotRestoreUserOrPersistToken() async {
        seedSavedSession()
        let started = expectation(description: "Server receives identity validation")
        let revoked = expectation(description: "Logout revokes saved token while restoration is pending")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.onIdentity = { started.fulfill() }; $0.identityGate = release
            $0.onRevoke = { revoked.fulfill() }
        }
        let restore = Task { await store.restoreSession() }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertEqual(backend.withState { $0.revokedTokens }, ["Bearer saved-pilot-token"])
        release.signal()
        await restore.value
        assertSignedOut(store)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path == "/v1/deliveries" } })
    }

    func testUncertainCreateRetryUsesSameKeyAndExactBodyWithoutDuplicate() async throws {
        await store.login(username: "dispatcher-a", password: "test-only-password")
        backend.withState { $0.lostCreateResponses = 1 }
        let initial = await store.create(Fixtures.newDelivery)
        XCTAssertNil(initial)
        let pending = try XCTUnwrap(store.pendingCreation)
        XCTAssertTrue(store.createOutcomeUncertain)
        XCTAssertEqual(storage.creations["\(endpoint)|dispatcher-a"], pending)
        let retried = await store.retryPendingCreation()
        XCTAssertEqual(retried?.id, "created-1")
        XCTAssertNil(store.pendingCreation)
        XCTAssertFalse(store.createOutcomeUncertain)
        XCTAssertTrue(storage.creations.isEmpty)
        let requests = backend.withState { $0.requests.filter { $0.method == "POST" && $0.path == "/v1/deliveries" } }
        XCTAssertEqual(requests.map(\.idempotencyKey), [pending.idempotencyKey, pending.idempotencyKey])
        for request in requests {
            XCTAssertEqual(try APIClient.decoder().decode(NewDelivery.self, from: request.body), pending.delivery)
        }
        XCTAssertEqual(backend.withState { $0.committedCreates }, 1)
        XCTAssertEqual(store.deliveries.map(\.id), ["created-1"])
    }

    func testPendingCreateSurvivesRelaunchAndValidatedSessionRestore() async throws {
        await store.login(username: "dispatcher-a", password: "test-only-password")
        backend.withState { $0.lostCreateResponses = 1 }
        _ = await store.create(Fixtures.newDelivery)
        let pending = try XCTUnwrap(store.pendingCreation)
        let relaunched = makeStore()
        await relaunched.restoreSession()
        XCTAssertEqual(relaunched.pendingCreation, pending)
        XCTAssertTrue(relaunched.createOutcomeUncertain)
        let result = await relaunched.retryPendingCreation()
        XCTAssertEqual(result?.id, "created-1")
        XCTAssertNil(relaunched.pendingCreation)
        XCTAssertTrue(storage.creations.isEmpty)
        XCTAssertEqual(backend.withState { $0.committedCreates }, 1)
    }

    func testPendingCreateIsIsolatedByServerIdentityAndEndpoint() async throws {
        await store.login(username: "dispatcher-a", password: "test-only-password")
        backend.withState { $0.lostCreateResponses = 1 }
        _ = await store.create(Fixtures.newDelivery)
        let pending = try XCTUnwrap(store.pendingCreation)
        store.logout()
        backend.withState { $0.user = Principal(id: "dispatcher-b", name: "Altra centrale", role: "dispatcher") }
        await store.login(username: "dispatcher-b", password: "test-only-password")
        XCTAssertNil(store.pendingCreation)
        XCTAssertFalse(store.createOutcomeUncertain)
        let wrongIdentity = await store.retryPendingCreation()
        XCTAssertNil(wrongIdentity)
        store.logout()
        backend.withState { $0.user = Principal(id: "dispatcher-a", name: "Centrale", role: "dispatcher") }
        store.apiURL = "https://other.arrivau.example"
        await store.login(username: "dispatcher-a", password: "test-only-password")
        XCTAssertNil(store.pendingCreation)
        let wrongEndpoint = await store.retryPendingCreation()
        XCTAssertNil(wrongEndpoint)
        store.logout()
        store.apiURL = endpoint
        await store.login(username: "dispatcher-a", password: "test-only-password")
        XCTAssertEqual(store.pendingCreation, pending, "The original server identity recovers the original request")
        let recovered = await store.retryPendingCreation()
        XCTAssertEqual(recovered?.id, "created-1")
        XCTAssertEqual(backend.withState { $0.committedCreates }, 1)
        XCTAssertTrue(storage.creations.isEmpty)
    }

    func testDifferentCreateCannotReplaceUncertainRequest() async throws {
        await store.login(username: "dispatcher-a", password: "test-only-password")
        backend.withState { $0.lostCreateResponses = 1 }
        _ = await store.create(Fixtures.newDelivery)
        let pending = try XCTUnwrap(store.pendingCreation)
        let different = NewDelivery(shopName: "Altro negozio", pickupAddress: "Via Roma 1", pickup: .pachino,
                                    dropoffAddress: "Via Garibaldi 8", dropoff: .pachino,
                                    readyAt: 1, deadlineAt: 2_000_000_000, loadUnits: 1, maxRideSeconds: 1800)
        let result = await store.create(different)
        XCTAssertNil(result)
        XCTAssertEqual(store.pendingCreation, pending)
        XCTAssertEqual(storage.creations["\(endpoint)|dispatcher-a"], pending)
        XCTAssertEqual(backend.withState { $0.createAttempts }, 1)
    }

    func testCreateDoesNotTransmitWhenRecoveryCannotBePersisted() async {
        let failing = FaultingPilotStorage(base: storage)
        failing.failCreationSave = true
        let candidate = makeStore(storage: failing)
        await candidate.login(username: "dispatcher-a", password: "test-only-password")
        let result = await candidate.create(Fixtures.newDelivery)
        XCTAssertNil(result)
        XCTAssertNil(candidate.pendingCreation)
        XCTAssertNotNil(candidate.errorMessage)
        XCTAssertEqual(backend.withState { $0.createAttempts }, 0)
        XCTAssertTrue(storage.creations.isEmpty)
    }

    private func useDeletableAccount() {
        backend.withState {
            $0.user = Principal(id: "invited-driver", name: "Corriere invitato", role: "driver",
                                teamId: "team-a", teamName: "Squadra A", canDeleteAccount: true)
            $0.active = true
        }
    }

    private func deletionReview() async throws -> DeliveryStore.AccountDeletionReview {
        useDeletableAccount()
        await store.login(username: "invited-driver", password: "test-only-password")
        await store.beginAccountDeletionReview()
        return try XCTUnwrap(store.accountDeletionReview)
    }

    func testConfiguredAccountCannotOpenDeletionOrReadPreview() async {
        await store.login(username: "dispatcher-a", password: "test-only-password")
        XCTAssertFalse(store.canDeleteAccount)
        await store.beginAccountDeletionReview()
        XCTAssertFalse(store.isReviewingAccountDeletion)
        XCTAssertNil(store.accountDeletionReview)
        XCTAssertFalse(backend.withState { $0.requests.contains { $0.path.hasPrefix("/v1/account") } })
    }

    func testDeletionReviewCancelInvalidatesExactSnapshotWithoutSending() async throws {
        let first = try await deletionReview()
        XCTAssertTrue(store.canDeleteAccount)
        XCTAssertTrue(first.preview.warning.contains("2 consegne"))
        XCTAssertTrue(first.preview.warning.contains("attive da eliminare sono 1"))
        store.cancelAccountDeletionReview()
        XCTAssertFalse(store.isReviewingAccountDeletion)
        XCTAssertNil(store.accountDeletionReview)
        await store.beginAccountDeletionReview()
        XCTAssertNotEqual(store.accountDeletionReview?.id, first.id)
        let canceled = await store.deleteAccount(password: "test-only-password", review: first)
        XCTAssertFalse(canceled)
        let review = try XCTUnwrap(store.accountDeletionReview)
        let emptyPassword = await store.deleteAccount(password: "", review: review)
        XCTAssertFalse(emptyPassword)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 0)
        XCTAssertNotNil(storage.savedSession)
    }

    func testFailedPreviewCannotDeleteAndMustBeReloaded() async throws {
        useDeletableAccount()
        await store.login(username: "invited-driver", password: "test-only-password")
        backend.withState { $0.deletionPreviewStatus = 503 }
        await store.beginAccountDeletionReview()
        XCTAssertNil(store.accountDeletionReview)
        XCTAssertNotNil(store.accountDeletionError)
        XCTAssertFalse(store.isLoadingAccountDeletion)
        backend.withState { $0.deletionPreviewStatus = 200 }
        await store.loadAccountDeletionReview()
        XCTAssertNotNil(store.accountDeletionReview)
        XCTAssertNil(store.accountDeletionError)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 0)
    }

    func testCanceledDelayedPreviewCannotReopenSheetOrExposeSnapshot() async {
        useDeletableAccount()
        await store.login(username: "invited-driver", password: "test-only-password")
        let started = expectation(description: "Preview started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.nextReadPath = "/v1/account/deletion-preview"
            $0.nextReadGate = release; $0.onNextRead = { started.fulfill() }
        }
        let loading = Task { await store.beginAccountDeletionReview() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.isLoadingAccountDeletion)
        store.cancelAccountDeletionReview()
        release.signal()
        await loading.value
        XCTAssertFalse(store.isReviewingAccountDeletion)
        XCTAssertFalse(store.isLoadingAccountDeletion)
        XCTAssertNil(store.accountDeletionReview)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 0)
    }

    func testDeletionSuccessStopsGPSImmediatelyClearsPrivateStateAndOnlyItsRecovery() async throws {
        let review = try await deletionReview()
        let user = try XCTUnwrap(store.principal)
        let current = CreationScope.current(endpoint: endpoint, user: user)
        let legacy = CreationScope.legacy(endpoint: endpoint, accountId: user.id)
        let recovery = PendingCreation(idempotencyKey: "test-recovery", delivery: Fixtures.newDelivery)
        let restaurant = PendingRestaurant(idempotencyKey: "test-restaurant", restaurant: NewRestaurant(name: "Test", address: "Test address", coordinate: .pachino))
        for scope in [current, legacy, "different-account"] {
            storage.creations[scope] = recovery
            storage.pendingRestaurants[scope] = restaurant
        }
        store.setForeground(true)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        XCTAssertTrue(store.locationSharing)
        let started = expectation(description: "Delete started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState { $0.deleteAccountGate = release; $0.onDeleteAccount = { started.fulfill() } }
        let deleting = Task { await store.deleteAccount(password: "test-only-password", review: review) }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.isDeletingAccount)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertEqual(store.location.message, "Condivisione della posizione disattivata")
        store.setLocationSharing(true)
        XCTAssertFalse(store.locationSharing)
        store.cancelAccountDeletionReview()
        XCTAssertTrue(store.isReviewingAccountDeletion, "An in-flight write cannot be represented as canceled")
        let duplicate = await store.deleteAccount(password: "test-only-password", review: review)
        XCTAssertFalse(duplicate)
        release.signal()
        let deleted = await deleting.value
        XCTAssertTrue(deleted)
        assertSignedOut(store)
        XCTAssertNil(store.pendingCreation)
        XCTAssertNil(store.legacyPendingCreation)
        XCTAssertNil(store.pendingRestaurant)
        XCTAssertTrue(store.restaurants.isEmpty)
        XCTAssertNil(store.pendingInvite)
        XCTAssertNil(store.accountDeletionReview)
        XCTAssertFalse(store.isReviewingAccountDeletion)
        XCTAssertFalse(store.isDeletingAccount)
        XCTAssertEqual(storage.creations, ["different-account": recovery])
        XCTAssertEqual(storage.pendingRestaurants, ["different-account": restaurant])
        XCTAssertTrue(store.accountDeletionNotice?.hasPrefix("Account eliminato definitivamente.") == true)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
        let request = try XCTUnwrap(backend.withState { $0.requests.first { $0.path == "/v1/account" } })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(body, ["password": "test-only-password", "confirmation": review.preview.confirmation])
        XCTAssertEqual(request.authorization, "Bearer pilot-token-1")
        XCTAssertNil(request.idempotencyKey)
    }

    func testWrongDeletionPasswordKeepsSessionAndDoesNotRetry() async throws {
        let review = try await deletionReview()
        backend.withState { $0.deleteAccountStatus = 403; $0.deleteAccountError = "Password confirmation failed" }
        let deleted = await store.deleteAccount(password: "incorrect-test-password", review: review)
        XCTAssertFalse(deleted)
        XCTAssertEqual(store.principal?.id, "invited-driver")
        XCTAssertNotNil(storage.savedSession)
        XCTAssertEqual(store.accountDeletionReview, review)
        XCTAssertEqual(store.accountDeletionError, "Password attuale non corretta. Inseriscila di nuovo per confermare l’eliminazione.")
        XCTAssertNil(store.accountDeletionNotice)
        XCTAssertFalse(store.isDeletingAccount)
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
    }

    func testDeletionUnauthorizedClearsSessionInsteadOfTreatingItAsWrongPassword() async throws {
        let review = try await deletionReview()
        backend.withState { $0.deleteAccountStatus = 401 }
        let deleted = await store.deleteAccount(password: "test-only-password", review: review)
        XCTAssertFalse(deleted)
        assertSignedOut(store)
        XCTAssertTrue(store.errorMessage?.contains("Sessione scaduta o revocata") == true)
        XCTAssertNil(store.accountDeletionNotice)
    }

    func testDeletionConflictLoadsNewSnapshotButRequiresNewExplicitConfirmation() async throws {
        let old = try await deletionReview()
        backend.withState {
            $0.deleteAccountStatus = 409
            $0.deletionCount = 3; $0.activeDeletionCount = 2
            $0.deletionConfirmation = String(repeating: "b", count: 64)
        }
        let first = await store.deleteAccount(password: "test-only-password", review: old)
        XCTAssertFalse(first)
        let fresh = try XCTUnwrap(store.accountDeletionReview)
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertEqual(fresh.preview.deliveryCount, 3)
        XCTAssertEqual(fresh.preview.activeDeliveryCount, 2)
        XCTAssertTrue(store.accountDeletionError?.contains("conferma di nuovo") == true)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
        backend.withState { $0.deleteAccountStatus = 204 }
        let stale = await store.deleteAccount(password: "test-only-password", review: old)
        XCTAssertFalse(stale)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
        let confirmed = await store.deleteAccount(password: "test-only-password", review: fresh)
        XCTAssertTrue(confirmed)
        let bodies = try backend.withState { state in
            try state.requests.filter { $0.path == "/v1/account" }.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: String])["confirmation"]
            }
        }
        XCTAssertEqual(bodies, [old.preview.confirmation, fresh.preview.confirmation])
    }

    func testRateLimitedDeletionDoesNotRetryOrSignOut() async throws {
        let review = try await deletionReview()
        backend.withState { $0.deleteAccountStatus = 429 }
        let deleted = await store.deleteAccount(password: "test-only-password", review: review)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(store.principal)
        XCTAssertNotNil(storage.savedSession)
        XCTAssertTrue(store.accountDeletionError?.contains("Troppi tentativi di eliminazione") == true)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
    }

    func testUncertainDeletionSignsOutWithoutClaimingSuccessOrRetrying() async throws {
        let review = try await deletionReview()
        backend.withState { $0.loseDeleteAccountResponse = true }
        let deleted = await store.deleteAccount(password: "test-only-password", review: review)
        XCTAssertFalse(deleted)
        assertSignedOut(store)
        XCTAssertTrue(store.accountDeletionNotice?.hasPrefix("Non è possibile confermare") == true)
        XCTAssertNil(store.accountDeletionReview)
        let retry = await store.deleteAccount(password: "test-only-password", review: review)
        XCTAssertFalse(retry)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
    }


    func testServerFailureDuringDeletionIsUncertainAndClearsLocalSession() async throws {
        let review = try await deletionReview()
        backend.withState { $0.deleteAccountStatus = 500 }
        let deleted = await store.deleteAccount(password: "test-only-password", review: review)
        XCTAssertFalse(deleted)
        assertSignedOut(store)
        XCTAssertTrue(store.accountDeletionNotice?.hasPrefix("Non è possibile confermare") == true)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
    }

    func testDeletionLocalCleanupFailureIsDisclosedWithoutRestoringPrivateState() async throws {
        useDeletableAccount()
        let failing = FaultingPilotStorage(base: storage)
        failing.failCreationClear = true
        let candidate = makeStore(storage: failing)
        await candidate.login(username: "invited-driver", password: "test-only-password")
        await candidate.beginAccountDeletionReview()
        let review = try XCTUnwrap(candidate.accountDeletionReview)
        let deleted = await candidate.deleteAccount(password: "test-only-password", review: review)
        XCTAssertTrue(deleted, "The server's confirmed deletion remains true despite a local cleanup failure")
        assertSignedOut(candidate)
        XCTAssertTrue(candidate.accountDeletionNotice?.contains("Non è stato possibile rimuovere tutti i dati protetti") == true)
        XCTAssertNil(candidate.accountDeletionReview)
    }

    func testDelayedPreviewCannotExposeOldAccountAfterNewerLogin() async {
        useDeletableAccount()
        await store.login(username: "invited-driver", password: "test-only-password")
        let started = expectation(description: "Old preview started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.nextReadPath = "/v1/account/deletion-preview"
            $0.nextReadGate = release; $0.onNextRead = { started.fulfill() }
        }
        let loading = Task { await store.beginAccountDeletionReview() }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        await store.awaitPendingRevocations()
        backend.withState { $0.user = Principal(id: "another-account", name: "Altro account", role: "dispatcher") }
        await store.login(username: "another-account", password: "test-only-password")
        let saved = storage.savedSession
        release.signal()
        await loading.value
        XCTAssertEqual(store.principal?.id, "another-account")
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertNil(store.accountDeletionReview)
        XCTAssertFalse(store.isReviewingAccountDeletion)
        XCTAssertNil(store.accountDeletionError)
    }

    func testLateSuccessfulDeletionCannotSignOutNewerLogin() async throws {
        try await assertLateDeletionPreservesNewLogin(loseResponse: false)
    }

    func testLateUncertainDeletionCannotClearNewerLoginOrShowOldWarning() async throws {
        try await assertLateDeletionPreservesNewLogin(loseResponse: true)
    }

    private func assertLateDeletionPreservesNewLogin(loseResponse: Bool) async throws {
        let review = try await deletionReview()
        let started = expectation(description: "Old session deletion started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.deleteAccountGate = release; $0.onDeleteAccount = { started.fulfill() }
            $0.loseDeleteAccountResponse = loseResponse
        }
        let deletion = Task { await store.deleteAccount(password: "test-only-password", review: review) }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        await store.awaitPendingRevocations()
        backend.withState { $0.user = Principal(id: "another-account", name: "Altro account", role: "dispatcher") }
        await store.login(username: "another-account", password: "test-only-password")
        let saved = try XCTUnwrap(storage.savedSession)
        release.signal()
        let result = await deletion.value
        XCTAssertFalse(result)
        XCTAssertEqual(store.principal?.id, "another-account")
        XCTAssertEqual(storage.savedSession, saved)
        XCTAssertNil(store.accountDeletionReview)
        XCTAssertNil(store.accountDeletionNotice)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isDeletingAccount)
        XCTAssertEqual(backend.withState { $0.deleteAccountCount }, 1)
    }
}

private final class FaultingPilotStorage: SessionStorage {
    private var restaurants: [String: PendingRestaurant] = [:]
    func loadRestaurant(scope: String) throws -> PendingRestaurant? { restaurants[scope] }
    func saveRestaurant(_ value: PendingRestaurant, scope: String) throws { restaurants[scope] = value }
    func clearRestaurant(scope: String) throws { restaurants[scope] = nil }

    let base: MemorySessionStorage
    var failCreationLoad = false
    var failCreationSave = false
    var failCreationClear = false
    init(base: MemorySessionStorage) { self.base = base }
    func loadSession() throws -> SavedSession? { try base.loadSession() }
    func saveSession(_ value: SavedSession) throws { try base.saveSession(value) }
    func clearSession() throws { try base.clearSession() }
    func loadCreation(scope: String) throws -> PendingCreation? {
        if failCreationLoad { throw APIError(message: "Test storage read failed") }
        return try base.loadCreation(scope: scope)
    }
    func saveCreation(_ value: PendingCreation, scope: String) throws {
        if failCreationSave { throw APIError(message: "Test storage write failed") }
        try base.saveCreation(value, scope: scope)
    }
    func clearCreation(scope: String) throws {
        if failCreationClear { throw APIError(message: "Test storage clear failed") }
        try base.clearCreation(scope: scope)
    }
}

private final class PilotSessionURLProtocol: URLProtocol {
    static var backend: PilotSessionBackend?
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Capture this test's backend before dispatching, so a late canceled request cannot reach the next test.
        guard let backend = Self.backend else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        DispatchQueue.global().async { [self] in
            let result = Result { try backend.respond(to: request) }
            stateLock.lock(); let cancelled = stopped; stateLock.unlock()
            guard !cancelled else { return }
            switch result {
            case .success(let (status, data)):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

private final class PilotSessionBackend {
    struct RequestRecord {
        let method: String
        let path: String
        let origin: String
        let authorization: String?
        let idempotencyKey: String?
        let body: Data
    }
    private let lock = NSLock()
    var user = Principal(id: "dispatcher-a", name: "Centrale", role: "dispatcher")
    var expiresAt = Int(Date().timeIntervalSince1970) + 3600
    var active = false
    var loginStatus = 201
    var identityStatus = 200
    var omitIdentityExpiry = false
    var emptyLoginToken = false
    var rejectProtectedReads = false
    var lostCreateResponses = 0
    var requests: [RequestRecord] = []
    var revokedTokens: [String] = []
    var locationWrites = 0
    var locationStatus = 200
    var createAttempts = 0
    var committedCreates = 0
    var onLogin: (() -> Void)?
    var onIdentity: (() -> Void)?
    var onRevoke: (() -> Void)?
    var onLocation: (() -> Void)?
    var loginGate: DispatchSemaphore?
    var identityGate: DispatchSemaphore?
    var shiftGate: DispatchSemaphore?
    var onShift: (() -> Void)?
    var jobs: [Delivery] = []
    var nextReadPath: String?
    var nextReadStatus = 200
    var nextReadGate: DispatchSemaphore?
    var onNextRead: (() -> Void)?
    var createGate: DispatchSemaphore?
    var onCreate: (() -> Void)?
    var deletionPreviewStatus = 200
    var deletionCount = 2
    var activeDeletionCount = 1
    var deletionConfirmation = String(repeating: "a", count: 64)
    var deleteAccountStatus = 204
    var deleteAccountError = "Test request rejected"
    var deleteAccountCount = 0
    var loseDeleteAccountResponse = false
    var deleteAccountGate: DispatchSemaphore?
    var onDeleteAccount: (() -> Void)?
    private var loginCount = 0
    private var creations: [String: Delivery] = [:]

    func withState<T>(_ operation: (PilotSessionBackend) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation(self)
    }

    func respond(to request: URLRequest) throws -> (Int, Data) {
        let body = try Self.body(of: request)
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        let origin = "\(request.url!.scheme!)://\(request.url!.host!)"
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        var gate: DispatchSemaphore?
        var received: (() -> Void)?
        var loseResponse = false
        // Never hold the backend lock while waiting for a test to release a delayed response.
        let response: (Int, Data) = try withState { state in
            state.requests.append(RequestRecord(method: method, path: path, origin: origin, authorization: authorization,
                                                idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"), body: body))
            if path == "/v1/session" && method == "POST" {
                state.loginCount += 1
                gate = state.loginGate; received = state.onLogin
                if state.loginStatus != 201 { return (state.loginStatus, Self.errorBody) }
                let token = state.emptyLoginToken ? "" : "pilot-token-\(state.loginCount)"
                return (201, try Self.json(["token": token, "expires_at": state.expiresAt, "user": Self.userBody(state.user)]))
            }
            if path == "/v1/session" && method == "GET" {
                gate = state.identityGate; received = state.onIdentity
                if state.identityStatus != 200 { return (state.identityStatus, Self.errorBody) }
                var identity: [String: Any] = ["user": Self.userBody(state.user)]
                if !state.omitIdentityExpiry { identity["expires_at"] = state.expiresAt }
                return (200, try Self.json(identity))
            }
            if path == "/v1/session" && method == "DELETE" {
                state.revokedTokens.append(authorization ?? "")
                received = state.onRevoke
                return (204, Data())
            }
            if method == "GET", path == state.nextReadPath {
                gate = state.nextReadGate; received = state.onNextRead
                state.nextReadPath = nil; state.nextReadGate = nil; state.onNextRead = nil
                if state.nextReadStatus != 200 { return (state.nextReadStatus, Self.errorBody) }
            }
            if method == "GET" && state.rejectProtectedReads { return (401, Self.errorBody) }
            let driver = Driver(id: state.user.id, name: state.user.name, active: state.active, capacity: 5,
                                location: nil, locationUpdatedAt: nil)
            switch (method, path) {
            case ("GET", "/v1/account/deletion-preview"):
                if state.deletionPreviewStatus != 200 { return (state.deletionPreviewStatus, Self.errorBody) }
                return (200, try Self.json(["delivery_count": state.deletionCount, "active_delivery_count": state.activeDeletionCount,
                                           "confirmation": state.deletionConfirmation]))
            case ("DELETE", "/v1/account"):
                state.deleteAccountCount += 1
                gate = state.deleteAccountGate; received = state.onDeleteAccount
                loseResponse = state.loseDeleteAccountResponse
                if state.deleteAccountStatus != 204 {
                    return (state.deleteAccountStatus, try Self.json(["error": state.deleteAccountError]))
                }
                return (204, Data())
            case ("GET", "/v1/drivers"): return (200, try APIClient.encoder().encode([driver]))
            case ("GET", "/v1/shift"): return (200, try APIClient.encoder().encode(driver))
            case ("POST", "/v1/shift"):
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                state.active = payload["active"] as? Bool ?? false
                gate = state.shiftGate; received = state.onShift
                let updated = Driver(id: state.user.id, name: state.user.name, active: state.active,
                                     capacity: payload["capacity"] as? Int ?? 5, location: nil, locationUpdatedAt: nil)
                return (200, try APIClient.encoder().encode(updated))
            case ("GET", "/v1/route"):
                let stops = state.jobs.filter { $0.driverId == state.user.id && $0.status == .assigned }.flatMap { job in
                    [RouteStop(deliveryId: job.id, kind: .pickup, address: job.pickupAddress, coordinate: job.pickup, arrivalAt: 1, departureAt: 2),
                     RouteStop(deliveryId: job.id, kind: .dropoff, address: job.dropoffAddress, coordinate: job.dropoff, arrivalAt: 3, departureAt: 4)]
                }
                let route = DriverRoute(driverId: state.user.id, stops: stops, travelSeconds: 0, finishAt: 0, feasible: true, warnings: [])
                return (200, try APIClient.encoder().encode(route))
            case ("GET", "/v1/deliveries"):
                let prefix = "\(origin)|\(state.user.teamId ?? "legacy")|\(state.user.id)|"
                let deliveries = state.jobs + state.creations.filter { $0.key.hasPrefix(prefix) }.map { $0.value }.sorted { $0.id < $1.id }
                return (200, try APIClient.encoder().encode(deliveries))
            case ("POST", "/v1/location"):
                state.locationWrites += 1; received = state.onLocation
                if state.locationStatus != 200 { return (state.locationStatus, Self.errorBody) }
                return (200, try APIClient.encoder().encode(driver))
            case ("POST", "/v1/deliveries"):
                state.createAttempts += 1
                gate = state.createGate; received = state.onCreate
                guard let key = request.value(forHTTPHeaderField: "Idempotency-Key"), !key.isEmpty else { return (400, Self.errorBody) }
                let scope = "\(origin)|\(state.user.teamId ?? "legacy")|\(state.user.id)|\(key)"
                let input = try APIClient.decoder().decode(NewDelivery.self, from: body)
                let delivery: Delivery
                if let existing = state.creations[scope] { delivery = existing }
                else {
                    state.committedCreates += 1
                    delivery = Delivery(id: "created-\(state.committedCreates)", shopName: input.shopName,
                                        pickupAddress: input.pickupAddress, pickup: input.pickup,
                                        dropoffAddress: input.dropoffAddress, dropoff: input.dropoff,
                                        readyAt: input.readyAt ?? 0, deadlineAt: input.deadlineAt,
                                        loadUnits: input.loadUnits, maxRideSeconds: input.maxRideSeconds,
                                        status: .pending, driverId: nil, createdAt: 1, pickedUpAt: nil, deliveredAt: nil)
                    state.creations[scope] = delivery
                }
                if state.lostCreateResponses > 0 {
                    state.lostCreateResponses -= 1
                    throw URLError(.networkConnectionLost)
                }
                return (201, try APIClient.encoder().encode(delivery))
            default: return (404, Self.errorBody)
            }
        }
        received?()
        if let gate, gate.wait(timeout: .now() + 10) == .timedOut { throw URLError(.timedOut) }
        if loseResponse { throw URLError(.networkConnectionLost) }
        return response
    }

    private static let errorBody = Data(#"{"error":"Test request rejected"}"#.utf8)
    private static func userBody(_ user: Principal) -> [String: Any] {
        var result: [String: Any] = ["id": user.id, "name": user.name, "role": user.role, "roles": user.roles]
        if user.canDeleteAccount { result["can_delete_account"] = true }
        if let teamId = user.teamId { result["team_id"] = teamId }
        if let teamName = user.teamName { result["team_name"] = teamName }
        return result
    }
    private static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
