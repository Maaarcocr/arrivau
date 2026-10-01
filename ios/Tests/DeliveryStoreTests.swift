import XCTest
@testable import Arrivau

/// Confirmed writes remain usable when a follow-up read fails; taps never invent success.
@MainActor
final class DeliveryStoreTests: XCTestCase {
    private var session: URLSession!
    private var backend: DriverStoreBackend!
    private var store: DeliveryStore!

    override func setUp() async throws {
        try await super.setUp()
        backend = DriverStoreBackend()
        DriverStoreURLProtocol.backend = backend
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriverStoreURLProtocol.self]
        session = URLSession(configuration: configuration)
        store = DeliveryStore(session: session, deterministicLocation: true)
        store.apiURL = "http://localhost:8080"
    }

    override func tearDown() async throws {
        store.logout()
        session.invalidateAndCancel()
        DriverStoreURLProtocol.backend = nil
        store = nil
        backend = nil
        try await super.tearDown()
    }

    func testStartShiftPreservesCapacityAndExplicitlyOptsIntoForegroundOnly() async {
        await store.login(as: .driver1)
        XCTAssertFalse(store.locationSharing)
        await store.startShiftAndShareLocation()
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertEqual(store.currentDriver?.capacity, 5)
        XCTAssertTrue(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertEqual(backend.withState { $0.lastShiftCapacity }, 5)
        await store.startShiftAndShareLocation()
        XCTAssertEqual(backend.withState { $0.shiftWrites }, 1, "Repeated start must not start another shift")
    }

    func testFailedStartNeverEnablesLocationSharing() async {
        await store.login(as: .driver1)
        backend.withState { $0.rejectWrites = true }
        await store.startShiftAndShareLocation()
        XCTAssertEqual(store.currentDriver?.active, false)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
        XCTAssertNotNil(store.errorMessage)
    }

    func testConfirmedStartSurvivesFailedFollowUpRead() async {
        await store.login(as: .driver1)
        backend.withState { $0.failReadsAfterWrite = true }
        await store.startShiftAndShareLocation()
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertTrue(store.locationSharing)
        XCTAssertNotNil(store.syncErrorMessage)
    }

    func testExistingActiveShiftRequiresFreshOptInAfterRoleSwitch() async {
        backend.withState { $0.active = true }
        await store.login(as: .driver1)
        XCTAssertFalse(store.locationSharing)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        XCTAssertTrue(store.backgroundLocationSharing)
        store.logout()
        await store.login(as: .driver1)
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
    }

    func testEndShiftStopsBothOptInsAndRejectedEndKeepsThem() async {
        backend.withState { $0.active = true }
        await store.login(as: .driver1)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        backend.withState { $0.rejectWrites = true }
        await store.setShift(active: false, capacity: 5)
        XCTAssertEqual(store.currentDriver?.active, true)
        XCTAssertTrue(store.locationSharing)
        XCTAssertTrue(store.backgroundLocationSharing)
        backend.withState { $0.rejectWrites = false; $0.failReadsAfterWrite = true }
        await store.setShift(active: false, capacity: 5)
        XCTAssertEqual(store.currentDriver?.active, false)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
    }

    func testOffShiftCannotOptIntoLocation() async {
        await store.login(as: .driver1)
        store.setLocationSharing(true)
        store.setBackgroundLocationSharing(true)
        XCTAssertFalse(store.locationSharing)
        XCTAssertFalse(store.backgroundLocationSharing)
    }

    func testCreatedDeliveryRemainsVisibleWhenRefreshFails() async {
        await store.login(as: .dispatcher)
        backend.withState { $0.failReadsAfterWrite = true }
        let created = await store.create(Fixtures.newDelivery)
        XCTAssertNotNil(created)
        XCTAssertEqual(store.deliveries.map(\.id), ["delivery-1"])
        XCTAssertEqual(store.deliveries.first?.status, .pending)
        XCTAssertFalse(store.createOutcomeUncertain)
        XCTAssertNotNil(store.syncErrorMessage)
    }

    func testDoubleCreateWhileRequestIsPendingCreatesOnlyOnce() async {
        await store.login(as: .dispatcher)
        let requestStarted = expectation(description: "Create request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        backend.withState {
            $0.onCreateRequest = { requestStarted.fulfill() }
            $0.createResponseGate = releaseResponse
        }
        let first = Task { await store.create(Fixtures.newDelivery) }
        await fulfillment(of: [requestStarted], timeout: 5)
        let second = await store.create(Fixtures.newDelivery)
        XCTAssertNil(second)
        releaseResponse.signal()
        let created = await first.value
        XCTAssertNotNil(created)
        XCTAssertEqual(backend.withState { $0.createWrites }, 1)
    }

    func testLostCreateResponseReconcilesAndWarnsAgainstRepeating() async {
        await store.login(as: .dispatcher)
        backend.withState { $0.loseCreateResponse = true }
        let created = await store.create(Fixtures.newDelivery)
        XCTAssertNil(created)
        XCTAssertTrue(store.createOutcomeUncertain)
        XCTAssertEqual(store.deliveries.count, 1, "The follow-up read recovers the committed delivery")
        XCTAssertEqual(store.errorMessage, "Impossibile confermare la creazione. Controlla l’elenco delle consegne prima di riprovare.")
    }

    func testConfirmedAssignmentCannotBeRepeatedAfterFailedRefresh() async {
        backend.withState { $0.jobs = [DriverStoreBackend.delivery(status: .pending)] }
        await store.login(as: .dispatcher)
        backend.withState { $0.failReadsAfterWrite = true }
        let assigned = await store.assign(deliveryId: "delivery-1", driverId: "driver-1")
        XCTAssertTrue(assigned)
        XCTAssertEqual(store.deliveries.first?.status, .assigned)
        let repeated = await store.assign(deliveryId: "delivery-1", driverId: "driver-1")
        XCTAssertTrue(repeated, "An already confirmed assignment needs no second write")
        XCTAssertEqual(backend.withState { $0.assignmentWrites }, 1)
    }

    func testConfirmedPickupCannotBeRepeatedOrSkipToDropoffUsingOldView() async throws {
        backend.withState { $0.active = true; $0.jobs = [DriverStoreBackend.delivery(status: .assigned)] }
        await store.login(as: .driver1)
        let oldDelivery = try XCTUnwrap(store.deliveries.first)
        backend.withState { $0.failReadsAfterWrite = true }
        await store.completeNextStop(oldDelivery)
        XCTAssertEqual(store.deliveries.first?.status, .pickedUp)
        XCTAssertEqual(store.route?.stops.first?.kind, .dropoff)
        await store.completeNextStop(oldDelivery)
        XCTAssertEqual(backend.withState { $0.statusWrites }, 1, "A stale pickup callback must not confirm a drop-off")
        let currentDelivery = try XCTUnwrap(store.deliveries.first)
        await store.completeNextStop(currentDelivery)
        XCTAssertEqual(store.deliveries.first?.status, .delivered)
        XCTAssertEqual(store.route?.stops.count, 0)
    }

    func testRejectedPickupDoesNotAdvanceTheRoute() async throws {
        backend.withState { $0.active = true; $0.jobs = [DriverStoreBackend.delivery(status: .assigned)] }
        await store.login(as: .driver1)
        let delivery = try XCTUnwrap(store.deliveries.first)
        backend.withState { $0.rejectWrites = true }
        await store.completeNextStop(delivery)
        XCTAssertEqual(store.deliveries.first?.status, .assigned)
        XCTAssertEqual(store.route?.stops.first?.kind, .pickup)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLostPickupResponseRefreshesConfirmedStatusBeforeUnlocking() async throws {
        backend.withState { $0.active = true; $0.jobs = [DriverStoreBackend.delivery(status: .assigned)] }
        await store.login(as: .driver1)
        let delivery = try XCTUnwrap(store.deliveries.first)
        backend.withState { $0.loseStatusResponse = true }
        await store.completeNextStop(delivery)
        XCTAssertEqual(store.deliveries.first?.status, .pickedUp)
        XCTAssertEqual(store.route?.stops.first?.kind, .dropoff)
        await store.completeNextStop(delivery)
        XCTAssertEqual(backend.withState { $0.statusWrites }, 1)
    }
}

private final class DriverStoreURLProtocol: URLProtocol {
    static var backend: DriverStoreBackend?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let backend = Self.backend else { throw URLError(.cancelled) }
            let (status, data) = try backend.respond(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class DriverStoreBackend {
    private let lock = NSLock()
    var active = false
    var jobs: [Delivery] = []
    var rejectWrites = false
    var failReadsAfterWrite = false
    var failReads = false
    var loseCreateResponse = false
    var loseStatusResponse = false
    var lastShiftCapacity: Int?
    var shiftWrites = 0
    var createWrites = 0
    var assignmentWrites = 0
    var statusWrites = 0
    var onCreateRequest: (() -> Void)?
    var createResponseGate: DispatchSemaphore?

    func withState<T>(_ operation: (DriverStoreBackend) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation(self)
    }

    static func delivery(status: DeliveryStatus) -> Delivery {
        Delivery(id: "delivery-1", shopName: "Pizzeria", pickupAddress: "Via Roma 1", pickup: .pachino,
                 dropoffAddress: "Via Garibaldi 8", dropoff: .pachino, readyAt: 1, deadlineAt: 2_000_000_000,
                 loadUnits: 1, maxRideSeconds: 1800, status: status, driverId: status == .pending ? nil : "driver-1",
                 createdAt: 1, pickedUpAt: status == .pickedUp || status == .delivered ? 2 : nil,
                 deliveredAt: status == .delivered ? 3 : nil)
    }
    private var driver: Driver {
        Driver(id: "driver-1", name: "Driver 1", active: active, capacity: 5, location: nil, locationUpdatedAt: nil)
    }
    private var route: DriverRoute {
        let stops = jobs.flatMap { delivery -> [RouteStop] in
            guard delivery.status == .assigned || delivery.status == .pickedUp else { return [] }
            let dropoff = RouteStop(deliveryId: delivery.id, kind: .dropoff, address: delivery.dropoffAddress, coordinate: delivery.dropoff, arrivalAt: 100, departureAt: 160)
            if delivery.status == .pickedUp { return [dropoff] }
            return [RouteStop(deliveryId: delivery.id, kind: .pickup, address: delivery.pickupAddress, coordinate: delivery.pickup, arrivalAt: 10, departureAt: 70), dropoff]
        }
        return DriverRoute(driverId: "driver-1", stops: stops, travelSeconds: 120, finishAt: 160, feasible: true, warnings: [])
    }
    func respond(to request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if request.httpMethod == "GET" {
            if path == "/v1/me" {
                let dispatcher = request.value(forHTTPHeaderField: "Authorization") == "Bearer demo-dispatcher"
                return (200, Data((dispatcher ? #"{"id":"dispatcher","name":"Dispatcher","role":"dispatcher"}"# : #"{"id":"driver-1","name":"Driver 1","role":"driver"}"#).utf8))
            }
            if failReads { return (503, Data(#"{"error":"Refresh unavailable"}"#.utf8)) }
            switch path {
            case "/v1/shift": return (200, try APIClient.encoder().encode(driver))
            case "/v1/drivers": return (200, try APIClient.encoder().encode([driver]))
            case "/v1/deliveries": return (200, try APIClient.encoder().encode(jobs))
            case "/v1/route": return (200, try APIClient.encoder().encode(route))
            default: return (404, Data(#"{"error":"Not found"}"#.utf8))
            }
        }
        if rejectWrites { return (409, Data(#"{"error":"Action rejected"}"#.utf8)) }
        if failReadsAfterWrite { failReads = true }
        let payload = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any] ?? [:]
        switch path {
        case "/v1/shift":
            shiftWrites += 1
            lastShiftCapacity = payload["capacity"] as? Int
            active = payload["active"] as? Bool ?? false
            return (200, try APIClient.encoder().encode(driver))
        case "/v1/deliveries":
            createWrites += 1
            onCreateRequest?()
            _ = createResponseGate?.wait(timeout: .now() + 10)
            let delivery = Self.delivery(status: .pending)
            jobs.append(delivery)
            if loseCreateResponse { throw URLError(.networkConnectionLost) }
            return (201, try APIClient.encoder().encode(delivery))
        case "/v1/deliveries/delivery-1/assign":
            assignmentWrites += 1
            let delivery = Self.delivery(status: .assigned)
            jobs = [delivery]
            return (200, try APIClient.encoder().encode(delivery))
        case "/v1/deliveries/delivery-1/status":
            statusWrites += 1
            let status = DeliveryStatus(rawValue: payload["status"] as? String ?? "") ?? .assigned
            let delivery = Self.delivery(status: status)
            jobs = [delivery]
            if loseStatusResponse { throw URLError(.networkConnectionLost) }
            return (200, try APIClient.encoder().encode(delivery))
        default: return (404, Data(#"{"error":"Not found"}"#.utf8))
        }
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
