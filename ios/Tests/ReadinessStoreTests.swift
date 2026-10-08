import XCTest
@testable import Arrivau

@MainActor
final class ReadinessStoreTests: XCTestCase {
    private var session: URLSession!
    private var backend: ReadinessBackend!
    private var store: DeliveryStore!
    private var storage: ReadinessStorage!

    override func setUp() async throws {
        backend = ReadinessBackend()
        ReadinessURLProtocol.backend = backend
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadinessURLProtocol.self]
        session = URLSession(configuration: configuration)
        storage = ReadinessStorage()
        store = DeliveryStore(session: session, deterministicLocation: true, mode: .demo, storage: storage)
        store.apiURL = "http://localhost:8080"
        await store.login(as: .dual)
    }
    override func tearDown() async throws {
        store.logout()
        session.invalidateAndCancel()
        ReadinessURLProtocol.backend = nil
        store = nil; backend = nil
    }

    func testDispatcherRouteIsLimitedToCurrentTeamAndSelectedRole() async throws {
        let route = await store.dispatcherRoute(driverId: "dual-1")
        XCTAssertEqual(route?.driverId, "dual-1")
        let unknown = await store.dispatcherRoute(driverId: "other-team-driver")
        XCTAssertNil(unknown)
        XCTAssertTrue(store.switchRole(to: .driver))
        let forbidden = await store.dispatcherRoute(driverId: "dual-1")
        XCTAssertNil(forbidden)
        XCTAssertEqual(backend.withState { $0.records.filter { $0.path.hasSuffix("/route") && $0.path.hasPrefix("/v1/drivers/") }.count }, 1)
    }

    func testFailedDispatcherRouteDoesNotReturnOldPlan() async {
        let initial = await store.dispatcherRoute(driverId: "dual-1")
        XCTAssertNotNil(initial)
        backend.withState { $0.failReads = true }
        let failed = await store.dispatcherRoute(driverId: "dual-1")
        XCTAssertNil(failed)
    }

    func testDeleteDeliveryRemovesConfirmedWorkEvenWhenRefreshFails() async {
        backend.withState { $0.failReadsAfterWrite = true }
        let deleted = await store.deleteDelivery(deliveryId: "delivery-1")
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.deliveries.isEmpty)
        XCTAssertNotNil(store.syncErrorMessage)
        let repeated = await store.deleteDelivery(deliveryId: "delivery-1")
        XCTAssertFalse(repeated)
        XCTAssertEqual(backend.withState { $0.deleteWrites }, 1)
    }

    func testDeleteDeliveryRejectsDriverViewAndUnknownDelivery() async {
        let unknown = await store.deleteDelivery(deliveryId: "other-team-delivery")
        XCTAssertFalse(unknown)
        XCTAssertTrue(store.switchRole(to: .driver))
        let forbidden = await store.deleteDelivery(deliveryId: "delivery-1")
        XCTAssertFalse(forbidden)
        XCTAssertEqual(backend.withState { $0.deleteWrites }, 0)
    }

    func testLostOrCancelledDeleteResponseStaysUnconfirmedAndCanRetry() async {
        for cancelled in [false, true] {
            backend.withState {
                $0.deleted = false; $0.failReads = false
                $0.failReadsAfterWrite = true
                $0.loseDeleteResponse = !cancelled; $0.cancelDeleteResponse = cancelled
            }
            await store.refresh(force: true)
            let uncertain = await store.deleteDelivery(deliveryId: "delivery-1")
            XCTAssertFalse(uncertain)
            XCTAssertEqual(store.deliveries.count, 1)
            backend.withState { $0.loseDeleteResponse = false; $0.cancelDeleteResponse = false }
            let retried = await store.deleteDelivery(deliveryId: "delivery-1")
            XCTAssertTrue(retried)
            XCTAssertTrue(store.deliveries.isEmpty)
        }
    }

    func testDeleteDoubleTapAndRoleSwitchAreBlockedDuringMutation() async {
        let started = expectation(description: "Deletion started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.gatedPath = "/v1/deliveries/delivery-1"
            $0.gate = release; $0.onGatedRequest = { started.fulfill() }
        }
        let first = Task { await store.deleteDelivery(deliveryId: "delivery-1") }
        await fulfillment(of: [started], timeout: 5)
        let second = await store.deleteDelivery(deliveryId: "delivery-1")
        XCTAssertFalse(second)
        XCTAssertFalse(store.switchRole(to: .driver))
        release.signal()
        let deleted = await first.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(backend.withState { $0.deleteWrites }, 1)
    }

    func testDeleteResponseFromOldSessionCannotChangeNewTeam() async {
        let started = expectation(description: "Deletion started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        backend.withState {
            $0.gatedPath = "/v1/deliveries/delivery-1"
            $0.gate = release; $0.onGatedRequest = { started.fulfill() }
        }
        let old = Task { await store.deleteDelivery(deliveryId: "delivery-1") }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        backend.withState { $0.teamId = "new-team"; $0.deleted = false }
        await store.login(as: .dual)
        release.signal()
        let deleted = await old.value
        XCTAssertFalse(deleted)
        XCTAssertEqual(store.principal?.teamId, "new-team")
        XCTAssertEqual(store.deliveries.count, 1)
    }

    func testUnknownDoesNotRequestSuggestionsOrPermitAssignmentOrPickup() async throws {
        let suggestions = await store.suggestions(for: "delivery-1")
        let assigned = await store.assign(deliveryId: "delivery-1", driverId: "dual-1")
        XCTAssertNil(suggestions)
        XCTAssertFalse(assigned)
        XCTAssertEqual(backend.withState { $0.records.filter { $0.path.hasSuffix("suggestions") || $0.path.hasSuffix("assign") }.count }, 0)
        backend.withState { $0.job = ReadinessBackend.delivery(status: .assigned, state: .unknown, readyAt: 1) }
        XCTAssertTrue(store.switchRole(to: .driver))
        await store.refresh(force: true)
        await store.completeNextStop(try XCTUnwrap(store.deliveries.first))
        XCTAssertEqual(backend.withState { $0.records.filter { $0.path.hasSuffix("status") }.count }, 0)
    }

    func testForecastAndReadyNowKeepDistinctAuthoritativeStatesAndOriginalAnchor() async throws {
        let forecast = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: 0)
        XCTAssertTrue(forecast)
        XCTAssertEqual(store.deliveries.first?.readinessState, .estimated)
        XCTAssertEqual(store.deliveries.first?.readyAt, 1600)
        let ready = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 1)
        XCTAssertTrue(ready)
        XCTAssertEqual(store.deliveries.first?.readinessState, .ready)
        let anchor = store.deliveries.first?.readyAt
        backend.withState { $0.now += 60 }
        let repeated = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 2)
        XCTAssertTrue(repeated)
        XCTAssertEqual(store.deliveries.first?.readyAt, anchor)
        XCTAssertEqual(backend.withState { $0.readinessWrites }, 2)
        let stale = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 15, expectedRevision: 1)
        XCTAssertFalse(stale)
        XCTAssertEqual(backend.withState { $0.readinessWrites }, 2, "A stale estimate sheet must not change a newer revision")
    }

    func testAutomaticAssignmentFromReadinessResponseIsAppliedWithoutDriverSelection() async {
        backend.withState { $0.autoAssign = true }
        let saved = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.deliveries.first?.status, .assigned)
        XCTAssertEqual(store.deliveries.first?.driverId, "dual-1")
        XCTAssertEqual(backend.withState { $0.records.filter { $0.path.hasSuffix("assign") }.count }, 0)
    }

    func testLostOrCancelledEstimateReusesExactBodyRevisionAndKeyWithoutSliding() async throws {
        for cancelled in [false, true] {
            backend.withState { $0.failReads = false; $0.failReadsAfterWrite = false; $0.loseReadinessResponse = false; $0.cancelReadinessResponse = false }
            let revision = try XCTUnwrap(store.deliveries.first?.readinessRevision)
            backend.withState { $0.failReadsAfterWrite = true; $0.loseReadinessResponse = !cancelled; $0.cancelReadinessResponse = cancelled }
            let uncertain = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: revision)
            XCTAssertFalse(uncertain)
            XCTAssertNotNil(store.pendingReadiness(for: "delivery-1"))
            let conflicting = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 20, expectedRevision: revision)
            XCTAssertFalse(conflicting)
            let originalAnchor = backend.withState { $0.job.readyAt }
            backend.withState { $0.now += 120; $0.loseReadinessResponse = false; $0.cancelReadinessResponse = false }
            let repeated = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: revision)
            XCTAssertTrue(repeated)
            XCTAssertEqual(store.deliveries.first?.readyAt, originalAnchor)
            let attempts = backend.withState { $0.records.filter { $0.path.hasSuffix("readiness") }.suffix(2) }
            XCTAssertEqual(attempts.first?.key, attempts.last?.key)
            XCTAssertNotNil(attempts.first?.key)
            XCTAssertEqual(try attempts.map { try APIClient.decoder().decode(ReadinessUpdate.self, from: $0.body) },
                           [ReadinessUpdate(readyInMinutes: 10, expectedRevision: revision), ReadinessUpdate(readyInMinutes: 10, expectedRevision: revision)])
        }
        XCTAssertEqual(backend.withState { $0.readinessWrites }, 2)
    }

    func testDoubleTapAndMidMutationViewSwitchCannotSubmitAgain() async {
        let started = expectation(description: "Readiness started")
        let release = DispatchSemaphore(value: 0)
        backend.withState { $0.gatedPath = "/v1/deliveries/delivery-1/readiness"; $0.gate = release; $0.onGatedRequest = { started.fulfill() } }
        let first = Task { await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: 0) }
        await fulfillment(of: [started], timeout: 5)
        let second = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: 0)
        XCTAssertFalse(second)
        XCTAssertFalse(store.switchRole(to: .driver))
        release.signal()
        let saved = await first.value
        XCTAssertTrue(saved)
        XCTAssertEqual(backend.withState { $0.readinessWrites }, 1)
        XCTAssertTrue(store.switchRole(to: .driver))
        let unauthorized = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 1)
        XCTAssertFalse(unauthorized)
        XCTAssertEqual(backend.withState { $0.readinessWrites }, 1)
    }

    func testUncertainReadinessSurvivesSameAccountViewChanges() async {
        backend.withState { $0.failReadsAfterWrite = true; $0.loseReadinessResponse = true }
        _ = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: 0)
        XCTAssertTrue(store.switchRole(to: .driver))
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        XCTAssertEqual(store.pendingReadiness(for: "delivery-1"), ReadinessUpdate(readyInMinutes: 10, expectedRevision: 0))
        backend.withState { $0.loseReadinessResponse = false }
        let saved = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 10, expectedRevision: 0)
        XCTAssertTrue(saved)
        XCTAssertEqual(backend.withState { $0.readinessWrites }, 1)
    }

    func testConflictClearsRetryAndRequiresSuccessfulAuthoritativeRead() async {
        backend.withState {
            $0.job = ReadinessBackend.delivery(state: .estimated, revision: 1, readyAt: 1800)
            $0.failReadsAfterWrite = true
        }
        let conflict = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0)
        XCTAssertFalse(conflict)
        XCTAssertNil(store.pendingReadiness(for: "delivery-1"))
        let blocked = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0)
        XCTAssertFalse(blocked)
        XCTAssertEqual(backend.withState { $0.records.filter { $0.path.hasSuffix("readiness") }.count }, 1)
        backend.withState { $0.failReads = false; $0.failReadsAfterWrite = false }
        await store.refresh(force: true)
        XCTAssertEqual(store.deliveries.first?.readinessRevision, 1)
        let saved = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 1)
        XCTAssertTrue(saved)
        let keys = backend.withState { $0.records.filter { $0.path.hasSuffix("readiness") }.map(\.key) }
        XCTAssertNotEqual(keys.first, keys.last)
    }

    func testOlderReadinessSnapshotCannotOverwriteConfirmedWrite() async {
        let original = backend.withState { $0.job }
        backend.withState { $0.deliveryReadOverride = original }
        let saved = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.deliveries.first?.readinessState, .ready)
        XCTAssertEqual(store.deliveries.first?.readinessRevision, 1)
        await store.refresh(force: true)
        XCTAssertEqual(store.deliveries.first?.readinessRevision, 1)
    }

    func testSameRevisionLateReadinessResponseCannotRewindPickupOrCompletion() async {
        for status in [DeliveryStatus.pickedUp, .delivered] {
            backend.withState {
                $0.failReads = false
                $0.job = ReadinessBackend.delivery()
                $0.autoAssign = true
            }
            // A fresh login isolates each monotonic-status scenario.
            store.logout()
            await store.login(as: .dual)
            let started = expectation(description: "Readiness response held before \(status.rawValue)")
            let release = DispatchSemaphore(value: 0)
            backend.withState { $0.gatedPath = "/v1/deliveries/delivery-1/readiness"; $0.gate = release; $0.onGatedRequest = { started.fulfill() } }
            let old = Task { await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0) }
            await fulfillment(of: [started], timeout: 5)
            backend.withState { $0.job = ReadinessBackend.delivery(status: status, state: .ready, revision: 1, readyAt: 1000) }
            await store.refresh(force: true)
            XCTAssertEqual(store.deliveries.first?.status, status)
            backend.withState { $0.failReads = true }
            release.signal()
            _ = await old.value
            XCTAssertEqual(store.deliveries.first?.status, status, "The cached readiness response must not rewind a concurrent confirmed action")
            XCTAssertEqual(store.deliveries.first?.readinessRevision, 1)
            backend.withState {
                $0.failReads = false
                $0.deliveryReadOverride = ReadinessBackend.delivery(status: .assigned, state: .ready, revision: 1, readyAt: 1000)
            }
            await store.refresh(force: true)
            XCTAssertEqual(store.deliveries.first?.status, status, "A later stale poll also cannot rewind progress")
            backend.withState { $0.deliveryReadOverride = nil }
        }
    }

    func testDelayedSuggestionCannotOutliveReadinessRevision() async {
        backend.withState { $0.job = ReadinessBackend.delivery(state: .estimated) }
        await store.refresh(force: true)
        let started = expectation(description: "Old suggestion started")
        let release = DispatchSemaphore(value: 0)
        backend.withState { $0.gatedPath = "/v1/deliveries/delivery-1/suggestions"; $0.gate = release; $0.onGatedRequest = { started.fulfill() } }
        let old = Task { await store.suggestions(for: "delivery-1") }
        await fulfillment(of: [started], timeout: 5)
        _ = await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0)
        release.signal()
        let result = await old.value
        XCTAssertNil(result)
    }

    func testRestaurantUncertainRetryAndDoubleTapUseOneSavedPlace() async throws {
        let draft = NewRestaurant(name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino)
        backend.withState { $0.loseRestaurantResponse = true }
        let lost = await store.createRestaurant(draft)
        XCTAssertNil(lost)
        XCTAssertEqual(store.pendingRestaurant?.restaurant, draft)
        let changed = await store.createRestaurant(NewRestaurant(name: "Altro", address: "Via Roma 1", coordinate: .pachino))
        XCTAssertNil(changed)
        XCTAssertTrue(store.switchRole(to: .driver))
        let forbidden = await store.createRestaurant(draft)
        XCTAssertNil(forbidden)
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        backend.withState { $0.loseRestaurantResponse = false }
        let saved = await store.createRestaurant(draft)
        XCTAssertEqual(saved?.name, draft.name)
        XCTAssertEqual(store.restaurants.count, 1)
        XCTAssertNil(store.pendingRestaurant)
        let attempts = backend.withState { $0.records.filter { $0.method == "POST" && $0.path == "/v1/restaurants" } }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.key, attempts.last?.key)
        XCTAssertEqual(try attempts.map { try APIClient.decoder().decode(NewRestaurant.self, from: $0.body) }, [draft, draft])
        XCTAssertEqual(backend.withState { $0.restaurantWrites }, 1)
        store.logout()
        XCTAssertTrue(store.restaurants.isEmpty)
        XCTAssertNil(store.pendingRestaurant)
    }

    func testRestaurantDoubleTapAndMidMutationRoleSwitchDoNotDuplicateSave() async {
        let started = expectation(description: "Restaurant started")
        let release = DispatchSemaphore(value: 0)
        backend.withState { $0.gatedPath = "/v1/restaurants"; $0.gate = release; $0.onGatedRequest = { started.fulfill() } }
        let draft = NewRestaurant(name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino)
        let first = Task { await store.createRestaurant(draft) }
        await fulfillment(of: [started], timeout: 5)
        let second = await store.createRestaurant(draft)
        XCTAssertNil(second)
        XCTAssertFalse(store.switchRole(to: .driver))
        release.signal()
        let saved = await first.value
        XCTAssertNotNil(saved)
        XCTAssertEqual(backend.withState { $0.restaurantWrites }, 1)
    }

    func testDelayedRestaurantLoadIsIgnoredAfterViewChangeAndNeverRequestedByDriver() async {
        let started = expectation(description: "Restaurants started")
        let release = DispatchSemaphore(value: 0)
        backend.withState {
            $0.restaurants = [Restaurant(id: "r-1", name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino, createdAt: 1)]
            $0.gatedPath = "/v1/restaurants"; $0.gate = release; $0.onGatedRequest = { started.fulfill() }
        }
        let old = Task { await store.loadRestaurants() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.switchRole(to: .driver))
        release.signal()
        await old.value
        XCTAssertTrue(store.restaurants.isEmpty)
        await store.loadRestaurants()
        XCTAssertEqual(backend.withState { $0.records.filter { $0.path == "/v1/restaurants" }.count }, 1)
        XCTAssertTrue(store.switchRole(to: .dispatcher))
        await store.loadRestaurants()
        XCTAssertEqual(store.restaurants.map(\.id), ["r-1"])
    }

    func testRestaurantRecoverySurvivesRelaunchAndKeepsTeamScope() async throws {
        let draft = NewRestaurant(name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino)
        backend.withState { $0.loseRestaurantResponse = true }
        _ = await store.createRestaurant(draft)
        let pending = try XCTUnwrap(store.pendingRestaurant)
        store.logout()
        store = DeliveryStore(session: session, deterministicLocation: true, mode: .demo, storage: storage)
        store.apiURL = "http://localhost:8080"
        backend.withState { $0.teamId = "another-team" }
        await store.login(as: .dual)
        XCTAssertNil(store.pendingRestaurant, "A recovery request must never enter another team")
        store.logout()
        backend.withState { $0.teamId = "review"; $0.loseRestaurantResponse = false }
        await store.login(as: .dual)
        XCTAssertEqual(store.pendingRestaurant, pending)
        let saved = await store.createRestaurant(pending.restaurant)
        XCTAssertNotNil(saved)
        XCTAssertNil(store.pendingRestaurant)
        XCTAssertEqual(backend.withState { $0.restaurantWrites }, 1)
        let keys = backend.withState { $0.records.filter { $0.path == "/v1/restaurants" && $0.method == "POST" }.map(\.key) }
        XCTAssertEqual(keys, [pending.idempotencyKey, pending.idempotencyKey])
    }

    func testRestaurantStorageFailurePreventsUnrecoverableWriteAndRetainsFailedCleanup() async {
        let draft = NewRestaurant(name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino)
        storage.failSave = true
        let blocked = await store.createRestaurant(draft)
        XCTAssertNil(blocked)
        XCTAssertEqual(backend.withState { $0.restaurantWrites }, 0)
        storage.failSave = false
        storage.failClear = true
        let saved = await store.createRestaurant(draft)
        XCTAssertNotNil(saved)
        XCTAssertNotNil(store.pendingRestaurant)
        storage.failClear = false
        let repeated = await store.createRestaurant(draft)
        XCTAssertEqual(repeated, saved)
        XCTAssertNil(store.pendingRestaurant)
        XCTAssertEqual(backend.withState { $0.restaurantWrites }, 1)
    }

    func testLateReadinessResultCannotRepopulateSignedOutSession() async {
        let started = expectation(description: "Readiness started")
        let release = DispatchSemaphore(value: 0)
        backend.withState { $0.gatedPath = "/v1/deliveries/delivery-1/readiness"; $0.gate = release; $0.onGatedRequest = { started.fulfill() } }
        let old = Task { await store.setReadiness(deliveryId: "delivery-1", readyInMinutes: 0, expectedRevision: 0) }
        await fulfillment(of: [started], timeout: 5)
        store.logout()
        release.signal()
        let result = await old.value
        XCTAssertFalse(result)
        XCTAssertTrue(store.deliveries.isEmpty)
        XCTAssertNil(store.principal)
    }
}

