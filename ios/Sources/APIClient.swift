import Foundation

struct APIError: Error, LocalizedError {
    let message: String
    let mutationOutcomeUncertain: Bool
    let statusCode: Int?
    var isUnauthorized: Bool { statusCode == 401 }
    init(message: String, mutationOutcomeUncertain: Bool = false, statusCode: Int? = nil) {
        self.message = message
        self.mutationOutcomeUncertain = mutationOutcomeUncertain
        self.statusCode = statusCode
    }
    var errorDescription: String? { message }
}

enum ConnectionMode: Equatable {
    case pilot
    #if DEBUG
    case demo
    #endif
}

enum APIConfiguration {
    static let defaultURL = ""
    static func validatedURL(_ value: String, mode: ConnectionMode = .pilot) throws -> URL {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let parts = URLComponents(string: value), let url = parts.url,
              let host = parts.host?.lowercased(), !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let scheme = parts.scheme?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              !value.contains("\\") else { throw invalidURL }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        #if DEBUG
        if mode == .demo {
            guard loopback, scheme == "http" || scheme == "https" else {
                throw APIError(message: "La demo accetta solo un indirizzo API locale (loopback), ad esempio http://localhost:8080.")
            }
            return url
        }
        #endif
        guard scheme == "https", !loopback, !host.hasPrefix("127."),
              !host.hasSuffix(".localhost"), !host.hasSuffix(".localhost."),
              !["localhost.", "0.0.0.0", "::", "[::]"].contains(host),
              !host.contains("::ffff:") else { throw invalidURL }
        // A single normalized origin binds both credentials and recovery requests.
        var origin = parts
        origin.scheme = scheme
        origin.host = host
        origin.path = ""
        if origin.port == 443 { origin.port = nil }
        guard let normalized = origin.url else { throw invalidURL }
        return normalized
    }
    private static var invalidURL: APIError {
        APIError(message: "Inserisci l’indirizzo HTTPS del server fornito dal responsabile, senza percorsi, credenziali o parametri (esempio: https://api.esempio.it).")
    }
}

/// Login bodies and bearer tokens must never follow a redirect to another destination.
final class NoAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoAPIRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct APIClient {
    let baseURL: URL
    let token: String
    var session: URLSession = APIClient.secureSession
    static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
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
    private struct LoginBody: Encodable { let username: String; let password: String }
    private struct ShiftBody: Encodable { let active: Bool; let capacity: Int }
    private struct AssignmentBody: Encodable { let driverId: String }
    private struct StatusBody: Encodable { let status: DeliveryStatus }

    func login(username: String, password: String) async throws -> LoginSession {
        try await post("v1/session", body: LoginBody(username: username, password: password))
    }
    func identity() async throws -> SessionIdentity { try await get("v1/session") }
    func revokeSession() async throws { _ = try await response("v1/session", method: "DELETE", body: nil) }
    func me() async throws -> Principal { try await get("v1/me") }
    func drivers() async throws -> [Driver] { try await get("v1/drivers") }
    func deliveries() async throws -> [Delivery] { try await get("v1/deliveries") }
    func shift() async throws -> Driver { try await get("v1/shift") }
    func route() async throws -> DriverRoute { try await get("v1/route") }
    func route(driverId: String) async throws -> DriverRoute { try await get("v1/drivers/\(driverId)/route") }
    func suggestions(deliveryId: String) async throws -> [Suggestion] { try await get("v1/deliveries/\(deliveryId)/suggestions") }
    func create(_ delivery: NewDelivery, idempotencyKey: String = UUID().uuidString) async throws -> Delivery {
        try await post("v1/deliveries", body: delivery, idempotencyKey: idempotencyKey)
    }
    func shift(active: Bool, capacity: Int) async throws -> Driver { try await post("v1/shift", body: ShiftBody(active: active, capacity: capacity)) }
    func location(_ coordinate: Coordinate) async throws -> Driver { try await post("v1/location", body: coordinate) }
    func assign(deliveryId: String, driverId: String, idempotencyKey: String? = nil) async throws -> Delivery {
        try await post("v1/deliveries/\(deliveryId)/assign", body: AssignmentBody(driverId: driverId), idempotencyKey: idempotencyKey)
    }
    func status(deliveryId: String, status: DeliveryStatus, idempotencyKey: String? = nil) async throws -> Delivery {
        try await post("v1/deliveries/\(deliveryId)/status", body: StatusBody(status: status), idempotencyKey: idempotencyKey)
    }
    private func get<T: Decodable>(_ path: String) async throws -> T { try await request(path, method: "GET", body: nil) }
    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, idempotencyKey: String? = nil) async throws -> T {
        let data: Data
        do { data = try Self.encoder().encode(body) }
        catch { throw APIError(message: "Impossibile preparare i dati da inviare. Controlla i valori inseriti.") }
        return try await request(path, method: "POST", body: data, idempotencyKey: idempotencyKey)
    }
    private func request<T: Decodable>(_ path: String, method: String, body: Data?, idempotencyKey: String? = nil) async throws -> T {
        let data = try await response(path, method: method, body: body, idempotencyKey: idempotencyKey)
        do { return try Self.decoder().decode(T.self, from: data) }
        catch {
            throw APIError(message: "La risposta del server contiene dati non validi o non compatibili con questa app.",
                           mutationOutcomeUncertain: method != "GET")
        }
    }
    private func response(_ path: String, method: String, body: Data?, idempotencyKey: String? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: NoAPIRedirects.shared) }
        catch let error as URLError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw APIError(message: ItalianPresentation.unknownError, mutationOutcomeUncertain: method != "GET") }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Il server ha restituito una risposta non valida.", mutationOutcomeUncertain: method != "GET")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? Self.decoder().decode(ErrorBody.self, from: data))?.error
            throw APIError(message: ItalianPresentation.serverError(detail, statusCode: http.statusCode),
                           mutationOutcomeUncertain: method != "GET" && http.statusCode >= 500, statusCode: http.statusCode)
        }
        return data
    }
}
