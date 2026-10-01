import XCTest
@testable import Arrivau

final class ModelTests: XCTestCase {
    func testDecodesSnakeCaseEpochContract() throws {
        let delivery = try APIClient.decoder().decode(Delivery.self, from: Fixtures.delivery)
        XCTAssertEqual(delivery.shopName, "Pizzeria")
        XCTAssertEqual(delivery.driverId, "driver-1")
        XCTAssertEqual(delivery.readyAt, 1_790_874_000)
        XCTAssertEqual(delivery.status, .assigned)
        XCTAssertNil(delivery.pickedUpAt)
        XCTAssertEqual(delivery.pickup, .pachino)
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
    func testConfigRejectsRemoteHostsAndEmbeddedCredentials() throws {
        XCTAssertEqual(try APIConfiguration.validatedURL("http://localhost:8080").host, "localhost")
        for url in ["http://example.com", "http://localhost.evil.test", "http://user:pass@localhost", "file:///tmp/api", "http://localhost:8080?token=x"] {
            XCTAssertThrowsError(try APIConfiguration.validatedURL(url), url)
        }
    }
}

enum Fixtures {
    static let delivery = Data(#"{"id":"delivery-1","shop_name":"Pizzeria","pickup_address":"Via Roma 1","pickup":{"lat":36.7163,"lng":15.0908},"dropoff_address":"Via Garibaldi 8","dropoff":{"lat":36.7210,"lng":15.1000},"ready_at":1790874000,"deadline_at":1790877600,"load_units":1,"max_ride_seconds":1800,"status":"assigned","driver_id":"driver-1","created_at":1790873900,"picked_up_at":null,"delivered_at":null}"#.utf8)
    static let route = Data(#"{"driver_id":"driver-1","stops":[{"delivery_id":"delivery-1","kind":"pickup","address":"Via Roma 1","coordinate":{"lat":36.7163,"lng":15.0908},"arrival_at":1790874000,"departure_at":1790874060}],"travel_seconds":180,"finish_at":1790874240,"feasible":true,"warnings":[]}"#.utf8)
    static let newDelivery = NewDelivery(shopName: "Pizzeria", pickupAddress: "Via Roma 1", pickup: .pachino, dropoffAddress: "Via Garibaldi 8", dropoff: Coordinate(lat: 36.721, lng: 15.1), readyAt: 1_790_874_000, deadlineAt: 1_790_877_600, loadUnits: 1, maxRideSeconds: 1800)
}
