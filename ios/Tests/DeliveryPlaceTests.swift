import XCTest
@testable import Arrivau

final class DeliveryPlaceTests: XCTestCase {
    func testSelectionRetainsOriginalUserInputAndProviderIDOnly() {
        let selected = DeliveryPlace(userInput: "  Via Garibaldi 8, Pachino  ", googlePlaceId: "google-place-123")
        XCTAssertEqual(selected.name, "Via Garibaldi 8, Pachino")
        XCTAssertEqual(selected.address, "Via Garibaldi 8, Pachino")
        XCTAssertEqual(selected.id, "google-place-123")
        XCTAssertEqual(Set(Mirror(reflecting: selected).children.compactMap(\.label)), ["name", "address", "googlePlaceId"])
    }

    func testSameUserLabelDoesNotMergeDistinctProviderPlaces() {
        let first = DeliveryPlace(userInput: "Via Roma", googlePlaceId: "place-one")
        let second = DeliveryPlace(userInput: "Via Roma", googlePlaceId: "place-two")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testLegacyRestaurantRequiresFreshSelectionDespiteHavingCoordinates() {
        let legacy = Restaurant(id: "old", name: "Name from previous provider", address: "Previous address",
                                coordinate: .pachino, createdAt: 1)
        XCTAssertFalse(legacy.hasGooglePlace)
        XCTAssertNil(DeliveryPlace(restaurant: legacy))
        var blankID = legacy
        blankID.googlePlaceId = "   "
        XCTAssertFalse(blankID.hasGooglePlace)
        XCTAssertNil(DeliveryPlace(restaurant: blankID))
    }

    func testSavedGoogleRestaurantRemainsSelectableWithoutExpiredCoordinates() throws {
        let restaurant = try APIClient.decoder().decode(Restaurant.self, from: Data(#"{"id":"r","name":"My own restaurant name","address":"My original input","coordinate":null,"created_at":1,"google_place_id":"place-r","coordinate_fetched_at":null}"#.utf8))
        XCTAssertNil(restaurant.coordinate)
        XCTAssertNil(restaurant.coordinateFetchedAt)
        XCTAssertTrue(restaurant.hasGooglePlace)
        let selected = try XCTUnwrap(DeliveryPlace(restaurant: restaurant))
        XCTAssertEqual(selected.name, restaurant.name)
        XCTAssertEqual(selected.address, restaurant.address)
        XCTAssertEqual(selected.googlePlaceId, "place-r")
    }

    func testGoogleCreationPayloadNeverPersistsProviderCoordinates() throws {
        let draft = NewDelivery(shopName: "My shop", pickupAddress: "My pickup", pickup: .pachino,
                                dropoffAddress: "My destination", dropoff: .pachino, readyAt: nil,
                                deadlineAt: 2000, loadUnits: 1, maxRideSeconds: 1800,
                                restaurantId: "r", pickupGooglePlaceId: "google-pickup", dropoffGooglePlaceId: "google-dropoff")
        XCTAssertNil(draft.pickup)
        XCTAssertNil(draft.dropoff)
        XCTAssertNil(draft.validationError)
        let data = try APIClient.encoder().encode(draft)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["pickup_google_place_id"] as? String, "google-pickup")
        XCTAssertEqual(body["dropoff_google_place_id"] as? String, "google-dropoff")
        XCTAssertEqual(body["pickup_address"] as? String, "My pickup")
        XCTAssertEqual(body["dropoff_address"] as? String, "My destination")
        XCTAssertNil(body["pickup"])
        XCTAssertNil(body["dropoff"])
        XCTAssertEqual(try APIClient.decoder().decode(NewDelivery.self, from: data), draft)

        let restaurant = NewRestaurant(name: "My name", address: "My address", coordinate: .pachino, googlePlaceId: "google-r")
        XCTAssertNil(restaurant.coordinate)
        XCTAssertNil(restaurant.validationError)
        let restaurantBody = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(restaurant)) as? [String: Any])
        XCTAssertEqual(restaurantBody["google_place_id"] as? String, "google-r")
        XCTAssertNil(restaurantBody["coordinate"])
        XCTAssertEqual(try APIClient.decoder().decode(NewRestaurant.self, from: APIClient.encoder().encode(restaurant)), restaurant)
    }

    func testLegacyPendingPayloadRoundTripPreservesReplayBodyWithoutInventedProvenance() throws {
        let data = try APIClient.encoder().encode(Fixtures.newDelivery)
        let decoded = try APIClient.decoder().decode(NewDelivery.self, from: data)
        XCTAssertEqual(decoded, Fixtures.newDelivery)
        XCTAssertEqual(decoded.pickup, .pachino)
        XCTAssertNil(decoded.pickupGooglePlaceId)
        XCTAssertNil(decoded.dropoffGooglePlaceId)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.encoder().encode(decoded)) as? [String: Any])
        XCTAssertNotNil(body["pickup"])
        XCTAssertNil(body["pickup_google_place_id"])
        XCTAssertNil(body["dropoff_google_place_id"])
    }

    func testDeliveryDecodesSourceAndPurgedCoordinateCacheWithoutLosingJob() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.delivery) as? [String: Any])
        json["pickup_google_place_id"] = "google-pickup"
        json["dropoff_google_place_id"] = "google-dropoff"
        json["pickup_coordinate_fetched_at"] = 1_790_000_000
        json["dropoff_coordinate_fetched_at"] = NSNull()
        json["dropoff"] = NSNull()
        let delivery = try APIClient.decoder().decode(Delivery.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(delivery.pickupGooglePlaceId, "google-pickup")
        XCTAssertEqual(delivery.dropoffGooglePlaceId, "google-dropoff")
        XCTAssertEqual(delivery.pickupCoordinateFetchedAt, 1_790_000_000)
        XCTAssertNil(delivery.dropoffCoordinateFetchedAt)
        XCTAssertNil(delivery.dropoff)
        XCTAssertEqual(delivery.id, "delivery-1")
        XCTAssertEqual(try APIClient.decoder().decode(Delivery.self, from: APIClient.encoder().encode(delivery)), delivery)
    }

    func testBlankProviderIDDoesNotValidateAsSelection() {
        XCTAssertNotNil(NewRestaurant(name: "My name", address: "My input", googlePlaceId: " ").validationError)
        let draft = NewDelivery(shopName: "My name", pickupAddress: "My pickup", dropoffAddress: "My dropoff", readyAt: nil,
                                deadlineAt: 2000, loadUnits: 1, maxRideSeconds: 1800,
                                pickupGooglePlaceId: " ", dropoffGooglePlaceId: "dropoff")
        XCTAssertNotNil(draft.validationError)
    }
}
