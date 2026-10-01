import Foundation

struct APIError: Error, LocalizedError {
    let message: String
    /// A mutation may have committed even though its response could not be read.
    /// Keep this independent of the user-facing wording and locale.
    let mutationOutcomeUncertain: Bool

    init(message: String, mutationOutcomeUncertain: Bool = false) {
        self.message = message
        self.mutationOutcomeUncertain = mutationOutcomeUncertain
    }

    var errorDescription: String? { message }
}

enum APIConfiguration {
    static let defaultURL = "http://localhost:8080"
    static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              url.scheme == "http" || url.scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw APIError(message: "Questa demo accetta solo un indirizzo API locale (loopback), ad esempio http://localhost:8080. Usa il simulatore iOS sul Mac che esegue il server API.")
        }
        #if !DEBUG
        guard url.scheme == "https" else { throw APIError(message: "Le connessioni HTTP non protette sono disponibili solo nelle build di debug.") }
        #endif
        return url
    }
}

struct APIClient {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
    private struct ErrorBody: Decodable { let error: String }
    private struct ShiftBody: Encodable { let active: Bool; let capacity: Int }
    private struct AssignmentBody: Encodable { let driverId: String }
    private struct StatusBody: Encodable { let status: DeliveryStatus }

    func me() async throws -> Principal { try await get("v1/me") }
    func drivers() async throws -> [Driver] { try await get("v1/drivers") }
    func deliveries() async throws -> [Delivery] { try await get("v1/deliveries") }
    func shift() async throws -> Driver { try await get("v1/shift") }
    func route() async throws -> DriverRoute { try await get("v1/route") }
    func route(driverId: String) async throws -> DriverRoute { try await get("v1/drivers/\(driverId)/route") }
    func suggestions(deliveryId: String) async throws -> [Suggestion] { try await get("v1/deliveries/\(deliveryId)/suggestions") }
    func create(_ delivery: NewDelivery) async throws -> Delivery { try await post("v1/deliveries", body: delivery) }
    func shift(active: Bool, capacity: Int) async throws -> Driver { try await post("v1/shift", body: ShiftBody(active: active, capacity: capacity)) }
    func location(_ coordinate: Coordinate) async throws -> Driver { try await post("v1/location", body: coordinate) }
    func assign(deliveryId: String, driverId: String) async throws -> Delivery {
        try await post("v1/deliveries/\(deliveryId)/assign", body: AssignmentBody(driverId: driverId))
    }
    func status(deliveryId: String, status: DeliveryStatus) async throws -> Delivery {
        try await post("v1/deliveries/\(deliveryId)/status", body: StatusBody(status: status))
    }

    private func get<T: Decodable>(_ path: String) async throws -> T { try await request(path, method: "GET", body: nil) }
    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let data: Data
        do { data = try Self.encoder().encode(body) }
        catch { throw APIError(message: "Impossibile preparare i dati da inviare. Controlla i valori inseriti.") }
        return try await request(path, method: "POST", body: data)
    }
    private func request<T: Decodable>(_ path: String, method: String, body: Data?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        // Preserve URLError and cancellation types for reconciliation/cancellation guards.
        // Present these through ItalianPresentation.errorMessage rather than system text.
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw APIError(message: ItalianPresentation.unknownError, mutationOutcomeUncertain: method != "GET")
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Il server ha restituito una risposta non valida.", mutationOutcomeUncertain: method != "GET")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? Self.decoder().decode(ErrorBody.self, from: data))?.error
            throw APIError(message: ItalianPresentation.serverError(detail, statusCode: http.statusCode))
        }
        do { return try Self.decoder().decode(T.self, from: data) }
        catch {
            throw APIError(message: "La risposta del server contiene dati non validi o non compatibili con questa demo.",
                           mutationOutcomeUncertain: method != "GET")
        }
    }
}

