import XCTest
@testable import Arrivau

@MainActor
final class DriverNavigationTests: XCTestCase {
    private let principal = Principal(id: "driver-1", name: "Corriere", role: "driver", teamId: "team-1")
    private let driver = Driver(id: "driver-1", name: "Corriere", active: true, capacity: 2, location: .pachino, locationUpdatedAt: 1)
    private var destination: NavigationDestination {
        NavigationDestination(accountID: "driver-1", teamID: "team-1", stopID: "delivery-1-pickup",
                              googlePlaceID: "test-place-id", coordinate: .pachino, title: "Ritiro", address: "Indirizzo del cliente")
    }
    private func route(_ stops: [RouteStop], driverID: String = "driver-1") -> DriverRoute {
        DriverRoute(driverId: driverID, stops: stops, travelSeconds: 10, finishAt: 20, feasible: true,
                    warnings: [], notices: [], estimatesAvailable: true, travelEstimate: nil)
    }
    private func stop(_ id: String = "delivery-1", arrival: Int = 10, coordinate: Coordinate = .pachino) -> RouteStop {
        RouteStop(googlePlaceId: "test-place-id", deliveryId: id, kind: .pickup, address: "Indirizzo del cliente",
                  coordinate: coordinate, arrivalAt: arrival, departureAt: arrival + 60)
    }
    func testOnlyAuthoritativeFirstStopBecomesDestination() {
        let first = NavigationDestination.next(principal: principal, role: .driver, driver: driver, route: route([stop(), stop("second")]))
        XCTAssertEqual(first, destination)
        XCTAssertEqual(first?.googlePlaceID, "test-place-id")
        XCTAssertNil(NavigationDestination.next(principal: principal, role: .driver, driver: driver, route: route([])))
        XCTAssertNil(NavigationDestination.next(principal: principal, role: .driver, driver: driver, route: route([stop()], driverID: "someone-else")))
        XCTAssertNil(NavigationDestination.next(principal: principal, role: .dispatcher, driver: driver, route: route([stop()])))
        XCTAssertNil(NavigationDestination.next(principal: nil, role: .driver, driver: driver, route: route([stop()])))
        let offShift = Driver(id: "driver-1", name: "Corriere", active: false, capacity: 2, location: nil, locationUpdatedAt: nil)
        XCTAssertNil(NavigationDestination.next(principal: principal, role: .driver, driver: offShift, route: route([stop()])))
    }
    func testChangingOnlyEstimatesDoesNotInvalidateGuidance() {
        let updated = NavigationDestination.next(principal: principal, role: .driver, driver: driver, route: route([stop(arrival: 90)]))
        XCTAssertEqual(updated, destination)
        XCTAssertNil(NavigationDestination.next(principal: principal, role: .driver, driver: driver,
                                               route: route([stop(coordinate: Coordinate(lat: .nan, lng: 15))])))
    }
    func testGoogleIDStillNavigatesWithoutCachedCoordinatesAndRefreshDoesNotRestartIt() {
        let uncached = RouteStop(googlePlaceId: "test-place-id", deliveryId: "delivery-1", kind: .pickup,
                                 address: "Indirizzo del cliente", coordinate: nil, arrivalAt: 0, departureAt: 0)
        let target = NavigationDestination.next(principal: principal, role: .driver, driver: driver, route: route([uncached]))
        XCTAssertEqual(target, destination)
        XCTAssertNil(target?.coordinate)
        XCTAssertEqual(target?.googlePlaceID, destination.googlePlaceID)
    }
    func testLegacyStopsNeverInventGooglePlaceIDs() throws {
        let legacy = Data(#"{"delivery_id":"d","kind":"pickup","address":"Via","coordinate":{"lat":36.7,"lng":15.1},"arrival_at":1,"departure_at":2}"#.utf8)
        XCTAssertNil(try APIClient.decoder().decode(RouteStop.self, from: legacy).googlePlaceId)
        let modern = try APIClient.decoder().decode(RouteStop.self, from: APIClient.encoder().encode(stop()))
        XCTAssertEqual(modern.googlePlaceId, "test-place-id")
    }
    func testMissingAndMalformedConfigurationFailsClosed() {
        for value in ["", " ", "$(ARRIVAU_GOOGLE_MAPS_API_KEY)", "YOUR_API_KEY", "AIzaBAD", "AIza" + String(repeating: "!", count: 35)] {
            XCTAssertNil(GoogleNavigationConfiguration(info: ["ARRIVAU_GOOGLE_MAPS_API_KEY": value]).apiKey)
        }
        XCTAssertNil(GoogleNavigationConfiguration(info: [:]).apiKey)
        let placeholder = "AIza" + String(repeating: "x", count: 35)
        XCTAssertEqual(GoogleNavigationConfiguration(info: ["ARRIVAU_GOOGLE_MAPS_API_KEY": " \(placeholder)\n"]).apiKey, placeholder)
    }
    func testRepeatedStartDoesNotDuplicateRouting() {
        let engine = NavigationEngineSpy()
        let session = DriverNavigationSession(destination: destination, engine: engine)
        session.start(); session.start()
        XCTAssertEqual(engine.destinations, [destination])
        engine.callbacks[0](.navigating)
        session.start()
        XCTAssertEqual(engine.destinations.count, 1)
    }
    func testCloseRejectsLateRouteAndArrivalCallbacks() {
        let engine = NavigationEngineSpy()
        let session = DriverNavigationSession(destination: destination, engine: engine)
        session.start()
        session.stop()
        engine.callbacks[0](.navigating)
        engine.callbacks[0](.arrived)
        session.start()
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.destinations.count, 1)
    }
    func testRetryRejectsOldRequestSuccessAndPreservesExactTarget() {
        let engine = NavigationEngineSpy()
        let session = DriverNavigationSession(destination: destination, engine: engine)
        session.start()
        engine.callbacks[0](.failed(.network))
        session.start()
        engine.callbacks[0](.arrived)
        XCTAssertEqual(session.state, .preparing)
        engine.callbacks[1](.navigating)
        XCTAssertEqual(session.state, .navigating)
        XCTAssertEqual(engine.destinations, [destination, destination])
    }
    func testNextStopOrAccountChangeStopsRatherThanReroutingSilently() {
        for current in [nil, NavigationDestination(accountID: "other", teamID: "team-1", stopID: destination.stopID,
                                                  googlePlaceID: destination.googlePlaceID, coordinate: .pachino, title: "Ritiro", address: destination.address)] {
            let engine = NavigationEngineSpy()
            let session = DriverNavigationSession(destination: destination, engine: engine)
            session.start()
            session.validate(current: current)
            engine.callbacks[0](.navigating)
            XCTAssertEqual(session.state, .failed(.destinationChanged))
            XCTAssertEqual(engine.stopCount, 1)
            session.start()
            XCTAssertEqual(engine.destinations.count, 1)
        }
    }
    func testArrivalIsAdvisoryAndCannotAdvanceAStop() {
        let engine = NavigationEngineSpy()
        let session = DriverNavigationSession(destination: destination, engine: engine)
        session.start()
        engine.callbacks[0](.arrived)
        XCTAssertEqual(session.state, .arrived)
        XCTAssertEqual(session.destination, destination)
        XCTAssertEqual(engine.destinations, [destination])
        XCTAssertFalse(session.state.canRetry)
        // The engine/session has no DeliveryStore, HTTP client or complete/next-stop callback.
    }
    func testBackgroundAndMuteAreSeparateExplicitNonPersistentChoices() {
        let engine = NavigationEngineSpy()
        let session = DriverNavigationSession(destination: destination, engine: engine)
        XCTAssertFalse(session.backgroundAllowed)
        XCTAssertFalse(session.muted)
        session.start()
        XCTAssertEqual(engine.backgroundChanges, [false])
        XCTAssertEqual(engine.muteChanges, [false])
        session.setBackgroundAllowed(true)
        session.setMuted(true)
        session.setForeground(false)
        XCTAssertEqual(engine.backgroundChanges, [false, true])
        XCTAssertEqual(engine.muteChanges, [false, true])
        XCTAssertEqual(engine.foregroundChanges, [false])
        session.stop()
        session.setForeground(true)
        session.setBackgroundAllowed(false)
        XCTAssertEqual(engine.foregroundChanges, [false])
        XCTAssertEqual(engine.backgroundChanges, [false, true])
    }
    func testEveryFailureLeavesAnItalianActionableState() {
        for error in [NavigationFailure.missingKey, .destinationSource, .locationDenied, .preciseLocationRequired, .termsDeclined,
                      .network, .noRoute, .unavailable, .destinationChanged, .timedOut] {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertEqual(DriverNavigationState.failed(error).canRetry, error.canRetry)
        }
        XCTAssertTrue(NavigationFailure.locationDenied.needsSettings)
        XCTAssertFalse(NavigationFailure.missingKey.canRetry)
    }
}

@MainActor
private final class NavigationEngineSpy: DriverNavigationEngine {
    var destinations: [NavigationDestination] = []
    var callbacks: [(DriverNavigationState) -> Void] = []
    var stopCount = 0
    var backgroundChanges: [Bool] = []
    var muteChanges: [Bool] = []
    var foregroundChanges: [Bool] = []
    func start(to destination: NavigationDestination, event: @escaping (DriverNavigationState) -> Void) {
        destinations.append(destination); callbacks.append(event)
    }
    func stop() { stopCount += 1 }
    func setForeground(_ foreground: Bool) { foregroundChanges.append(foreground) }
    func setBackgroundAllowed(_ allowed: Bool) { backgroundChanges.append(allowed) }
    func setMuted(_ muted: Bool) { muteChanges.append(muted) }
}
