import XCTest
@testable import Arrivau

final class DispatcherDriverPresentationTests: XCTestCase {
    private func delivery(_ id: String, driverId: String? = "driver-1", status: DeliveryStatus = .assigned,
                          deadline: Int = 100, created: Int = 10, delivered: Int? = nil) -> Delivery {
        Delivery(id: id, shopName: "Pizzeria", pickupAddress: "Ritiro", pickup: .pachino,
                 dropoffAddress: "Destinazione", dropoff: .pachino, readyAt: 1, deadlineAt: deadline,
                 loadUnits: 1, maxRideSeconds: 1800, status: status, driverId: driverId,
                 createdAt: created, pickedUpAt: nil, deliveredAt: delivered)
    }

    func testActiveHistoryExcludesOtherDriversUnassignedAndCompleted() {
        let input = [delivery("later", deadline: 200), delivery("early", status: .pickedUp),
                     delivery("other", driverId: "driver-2"), delivery("unassigned", driverId: nil, status: .pending),
                     delivery("finished", status: .delivered, delivered: 90)]
        XCTAssertEqual(DispatcherDriverPresentation.activeDeliveries(input, driverId: "driver-1").map(\.id), ["early", "later"])
        XCTAssertEqual(DispatcherDriverPresentation.completedDeliveries(input, driverId: "driver-1").map(\.id), ["finished"])
        XCTAssertTrue(DispatcherDriverPresentation.activeDeliveries(input, driverId: "absent").isEmpty)
    }

    func testCompletedHistoryUsesCompletionDateNotCreationAndStableFallback() {
        let input = [delivery("old", status: .delivered, created: 500, delivered: 20),
                     delivery("recent", status: .delivered, created: 1, delivered: 100),
                     delivery("legacy-b", status: .delivered, created: 50),
                     delivery("legacy-a", status: .delivered, created: 50)]
        XCTAssertEqual(DispatcherDriverPresentation.completedDeliveries(input, driverId: "driver-1").map(\.id),
                       ["recent", "legacy-a", "legacy-b", "old"])
    }
}
