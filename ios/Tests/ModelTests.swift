import XCTest
@testable import Arrivau

final class ModelTests: XCTestCase {
    func testLegacyIdentityDecodesOnlyItsSingleRole() throws {
        for role in ["dispatcher", "driver"] {
            let data = Data("{\"id\":\"account\",\"name\":\"Persona\",\"role\":\"\(role)\"}".utf8)
            let user = try APIClient.decoder().decode(Principal.self, from: data)
            XCTAssertEqual(user.roles, [role])
            XCTAssertEqual(user.availableRoles.count, 1)
            XCTAssertEqual(user.serverRole?.rawValue, role)
            XCTAssertNil(user.teamId)
            XCTAssertNil(user.teamTitle)
        }
    }
    func testDualIdentityUsesOnlyServerCapabilitiesAndTeam() throws {
        let data = Data(#"{"id":"reviewer","name":"Revisione","role":"dispatcher","roles":["dispatcher","driver"],"team_id":"review","team_name":"Squadra revisione"}"#.utf8)
        let user = try APIClient.decoder().decode(Principal.self, from: data)
        XCTAssertEqual(user.availableRoles, [.dispatcher, .driver])
        XCTAssertEqual(user.serverRole, .dispatcher)
        XCTAssertEqual(user.teamId, "review")
        XCTAssertEqual(user.teamTitle, "Squadra revisione")
        XCTAssertEqual(try APIClient.decoder().decode(Principal.self, from: APIClient.encoder().encode(user)), user)
        let narrowed = Principal(id: "reviewer", name: "Revisione", role: "dispatcher", roles: ["driver"], teamId: "review")
        XCTAssertEqual(narrowed.serverRole, .driver, "Legacy primary role must never expand explicit capabilities")
        XCTAssertFalse(narrowed.supports(.dispatcher))
        XCTAssertNil(Principal(id: "x", name: "X", role: "dispatcher", roles: []).serverRole)
        XCTAssertNil(Principal(id: "x", name: "X", role: "dispatcher", roles: ["admin"]).serverRole)
    }
    func testMalformedCapabilitiesNeverFallBackToLegacyPrivilege() throws {
        for roles in ["null", "123", "\"driver\"", "[null]"] {
            let data = Data("{\"id\":\"x\",\"name\":\"X\",\"role\":\"dispatcher\",\"roles\":\(roles)}".utf8)
            XCTAssertThrowsError(try APIClient.decoder().decode(Principal.self, from: data))
        }
        let empty = Data(#"{"id":"x","name":"X","role":"dispatcher","roles":[]}"#.utf8)
        XCTAssertNil(try APIClient.decoder().decode(Principal.self, from: empty).serverRole)
        for team in ["null", "\"\"", "\"   \""] {
            let data = Data("{\"id\":\"x\",\"name\":\"X\",\"role\":\"dispatcher\",\"team_id\":\(team)}".utf8)
            XCTAssertThrowsError(try APIClient.decoder().decode(Principal.self, from: data))
        }
    }
    func testRecoveryScopeIncludesTeamAccountEndpointWithoutDelimiterCollisions() {
        let first = Principal(id: "a|b", name: "X", role: "dispatcher", teamId: "review")
        let second = Principal(id: "b", name: "X", role: "dispatcher", teamId: "review|a")
        let firstScope = CreationScope.current(endpoint: "https://api.example", user: first)
        XCTAssertNotEqual(firstScope, CreationScope.current(endpoint: "https://api.example", user: second))
        XCTAssertNotEqual(firstScope, CreationScope.current(endpoint: "https://other.example", user: first))
        XCTAssertEqual(CreationScope.current(endpoint: "https://api.example", user: Principal(id: "x", name: "X", role: "dispatcher")), "https://api.example|x")
    }
    func testDecodesSnakeCaseEpochContract() throws {
        let delivery = try APIClient.decoder().decode(Delivery.self, from: Fixtures.delivery)
        XCTAssertEqual(delivery.shopName, "Pizzeria")
        XCTAssertEqual(delivery.driverId, "driver-1")
        XCTAssertEqual(delivery.readyAt, 1_790_874_000)
        XCTAssertEqual(delivery.status, .assigned)
        XCTAssertNil(delivery.pickedUpAt)
        XCTAssertEqual(delivery.pickup, .pachino)
    }
    func testReadinessCompatibilityAndKnownTimestampGuards() throws {
        let legacy = try APIClient.decoder().decode(Delivery.self, from: Fixtures.delivery)
        XCTAssertEqual(legacy.readinessState, .estimated)
        XCTAssertEqual(legacy.readinessRevision, 0)
        XCTAssertNil(legacy.readinessUpdatedAt)
        XCTAssertNil(legacy.onboardDeadlineAt)
        XCTAssertNil(legacy.dispatchWaitingReason)
        let route = try APIClient.decoder().decode(DriverRoute.self, from: Fixtures.route)
        for state in [ReadinessState.unknown, .estimated, .ready] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.delivery) as? [String: Any])
            object["readiness_state"] = state.rawValue
            object["readiness_revision"] = 3
            object["readiness_updated_at"] = 1_790_873_900
            object["onboard_deadline_at"] = 1_790_875_800
            let delivery = try APIClient.decoder().decode(Delivery.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(delivery.readinessState, state)
            XCTAssertEqual(delivery.readinessRevision, 3)
            XCTAssertEqual(delivery.readinessUpdatedAt, 1_790_873_900)
            XCTAssertEqual(delivery.onboardDeadlineAt, 1_790_875_800)
            XCTAssertEqual(DeliveryAction.nextStatus(delivery: delivery, route: route, now: delivery.readyAt + 1), state == .unknown ? nil : .pickedUp)
            XCTAssertNil(DeliveryAction.nextStatus(delivery: delivery, route: route, now: delivery.readyAt - 1))
            XCTAssertEqual(delivery.pickupTargetAt, state == .unknown ? nil : delivery.readyAt + 600)
            XCTAssertEqual(try APIClient.decoder().decode(Delivery.self, from: APIClient.encoder().encode(delivery)), delivery)
            if state == .unknown { XCTAssertEqual(delivery.readinessTitle, "Da definire") }
            if state == .estimated {
                XCTAssertTrue(delivery.readinessTitle.contains("stima"), "An elapsed forecast never becomes confirmed")
                XCTAssertFalse(delivery.readinessTitle.contains("confermata"))
            }
            if state == .ready { XCTAssertTrue(delivery.readinessTitle.contains("confermata")) }
        }
    }
    func testNewCreationOmitsUnknownReadinessButDecodesLegacyRecovery() throws {
        let original = Fixtures.newDelivery
        let draft = NewDelivery(shopName: original.shopName, pickupAddress: original.pickupAddress,
                                pickup: original.pickup, dropoffAddress: original.dropoffAddress, dropoff: original.dropoff,
                                readyAt: nil, deadlineAt: original.deadlineAt, loadUnits: 1, maxRideSeconds: 1800)
        XCTAssertNil(draft.validationError)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(draft)) as? [String: Any])
        XCTAssertNil(body["ready_at"])
        XCTAssertNil(body["restaurant_id"], "Legacy recovery hashes must omit a missing restaurant ID")
        XCTAssertEqual(try APIClient.decoder().decode(NewDelivery.self, from: APIClient.encoder().encode(draft)), draft)
        XCTAssertEqual(try APIClient.decoder().decode(NewDelivery.self, from: APIClient.encoder().encode(original)), original)
    }
    func testSoftNoticesDecodeWithoutChangingFeasibilityOrHardWarnings() throws {
        let legacy = try APIClient.decoder().decode(DriverRoute.self, from: Fixtures.route)
        XCTAssertEqual(legacy.notices, [])
        XCTAssertTrue(legacy.estimatesAvailable)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.route) as? [String: Any])
        object["notices"] = ["Pickup target missed for delivery-1"]
        let route = try APIClient.decoder().decode(DriverRoute.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(route.feasible)
        XCTAssertEqual(route.warnings, [])
        XCTAssertEqual(route.localizedNotices, ["Ritiro previsto oltre l’obiettivo di 10 minuti dalla disponibilità."])
        XCTAssertEqual(try APIClient.decoder().decode(DriverRoute.self, from: APIClient.encoder().encode(route)), route)
    }
    func testUnavailableEstimatesAndPendingReasonsDecodeWithItalianPresentation() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.route) as? [String: Any])
        object["estimates_available"] = false
        let route = try APIClient.decoder().decode(DriverRoute.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(route.estimatesAvailable)
        XCTAssertFalse(route.stops.isEmpty, "Missing GPS must not discard committed stops")
        var job = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.delivery) as? [String: Any])
        for (reason, expected) in [("no_active_driver", "Nessun corriere in turno"), ("capacity_or_route_limit", "al completo"), ("Future English reason", "Assegnazione in attesa")] {
            job["dispatch_waiting_reason"] = reason
            let delivery = try APIClient.decoder().decode(Delivery.self, from: JSONSerialization.data(withJSONObject: job))
            XCTAssertTrue(try XCTUnwrap(delivery.localizedDispatchWaitingReason).contains(expected))
            XCTAssertFalse(try XCTUnwrap(delivery.localizedDispatchWaitingReason).contains("English"))
        }
    }
    func testSavedRestaurantBecomesExactCreationSnapshotAndID() throws {
        let restaurant = Restaurant(id: "restaurant-1", name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino, createdAt: 1000)
        XCTAssertEqual(try APIClient.decoder().decode(Restaurant.self, from: APIClient.encoder().encode(restaurant)), restaurant)
        let draft = NewDelivery(shopName: restaurant.name, pickupAddress: restaurant.address, pickup: restaurant.coordinate,
                                dropoffAddress: "Via Garibaldi 8", dropoff: .pachino, readyAt: nil,
                                deadlineAt: 2000, loadUnits: 1, maxRideSeconds: 1800, restaurantId: restaurant.id)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(draft)) as? [String: Any])
        XCTAssertEqual(body["restaurant_id"] as? String, restaurant.id)
        XCTAssertEqual(body["shop_name"] as? String, restaurant.name)
        XCTAssertEqual(body["pickup_address"] as? String, restaurant.address)
        XCTAssertNil(body["ready_at"])
        XCTAssertNil(draft.validationError)
        XCTAssertNotNil(NewRestaurant(name: " ", address: "Via Roma", coordinate: .pachino).validationError)
        XCTAssertNotNil(NewRestaurant(name: "Pizzeria", address: "Via Roma", coordinate: Coordinate(lat: 91, lng: 0)).validationError)
    }
    func testNextStopCannotSkipPickupOrReadyTime() throws {
        let delivery = try APIClient.decoder().decode(Delivery.self, from: Fixtures.delivery)
        let route = try APIClient.decoder().decode(DriverRoute.self, from: Fixtures.route)
        XCTAssertNil(DeliveryAction.nextStatus(delivery: delivery, route: route, now: delivery.readyAt - 1))
        XCTAssertEqual(DeliveryAction.nextStatus(delivery: delivery, route: route, now: delivery.readyAt), .pickedUp)
        let wrongDeliveryRoute = DriverRoute(driverId: "driver-1", stops: [
            RouteStop(deliveryId: "another-job", kind: .pickup, address: "Elsewhere", coordinate: .pachino, arrivalAt: 0, departureAt: 60)
        ], travelSeconds: 0, finishAt: 60, feasible: true, warnings: [])
        XCTAssertNil(DeliveryAction.nextStatus(delivery: delivery, route: wrongDeliveryRoute, now: delivery.readyAt + 60))
        XCTAssertNil(DeliveryAction.nextStatus(delivery: delivery, route: nil, now: delivery.readyAt + 60))
    }
    func testOnlyPickedUpJobCanDropOffAndWrongDriverCannotAct() throws {
        let data = String(decoding: Fixtures.delivery, as: UTF8.self).replacingOccurrences(of: "\"assigned\"", with: "\"picked_up\"").data(using: .utf8)!
        let delivery = try APIClient.decoder().decode(Delivery.self, from: data)
        let stop = RouteStop(deliveryId: "delivery-1", kind: .dropoff, address: "Destination", coordinate: .pachino, arrivalAt: 0, departureAt: 60)
        let route = DriverRoute(driverId: "driver-1", stops: [stop], travelSeconds: 0, finishAt: 60, feasible: true, warnings: [])
        XCTAssertEqual(DeliveryAction.nextStatus(delivery: delivery, route: route, now: delivery.readyAt), .delivered)
        let wrongDriver = DriverRoute(driverId: "driver-2", stops: [stop], travelSeconds: 0, finishAt: 60, feasible: true, warnings: [])
        XCTAssertNil(DeliveryAction.nextStatus(delivery: delivery, route: wrongDriver, now: delivery.readyAt))
        let assigned = try APIClient.decoder().decode(Delivery.self, from: Fixtures.delivery)
        XCTAssertNil(DeliveryAction.nextStatus(delivery: assigned, route: route, now: assigned.readyAt))
    }
    func testInfeasibleRouteRetainsExecutableStop() throws {
        let delivery = try APIClient.decoder().decode(Delivery.self, from: Fixtures.delivery)
        let original = try APIClient.decoder().decode(DriverRoute.self, from: Fixtures.route)
        let lateRoute = DriverRoute(driverId: original.driverId, stops: original.stops, travelSeconds: 0, finishAt: 0, feasible: false, warnings: ["Deadline passed"])
        XCTAssertEqual(DeliveryAction.nextStatus(delivery: delivery, route: lateRoute, now: delivery.readyAt), .pickedUp)
    }
    func testCoordinateValidation() {
        XCTAssertTrue(Coordinate.pachino.isValid)
        XCTAssertFalse(Coordinate(lat: .nan, lng: 0).isValid)
        XCTAssertFalse(Coordinate(lat: 0, lng: .infinity).isValid)
        XCTAssertFalse(Coordinate(lat: 91, lng: 0).isValid)
        XCTAssertFalse(Coordinate(lat: 0, lng: -181).isValid)
    }
    func testNewDeliveryValidationAndSnakeCaseEncoding() throws {
        let draft = Fixtures.newDelivery
        XCTAssertNil(draft.validationError)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(draft)) as? [String: Any])
        XCTAssertEqual(body["shop_name"] as? String, "Pizzeria")
        XCTAssertEqual(body["max_ride_seconds"] as? Int, 1800)
        XCTAssertEqual(body["ready_at"] as? Int, 1_790_874_000)
        XCTAssertNil(body["shopName"])
        let invalid = NewDelivery(shopName: " ", pickupAddress: "A", pickup: .pachino, dropoffAddress: "B", dropoff: .pachino, readyAt: 2, deadlineAt: 1, loadUnits: 0, maxRideSeconds: 0)
        XCTAssertNotNil(invalid.validationError)
    }
    func testPilotRequiresHTTPSRootOriginAndNormalizesIt() throws {
        XCTAssertEqual(try APIConfiguration.validatedURL("https://API.example.com:443/").absoluteString, "https://api.example.com")
        XCTAssertEqual(try APIConfiguration.validatedURL("https://api.example.com:8443").port, 8443)
        for url in ["", "http://api.example.com", "https://localhost", "https://127.0.0.1", "https://[::1]", "https://user:pass@api.example.com", "https://api.example.com/v1", "https://api.example.com?token=x", "https://api.example.com#x", "file:///tmp/api", " https://api.example.com", "https://api.example.com:0", "https://api.example.com:65536"] {
            XCTAssertThrowsError(try APIConfiguration.validatedURL(url), url)
        }
    }
    func testExplicitDebugDemoAcceptsOnlyLoopback() throws {
        for url in ["http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"] {
            XCTAssertNoThrow(try APIConfiguration.validatedURL(url, mode: .demo), url)
        }
        for url in ["http://example.com", "https://example.com", "http://localhost.evil.test", "http://user:pass@localhost", "file:///tmp/api", "http://localhost:8080?token=x"] {
            XCTAssertThrowsError(try APIConfiguration.validatedURL(url, mode: .demo), url)
        }
    }
}

