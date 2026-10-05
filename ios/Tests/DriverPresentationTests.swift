import XCTest
@testable import Arrivau

final class DriverPresentationTests: XCTestCase {
    private func delivery(name: String = "Pizzeria", readiness: ReadinessState = .ready, onboard: Int? = nil) -> Delivery {
        Delivery(id: "delivery-1", shopName: name, pickupAddress: "Via Roma 1, Pachino", pickup: .pachino,
                 dropoffAddress: "Via Garibaldi 8", dropoff: .pachino, readyAt: 1_790_873_000, deadlineAt: 1_790_876_000,
                 loadUnits: 1, maxRideSeconds: 1800, status: .assigned, driverId: "driver-1", createdAt: 1,
                 pickedUpAt: nil, deliveredAt: nil, readinessState: readiness, onboardDeadlineAt: onboard)
    }
    private func stop(kind: StopKind = .pickup) -> RouteStop {
        RouteStop(deliveryId: "delivery-1", kind: kind, address: "Via Roma 1, Pachino", coordinate: .pachino,
                  arrivalAt: 1_790_874_000, departureAt: 1_790_874_060)
    }
    private func route(warnings: [String] = [], notices: [String] = [], estimates: Bool = true,
                       travel: RouteTravelEstimate? = nil, feasible: Bool = true) -> DriverRoute {
        DriverRoute(driverId: "driver-1", stops: [stop()], travelSeconds: 120, finishAt: 1_790_874_060,
                    feasible: feasible, warnings: warnings, notices: notices, estimatesAvailable: estimates, travelEstimate: travel)
    }

    func testAddressNamesDoNotRepeatButBusinessNamesArePreserved() {
        XCTAssertEqual(DriverPresentation.nextStopTitle(stop(), delivery: delivery(name: "Via Roma 1")), "Ritiro")
        XCTAssertEqual(DriverPresentation.nextStopTitle(stop(), delivery: delivery(name: "via roma 1, pachino")), "Ritiro")
        XCTAssertEqual(DriverPresentation.nextStopTitle(stop(), delivery: delivery()), "Ritiro · Pizzeria")
        XCTAssertEqual(DriverPresentation.nextStopTitle(stop(), delivery: delivery(name: "Via Roma 10")), "Ritiro · Via Roma 10")
    }

    func testReadinessAlwaysDistinguishesEstimateFromConfirmed() {
        XCTAssertTrue(DriverPresentation.readiness(delivery(readiness: .estimated)).contains("stima"))
        XCTAssertTrue(DriverPresentation.readiness(delivery(readiness: .ready)).hasPrefix("Pronta dalle "))
        XCTAssertFalse(DriverPresentation.readiness(delivery(readiness: .ready)).contains("stima"))
        XCTAssertEqual(DriverPresentation.readiness(delivery(readiness: .unknown)), "Disponibilità da confermare")
    }

    func testUnavailableEstimatesHideArrivalButRetainKnownTarget() {
        let item = delivery()
        let unavailable = route(estimates: false)
        let timing = DriverPresentation.timing(stop(), delivery: item, route: unavailable)
        XCTAssertEqual(timing, "ritiro entro \(item.pickupTargetAt!.epochDate.italianTime)")
        XCTAssertFalse(timing?.contains("Arrivo") == true)
        XCTAssertNil(DriverPresentation.travelSummary(unavailable))
        XCTAssertEqual(DriverPresentation.alerts(unavailable), [unavailable.unavailableEstimateMessage])
        XCTAssertNil(DriverPresentation.timing(stop(), delivery: delivery(readiness: .unknown), route: unavailable))
    }

    func testDropoffUsesTheEarlierOfDeliveryAndOnboardLimits() {
        let early = delivery(onboard: 1_790_875_000)
        let late = delivery(onboard: 1_790_877_000)
        XCTAssertEqual(DriverPresentation.timing(stop(kind: .dropoff), delivery: early, route: route(estimates: false)),
                       "consegna entro \(early.onboardDeadlineAt!.epochDate.italianTime)")
        XCTAssertEqual(DriverPresentation.timing(stop(kind: .dropoff), delivery: late, route: route(estimates: false)),
                       "consegna entro \(late.deadlineAt.epochDate.italianTime)")
    }

    func testStaleApproximateAndLateConditionsAllRemainVisibleWithoutDuplicateWarnings() {
        let value = route(warnings: [
            "Driver location is older than 5 minutes; estimates may be inaccurate",
            "Deadline missed for delivery-1", "Deadline missed for delivery-2",
            "Maximum ride time exceeded for delivery-1", "Onboard delivery delay exceeded for delivery-1"
        ], notices: ["Pickup target missed for delivery-1", "Pickup target missed for delivery-2"], feasible: false)
        XCTAssertEqual(DriverPresentation.alerts(value), [
            "GPS oltre 5 minuti: stime imprecise", "Consegna in ritardo: avvisa la centrale",
            "Tempo di trasporto superato: avvisa la centrale", "Ritiro oltre obiettivo: avvisa la centrale"
        ])
        XCTAssertEqual(DriverPresentation.travelSummary(value), "Stime in linea d’aria · senza traffico")
    }

    func testFallbackAndRoadEstimatesKeepTheirDifferentMeaning() {
        let fallback = RouteTravelEstimate(mode: "approximate_fallback", approximate: true, notice: "Specific fallback", mapDate: nil, attribution: nil)
        let roads = RouteTravelEstimate(mode: "embedded_osrm", approximate: false, notice: "Road notice", mapDate: "2026-10-01", attribution: "OSM")
        XCTAssertEqual(DriverPresentation.travelSummary(route(travel: fallback)), "Strade non disponibili: stime in linea d’aria, senza traffico")
        XCTAssertEqual(DriverPresentation.travelSummary(route(travel: roads)), "Tempi stradali stimati · senza traffico")
    }

    func testUnknownAndStructuralProblemsStillHaveAnActionAndDoNotEchoServerText() {
        let value = route(warnings: ["New raw English warning", "Capacity exceeded at pickup delivery-1",
                                    "Duplicate stop for delivery-1", "Onboard load exceeds capacity"], feasible: false)
        XCTAssertEqual(DriverPresentation.alerts(value), ["Percorso da verificare con la centrale", "Carico da verificare con la centrale"])
        XCTAssertEqual(DriverPresentation.alerts(route(feasible: false)), ["Percorso da verificare con la centrale"])
    }

    func testMissingGPSIsNotDuplicatedAndMissingDestinationRetainsRepairAction() {
        let missing = route(warnings: ["Driver location is unavailable"], estimates: false)
        XCTAssertEqual(DriverPresentation.alerts(missing), [missing.unavailableEstimateMessage])
        let address = route(warnings: ["Destination location unavailable for delivery-1"], estimates: false)
        XCTAssertTrue(DriverPresentation.alerts(address).contains("Indirizzo da aggiornare: contatta la centrale"))
        XCTAssertNil(DriverPresentation.travelSummary(address))
    }

    func testNewShiftDisclosureNamesRecipientBackgroundAndStop() {
        XCTAssertTrue(DriverPresentation.shiftConsent.contains("centrale"))
        XCTAssertTrue(DriverPresentation.shiftConsent.contains("schermo bloccato"))
        XCTAssertTrue(DriverPresentation.shiftConsent.contains("fermarla"))
    }
}
