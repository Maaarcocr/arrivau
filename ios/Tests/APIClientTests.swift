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
            XCTAssertEqual(error.localizedDescription, "Pickup is not the next route stop")
        }
        XCTAssertEqual(count, 1)
    }
    func testNonJSONErrorProvidesStatus() async throws {
        StubURLProtocol.handler = { _ in (503, Data("Unavailable".utf8)) }
        do { _ = try await client.me(); XCTFail("Expected API error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw APIError(message: "Missing test handler") }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