enum Fixtures {
    static let delivery = Data(#"{"id":"delivery-1","shop_name":"Pizzeria","pickup_address":"Via Roma 1","pickup":{"lat":36.7163,"lng":15.0908},"dropoff_address":"Via Garibaldi 8","dropoff":{"lat":36.7210,"lng":15.1000},"ready_at":1790874000,"deadline_at":1790877600,"load_units":1,"max_ride_seconds":1800,"status":"assigned","driver_id":"driver-1","created_at":1790873900,"picked_up_at":null,"delivered_at":null}"#.utf8)
    static let route = Data(#"{"driver_id":"driver-1","stops":[{"delivery_id":"delivery-1","kind":"pickup","address":"Via Roma 1","coordinate":{"lat":36.7163,"lng":15.0908},"arrival_at":1790874000,"departure_at":1790874060}],"travel_seconds":180,"finish_at":1790874240,"feasible":true,"warnings":[]}"#.utf8)
    static let newDelivery = NewDelivery(shopName: "Pizzeria", pickupAddress: "Via Roma 1", pickup: .pachino, dropoffAddress: "Via Garibaldi 8", dropoff: Coordinate(lat: 36.721, lng: 15.1), readyAt: 1_790_874_000, deadlineAt: 1_790_877_600, loadUnits: 1, maxRideSeconds: 1800)
}

