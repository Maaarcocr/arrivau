import XCTest
@testable import Arrivau

final class APIClientTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.handler = nil
        StubURLProtocol.responseOverride = nil
        super.tearDown()
    }
    private var client: APIClient {
        APIClient(baseURL: URL(string: "http://localhost:8080")!, token: "demo-driver-1", session: session)
    }
    func testReadsOwnShiftWithBearerToken() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/shift")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-driver-1")
            return (200, Data(#"{"id":"driver-1","name":"Driver 1","active":true,"capacity":2,"location":null,"location_updated_at":null}"#.utf8))
        }
        let driver = try await client.shift()
        XCTAssertTrue(driver.active)
        XCTAssertEqual(driver.capacity, 2)
        XCTAssertNil(driver.location)
    }
    func testCreatePostsExpectedPayloadAndDecodes201() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/deliveries")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let payload = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
            XCTAssertEqual(payload?["load_units"] as? Int, 1)
            XCTAssertEqual(payload?["shop_name"] as? String, "Pizzeria")
            return (201, Fixtures.delivery)
        }
        let result = try await client.create(Fixtures.newDelivery)
        XCTAssertEqual(result.id, "delivery-1")
    }
    func testRestaurantAPIUsesCanonicalPlaceAndRetryKey() async throws {
        let restaurant = Restaurant(id: "restaurant-1", name: "Pizzeria", address: "Via Roma 1", coordinate: .pachino, createdAt: 1000)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/restaurants")
            if request.httpMethod == "GET" { return (200, try APIClient.encoder().encode([restaurant])) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "restaurant-retry")
            let payload = try APIClient.decoder().decode(NewRestaurant.self, from: Self.body(of: request))
            XCTAssertEqual(payload, NewRestaurant(name: restaurant.name, address: restaurant.address, coordinate: restaurant.coordinate))
            return (201, try APIClient.encoder().encode(restaurant))
        }
        let saved = try await client.createRestaurant(NewRestaurant(name: restaurant.name, address: restaurant.address, coordinate: restaurant.coordinate), idempotencyKey: "restaurant-retry")
        XCTAssertEqual(saved, restaurant)
        let listed = try await client.restaurants()
        XCTAssertEqual(listed, [restaurant])
    }
    func testReadinessPostsExactRevisionAndIdempotencyKey() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/deliveries/delivery-1/readiness")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "readiness-retry-key")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Int])
            XCTAssertEqual(payload, ["ready_in_minutes": 10, "expected_revision": 7])
            return (200, Fixtures.delivery)
        }
        let result = try await client.readiness(deliveryId: "delivery-1", update: ReadinessUpdate(readyInMinutes: 10, expectedRevision: 7), idempotencyKey: "readiness-retry-key")
        XCTAssertEqual(result.id, "delivery-1")
    }
    func testServerConflictIsShownWithoutSilentRetry() async throws {
        var count = 0
        StubURLProtocol.handler = { _ in
            count += 1
            return (409, Data(#"{"error":"Pickup is not the next route stop"}"#.utf8))
        }
        do {
            _ = try await client.status(deliveryId: "delivery-1", status: .pickedUp)
            XCTFail("Expected a conflict")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Il ritiro non è la prossima tappa del percorso.")
            XCTAssertFalse(try XCTUnwrap(error as? APIError).mutationOutcomeUncertain)
        }
        XCTAssertEqual(count, 1)
    }
    func testNonJSONErrorProvidesStatus() async throws {
        StubURLProtocol.handler = { _ in (503, Data("Unavailable".utf8)) }
        do { _ = try await client.me(); XCTFail("Expected API error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
    }
    func testUnknownServerMessageUsesItalianFallbackWithoutEchoingDetails() async throws {
        StubURLProtocol.handler = { _ in (418, Data(#"{"error":"New English server message with private details"}"#.utf8)) }
        do { _ = try await client.me(); XCTFail("Expected API error") }
        catch {
            XCTAssertEqual(error.localizedDescription, "La richiesta al server non è riuscita (HTTP 418). Riprova.")
            XCTAssertFalse(try XCTUnwrap(error as? APIError).mutationOutcomeUncertain)
        }
    }
    func testUnreadableMutationResponseHasTypedUncertaintyFlag() async throws {
        StubURLProtocol.handler = { _ in (201, Data(#"{"unexpected":"English decoding detail"}"#.utf8)) }
        do { _ = try await client.create(Fixtures.newDelivery); XCTFail("Expected decoding error") }
        catch {
            let error = try XCTUnwrap(error as? APIError)
            XCTAssertTrue(error.mutationOutcomeUncertain)
            XCTAssertEqual(error.localizedDescription, "La risposta del server contiene dati non validi o non compatibili con questa app.")
        }
    }
    func testUnreadableReadResponseDoesNotMarkMutationUncertain() async throws {
        StubURLProtocol.handler = { _ in (200, Data("invalid json".utf8)) }
        do { _ = try await client.me(); XCTFail("Expected decoding error") }
        catch { XCTAssertFalse(try XCTUnwrap(error as? APIError).mutationOutcomeUncertain) }
    }
    func testInvalidMutationResponseHasTypedUncertaintyFlag() async throws {
        StubURLProtocol.handler = { _ in (201, Fixtures.delivery) }
        StubURLProtocol.responseOverride = URLResponse(url: URL(string: "http://localhost:8080")!, mimeType: "application/json", expectedContentLength: Fixtures.delivery.count, textEncodingName: nil)
        do { _ = try await client.create(Fixtures.newDelivery); XCTFail("Expected invalid response") }
        catch {
            let error = try XCTUnwrap(error as? APIError)
            XCTAssertTrue(error.mutationOutcomeUncertain)
            XCTAssertEqual(error.localizedDescription, "Il server ha restituito una risposta non valida.")
        }
    }
    func testTransportErrorRetainsTypeForCreateReconciliationAndHasItalianPresentation() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "Raw English network failure"]) }
        do { _ = try await client.create(Fixtures.newDelivery); XCTFail("Expected network error") }
        catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
            XCTAssertEqual(ItalianPresentation.errorMessage(error), "La connessione al server si è interrotta. Controlla la rete e riprova.")
            XCTAssertTrue(error is URLError || (error as? APIError)?.mutationOutcomeUncertain == true)
        }
    }
    func testFailedEncodingIsLocalizedAndCannotHaveCommitted() async throws {
        let invalid = NewDelivery(shopName: "Pizzeria", pickupAddress: "A", pickup: Coordinate(lat: .nan, lng: 0), dropoffAddress: "B", dropoff: .pachino, readyAt: 1, deadlineAt: 2, loadUnits: 1, maxRideSeconds: 60)
        StubURLProtocol.handler = { _ in XCTFail("Invalid values must not reach the API"); return (201, Fixtures.delivery) }
        do { _ = try await client.create(invalid); XCTFail("Expected encoding error") }
        catch {
            let error = try XCTUnwrap(error as? APIError)
            XCTAssertFalse(error.mutationOutcomeUncertain)
            XCTAssertEqual(error.localizedDescription, "Impossibile preparare i dati da inviare. Controlla i valori inseriti.")
        }
    }
    func testLocalizedTitlesDoNotChangeStatusPayload() async throws {
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])
            XCTAssertEqual(payload["status"] as? String, "picked_up")
            return (200, Fixtures.delivery)
        }
        _ = try await client.status(deliveryId: "delivery-1", status: .pickedUp)
    }
    func testLoginUsesCredentialsOnceWithoutBearerAndDecodesSession() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/session")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: String])
            XCTAssertEqual(payload, ["username": "mario", "password": "test-only-password"])
            return (201, Data(#"{"token":"opaque-session","expires_at":2000000000,"user":{"id":"rider-a","name":"Mario","role":"driver"}}"#.utf8))
        }
        let anonymous = APIClient(baseURL: URL(string: "https://api.example.com")!, token: "", session: session)
        let authenticated = try await anonymous.login(username: "mario", password: "test-only-password")
        XCTAssertEqual(authenticated.token, "opaque-session")
        XCTAssertEqual(authenticated.expiresAt, 2_000_000_000)
        XCTAssertEqual(authenticated.user.serverRole, .driver)
    }
    func testRevokeAcceptsEmpty204AndUsesBearer() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-driver-1")
            XCTAssertNil(request.httpBody)
            return (204, Data())
        }
        try await client.revokeSession()
    }
    func testUnauthorizedIsTypedAndCannotEchoServerDetails() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":"private account details"}"#.utf8)) }
        do { _ = try await client.identity(); XCTFail("Expected unauthorized") }
        catch {
            XCTAssertTrue((error as? APIError)?.isUnauthorized == true)
            XCTAssertEqual(error.localizedDescription, "Sessione scaduta o revocata. Accedi di nuovo.")
        }
    }
    func testIdempotencyKeyIsReusedExactlyAsSupplied() async throws {
        let key = UUID().uuidString
        var requests = 0
        StubURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key)
            return (201, Fixtures.delivery)
        }
        _ = try await client.create(Fixtures.newDelivery, idempotencyKey: key)
        _ = try await client.create(Fixtures.newDelivery, idempotencyKey: key)
        XCTAssertEqual(requests, 2)
    }
    func testServerFailureLeavesMutationOutcomeUncertain() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do { _ = try await client.create(Fixtures.newDelivery); XCTFail("Expected unavailable") }
        catch { XCTAssertTrue((error as? APIError)?.mutationOutcomeUncertain == true) }
    }
    func testRedirectPolicyRejectsEvenSameOriginRedirects() {
        let original = URL(string: "https://api.example.com/v1/session")!
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: ["Location": "https://other.example.com/session"])!
        let task = session.dataTask(with: original)
        var called = false
        NoAPIRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                         newRequest: URLRequest(url: URL(string: "https://other.example.com/session")!)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
        task.cancel()
    }
    private static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw stream.streamError ?? APIError(message: "Could not read request") }
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseOverride: URLResponse?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw APIError(message: "Missing test handler") }
            let (status, body) = try handler(request)
            let response = Self.responseOverride ?? HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}


