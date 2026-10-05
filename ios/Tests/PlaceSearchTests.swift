import XCTest
import GooglePlaces
@testable import Arrivau

@MainActor
final class PlaceSearchTests: XCTestCase {
    private let prediction = PlacePrediction(id: "provider-id", title: "Google prediction name", subtitle: "Google formatted address")

    func testDetailsMaskIsOnlyIDAndCoordinateEssentials() {
        XCTAssertEqual(Set(GooglePlaceSearchService.detailProperties), Set([GMSPlaceProperty.placeID.rawValue, GMSPlaceProperty.coordinate.rawValue]))
    }

    func testOldResponseCannotReplaceNewQueryEvenAfterReturningToSameText() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        model.updateQuery("Roma")
        try await waitUntil { service.searches.count == 1 }
        model.updateQuery("Garibaldi")
        try await waitUntil { service.searches.count == 2 }
        model.updateQuery("Roma")
        try await waitUntil { service.searches.count == 3 }
        service.searches[0].continuation.resume(returning: [prediction])
        service.searches[1].continuation.resume(throwing: PlaceSearchError.searchFailed)
        let newest = PlacePrediction(id: "latest", title: "Newest", subtitle: "Result")
        service.searches[2].continuation.resume(returning: [newest])
        try await waitUntil { !model.searching }
        XCTAssertEqual(model.results, [newest])
        XCTAssertNil(model.error)
        model.cancel()
    }

    func testCancelSuppressesLateSearchResultsAndResetsBillingSession() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        model.updateQuery("Roma")
        try await waitUntil { service.searches.count == 1 }
        model.cancel()
        service.searches[0].continuation.resume(returning: [prediction])
        await Task.yield()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.searching)
        XCTAssertNil(model.error)
        XCTAssertEqual(service.resetCount, 1)
        model.updateQuery("Garibaldi")
        await Task.yield()
        XCTAssertEqual(service.searches.count, 1)
    }

    func testSelectionUsesOriginalInputAndDoubleTapMakesOneDetailsRequest() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let first = Task { await model.select(prediction) }
        try await waitUntil { service.selections.count == 1 }
        let duplicate = await model.select(prediction)
        XCTAssertNil(duplicate)
        XCTAssertEqual(service.selections.count, 1)
        XCTAssertEqual(service.selections[0].userInput, "  My own typed address  ")
        service.selections[0].continuation.resume(returning: DeliveryPlace(userInput: service.selections[0].userInput, googlePlaceId: prediction.id))
        let result = await first.value
        XCTAssertEqual(result?.address, "My own typed address")
        XCTAssertNotEqual(result?.address, prediction.subtitle)
        XCTAssertNotEqual(result?.name, prediction.title)
        let afterCompletion = await model.select(prediction)
        XCTAssertNil(afterCompletion)
    }

    func testCancelDuringDetailsNeverCommitsSelection() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let task = Task { await model.select(prediction) }
        try await waitUntil { service.selections.count == 1 }
        model.cancel()
        service.selections[0].continuation.resume(returning: DeliveryPlace(userInput: "ignored", googlePlaceId: prediction.id))
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.selecting)
    }

    func testNewQueryDuringDetailsSupersedesSelection() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let task = Task { await model.select(prediction) }
        try await waitUntil { service.selections.count == 1 }
        model.updateQuery("New address")
        try await waitUntil { service.searches.count == 2 }
        service.selections[0].continuation.resume(returning: DeliveryPlace(userInput: "ignored", googlePlaceId: prediction.id))
        let result = await task.value
        XCTAssertNil(result)
        let newest = PlacePrediction(id: "new", title: "New", subtitle: "Address")
        service.searches[1].continuation.resume(returning: [newest])
        try await waitUntil { !model.searching }
        XCTAssertEqual(model.results, [newest])
        model.cancel()
    }

    func testFailedDetailsRequireNewSearchAndDoNotRetainGoogleContent() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let task = Task { await model.select(prediction) }
        try await waitUntil { service.selections.count == 1 }
        service.selections[0].continuation.resume(throwing: PlaceSearchError.invalidPlace)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.error, PlaceSearchError.invalidPlace.errorDescription)
        XCTAssertEqual(service.resetCount, 1)
        model.search()
        try await waitUntil { service.searches.count == 2 }
        service.searches[1].continuation.resume(returning: [prediction])
        try await waitUntil { !model.searching }
        XCTAssertEqual(model.results, [prediction])
        XCTAssertNil(model.error)
        model.cancel()
    }

    func testIdenticalTextFieldWritebackDoesNotRemoveTappablePrediction() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        // Resigning first responder can repeat the binding setter before the tap
        // starts its asynchronous work. It must not clear the selected row.
        model.updateQuery(model.query)
        XCTAssertEqual(model.results, [prediction])
        XCTAssertFalse(model.searching)
        XCTAssertNotNil(model.beginSelection(prediction))
        await Task.yield()
        XCTAssertEqual(service.searches.count, 1)
        model.cancel()
    }

    func testClaimedTapSurvivesKeyboardWritebackAndSubmitBeforeAndDuringDetails() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let request = try XCTUnwrap(model.beginSelection(prediction))
        XCTAssertTrue(model.selecting, "The tap is claimed synchronously, before keyboard blur")
        model.updateQuery(model.query)
        model.search() // A delayed keyboard submit must not create a new generation.
        XCTAssertTrue(model.selecting)
        XCTAssertEqual(model.results, [prediction])
        let task = Task { await model.resolveSelection(request) }
        try await waitUntil { service.selections.count == 1 }
        model.updateQuery(model.query)
        model.search()
        XCTAssertTrue(model.selecting)
        XCTAssertNil(model.beginSelection(prediction))
        let duplicate = await model.resolveSelection(request)
        XCTAssertNil(duplicate)
        XCTAssertEqual(service.searches.count, 1)
        XCTAssertEqual(service.selections.count, 1)
        service.selections[0].continuation.resume(returning: DeliveryPlace(userInput: service.selections[0].userInput, googlePlaceId: prediction.id))
        let result = await task.value
        XCTAssertEqual(result?.googlePlaceId, prediction.id)
        XCTAssertEqual(result?.address, "My own typed address")
        XCTAssertFalse(model.selecting)
    }

    func testGenuineEditBeforeClaimedSelectionStartsPreventsDetailsRequest() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let request = try XCTUnwrap(model.beginSelection(prediction))
        model.updateQuery("New address")
        let stale = await model.resolveSelection(request)
        XCTAssertNil(stale)
        XCTAssertTrue(service.selections.isEmpty)
        try await waitUntil { service.searches.count == 2 }
        service.searches[1].continuation.resume(returning: [])
        try await waitUntil { !model.searching }
        model.cancel()
    }

    func testDismissBeforeClaimedSelectionStartsMakesNoDetailsRequest() async throws {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        try await showPrediction(model, service)
        let request = try XCTUnwrap(model.beginSelection(prediction))
        model.cancel()
        let result = await model.resolveSelection(request)
        XCTAssertNil(result)
        XCTAssertTrue(service.selections.isEmpty)
        XCTAssertFalse(model.selecting)
    }

    func testShortInputDoesNotStartProviderRequest() async {
        let service = ControlledPlaceSearch()
        let model = PlaceSearchModel(service: service, debounceNanoseconds: 0)
        model.updateQuery("ab")
        await Task.yield()
        XCTAssertTrue(service.searches.isEmpty)
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(service.resetCount, 1)
    }

    private func showPrediction(_ model: PlaceSearchModel, _ service: ControlledPlaceSearch) async throws {
        model.updateQuery("  My own typed address  ")
        try await waitUntil { service.searches.count == 1 }
        service.searches[0].continuation.resume(returning: [prediction])
        try await waitUntil { !model.searching }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous provider call did not finish", file: file, line: line)
        throw PlaceSearchError.searchFailed
    }
}

@MainActor
private final class ControlledPlaceSearch: PlaceSearching {
    struct Search {
        let query: String
        let continuation: CheckedContinuation<[PlacePrediction], Error>
    }
    struct Selection {
        let userInput: String
        let continuation: CheckedContinuation<DeliveryPlace, Error>
    }
    var searches: [Search] = []
    var selections: [Selection] = []
    var resetCount = 0
    func predictions(for query: String) async throws -> [PlacePrediction] {
        try await withCheckedThrowingContinuation { searches.append(Search(query: query, continuation: $0)) }
    }
    func resolve(_ prediction: PlacePrediction, userInput: String) async throws -> DeliveryPlace {
        try await withCheckedThrowingContinuation { selections.append(Selection(userInput: userInput, continuation: $0)) }
    }
    func resetSession() { resetCount += 1 }
}