private final class ReadinessURLProtocol: URLProtocol {
    static var backend: ReadinessBackend?
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let backend = Self.backend
        DispatchQueue.global().async {
            do {
                guard let backend else { throw URLError(.cancelled) }
                let (status, data) = try backend.respond(to: self.request)
                self.stateLock.lock(); let cancelled = self.stopped; self.stateLock.unlock()
                guard !cancelled else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.stateLock.lock(); let cancelled = self.stopped; self.stateLock.unlock()
                if !cancelled { self.client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

private final class ReadinessBackend {
    struct Record { let method: String; let path: String; let key: String?; let body: Data }
    private let lock = NSLock()
    var job = ReadinessBackend.delivery()
    var now = 1000
    var teamId = "review"
    var restaurants: [Restaurant] = []
    var records: [Record] = []
    var deleted = false
    var deleteWrites = 0
    var loseDeleteResponse = false
    var cancelDeleteResponse = false
    var readinessWrites = 0
    var restaurantWrites = 0
    var failReads = false
    var failReadsAfterWrite = false
    var loseReadinessResponse = false
    var cancelReadinessResponse = false
    var loseRestaurantResponse = false
    var autoAssign = false
    var deliveryReadOverride: Delivery?
    var gatedPath: String?
    var gate: DispatchSemaphore?
    var onGatedRequest: (() -> Void)?
    private var replays: [String: Data] = [:]

    func withState<T>(_ operation: (ReadinessBackend) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation(self)
    }
    static func delivery(status: DeliveryStatus = .pending, state: ReadinessState = .unknown,
                         revision: UInt64 = 0, readyAt: Int = 1) -> Delivery {
        Delivery(id: "delivery-1", shopName: "Pizzeria", pickupAddress: "Via Roma 1", pickup: .pachino,
                 dropoffAddress: "Via Garibaldi 8", dropoff: .pachino, readyAt: readyAt, deadlineAt: 2_000_000_000,
                 loadUnits: 1, maxRideSeconds: 1800, status: status, driverId: status == .pending ? nil : "dual-1",
                 createdAt: 1, pickedUpAt: nil, deliveredAt: nil, readinessState: state, readinessRevision: revision,
                 readinessUpdatedAt: revision == 0 ? nil : readyAt)
    }
    func respond(to request: URLRequest) throws -> (Int, Data) {
        let body = try Self.body(of: request)
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        let key = request.value(forHTTPHeaderField: "Idempotency-Key")
        var held: DispatchSemaphore?
        var received: (() -> Void)?
        let response: (Int, Data) = try withState { state in
            state.records.append(Record(method: method, path: path, key: key, body: body))
            if path == state.gatedPath {
                held = state.gate; received = state.onGatedRequest
                state.gatedPath = nil; state.gate = nil; state.onGatedRequest = nil
            }
            if method == "GET", state.failReads { return (503, Data(#"{"error":"Read unavailable"}"#.utf8)) }
            let driver = Driver(id: "dual-1", name: "Revisione", active: true, capacity: 2, location: .pachino, locationUpdatedAt: 1000)
            let route = DriverRoute(driverId: "dual-1", stops: [RouteStop(deliveryId: "delivery-1", kind: .pickup,
                address: "Via Roma 1", coordinate: .pachino, arrivalAt: state.job.readyAt, departureAt: state.job.readyAt + 60)],
                travelSeconds: 0, finishAt: 1800, feasible: true, warnings: [])
            if method == "GET" {
                switch path {
                case "/v1/me": return (200, try APIClient.encoder().encode(Principal(id: "dual-1", name: "Revisione", role: "dispatcher", roles: ["dispatcher", "driver"], teamId: state.teamId)))
                case "/v1/deliveries": return (200, try APIClient.encoder().encode(state.deleted ? [] : [state.deliveryReadOverride ?? state.job]))
                case "/v1/drivers": return (200, try APIClient.encoder().encode([driver]))
                case "/v1/shift": return (200, try APIClient.encoder().encode(driver))
                case "/v1/route", "/v1/drivers/dual-1/route": return (200, try APIClient.encoder().encode(route))
                case "/v1/restaurants": return (200, try APIClient.encoder().encode(state.restaurants))
                case "/v1/deliveries/delivery-1/suggestions": return (200, try APIClient.encoder().encode([Suggestion(driverId: "dual-1", incrementalTravelSeconds: 0, route: route)]))
                default: return (404, Data())
                }
            }
            if let key, let replay = state.replays[key] { return (200, replay) }
            if state.failReadsAfterWrite { state.failReads = true }
            if method == "DELETE", path == "/v1/deliveries/delivery-1" {
                state.deleted = true
                state.deleteWrites += 1
                if state.loseDeleteResponse { throw URLError(.networkConnectionLost) }
                if state.cancelDeleteResponse { throw CancellationError() }
                return (204, Data())
            }
            if path.hasSuffix("/readiness") {
                let update = try APIClient.decoder().decode(ReadinessUpdate.self, from: body)
                guard state.job.readinessRevision == update.expectedRevision else {
                    return (409, Data(#"{"error":"Readiness changed; refresh the delivery and try again"}"#.utf8))
                }
                state.readinessWrites += 1
                state.job = Self.delivery(status: state.autoAssign && update.readyInMinutes == 0 ? .assigned : state.job.status,
                    state: update.readyInMinutes == 0 ? .ready : .estimated, revision: state.job.readinessRevision + 1,
                    readyAt: state.now + update.readyInMinutes * 60)
                let data = try APIClient.encoder().encode(state.job)
                if let key { state.replays[key] = data }
                if state.loseReadinessResponse { throw URLError(.networkConnectionLost) }
                if state.cancelReadinessResponse { throw CancellationError() }
                return (200, data)
            }
            if path == "/v1/restaurants" {
                let draft = try APIClient.decoder().decode(NewRestaurant.self, from: body)
                state.restaurantWrites += 1
                let restaurant = Restaurant(id: "restaurant-1", name: draft.name, address: draft.address, coordinate: draft.coordinate, createdAt: state.now)
                state.restaurants.append(restaurant)
                let data = try APIClient.encoder().encode(restaurant)
                if let key { state.replays[key] = data }
                if state.loseRestaurantResponse { throw URLError(.networkConnectionLost) }
                return (201, data)
            }
            return (404, Data())
        }
        received?()
        if let held, held.wait(timeout: .now() + 10) == .timedOut { throw URLError(.timedOut) }
        return response
    }
    private static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class ReadinessStorage: SessionStorage {
    private let base = MemorySessionStorage()
    var failSave = false
    var failClear = false
    func loadSession() throws -> SavedSession? { try base.loadSession() }
    func saveSession(_ value: SavedSession) throws { try base.saveSession(value) }
    func clearSession() throws { try base.clearSession() }
    func loadCreation(scope: String) throws -> PendingCreation? { try base.loadCreation(scope: scope) }
    func saveCreation(_ value: PendingCreation, scope: String) throws { try base.saveCreation(value, scope: scope) }
    func clearCreation(scope: String) throws { try base.clearCreation(scope: scope) }
    func loadRestaurant(scope: String) throws -> PendingRestaurant? { try base.loadRestaurant(scope: scope) }
    func saveRestaurant(_ value: PendingRestaurant, scope: String) throws {
        if failSave { throw APIError(message: "Test storage unavailable") }
        try base.saveRestaurant(value, scope: scope)
    }
    func clearRestaurant(scope: String) throws {
        if failClear { throw APIError(message: "Test storage unavailable") }
        try base.clearRestaurant(scope: scope)
    }
}
