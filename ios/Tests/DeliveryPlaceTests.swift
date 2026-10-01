import XCTest
import MapKit
@testable import Arrivau

final class DeliveryPlaceTests: XCTestCase {
    func testMapSelectionKeepsAddressAndCoordinatesTogether() {
        let coordinate = CLLocationCoordinate2D(latitude: 36.721, longitude: 15.1)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate, addressDictionary: [
            "Street": "Via Garibaldi 8", "City": "Pachino"
        ]))
        item.name = "Via Garibaldi 8"
        let selected = DeliveryPlace(item: item)
        XCTAssertEqual(selected.name, "Via Garibaldi 8")
        XCTAssertFalse(selected.address.isEmpty)
        XCTAssertEqual(selected.coordinate, Coordinate(lat: 36.721, lng: 15.1))
        XCTAssertTrue(selected.coordinate.isValid)
    }

    func testDifferentRoutingPointsRemainDistinctEvenWithSameLabel() {
        let first = DeliveryPlace(name: "Pickup", address: "Via Roma", coordinate: .pachino)
        let second = DeliveryPlace(name: "Pickup", address: "Via Roma", coordinate: Coordinate(lat: 36.717, lng: 15.091))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.id, second.id)
    }
}
