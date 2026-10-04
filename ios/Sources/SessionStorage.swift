import Foundation
import Security

struct LoginSession: Decodable {
    let token: String
    let expiresAt: Int
    let user: Principal
}
struct SessionIdentity: Decodable {
    let expiresAt: Int?
    let user: Principal
}
struct SavedSession: Codable, Equatable {
    let endpoint: String
    let token: String
    let expiresAt: Int
}
struct PendingCreation: Codable, Equatable {
    let idempotencyKey: String
    let delivery: NewDelivery
}

enum CreationScope {
    static func legacy(endpoint: String, accountId: String) -> String { "\(endpoint)|\(accountId)" }
    static func current(endpoint: String, user: Principal) -> String {
        guard let teamId = user.teamId else { return legacy(endpoint: endpoint, accountId: user.id) }
        // Length-prefix each UTF-8 component so identifiers containing separators cannot collide.
        return "v2:" + [endpoint, teamId, user.id].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// No password is persisted. Recovery is bound to endpoint + team + authenticated account.
/// Legacy unscoped records are never silently replayed into a newly declared team.
protocol SessionStorage {
    func loadSession() throws -> SavedSession?
    func saveSession(_ value: SavedSession) throws
    func clearSession() throws
    func loadCreation(scope: String) throws -> PendingCreation?
    func saveCreation(_ value: PendingCreation, scope: String) throws
    func clearCreation(scope: String) throws
    func loadRestaurant(scope: String) throws -> PendingRestaurant?
    func saveRestaurant(_ value: PendingRestaurant, scope: String) throws
    func clearRestaurant(scope: String) throws
}

struct KeychainSessionStorage: SessionStorage {
    private let service = "dev.arrivau.pilot.session.v1"
    func loadSession() throws -> SavedSession? { try read("session") }
    func saveSession(_ value: SavedSession) throws { try write(value, account: "session") }
    func clearSession() throws { try remove("session") }
    func loadCreation(scope: String) throws -> PendingCreation? { try read("creation:\(scope)") }
    func saveCreation(_ value: PendingCreation, scope: String) throws { try write(value, account: "creation:\(scope)") }
    func clearCreation(scope: String) throws { try remove("creation:\(scope)") }

    func loadRestaurant(scope: String) throws -> PendingRestaurant? { try read("restaurant:\(scope)") }
    func saveRestaurant(_ value: PendingRestaurant, scope: String) throws { try write(value, account: "restaurant:\(scope)") }
    func clearRestaurant(scope: String) throws { try remove("restaurant:\(scope)") }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func read<T: Decodable>(_ account: String) throws -> T? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw storageError }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw storageError }
    }
    private func write<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        // Background location can continue only after the user has unlocked this device once.
        // No iCloud synchronization or migration to a different device.
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw storageError }
        } else if status != errSecSuccess { throw storageError }
    }
    private func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError }
    }
    private var storageError: APIError {
        APIError(message: "Impossibile accedere ai dati protetti del dispositivo. Sblocca l’iPhone e riprova.")
    }
}

#if DEBUG
/// Test/demo sessions never read or overwrite the signed-in pilot user's Keychain.
final class MemorySessionStorage: SessionStorage {
    var savedSession: SavedSession?
    var creations: [String: PendingCreation] = [:]
    var pendingRestaurants: [String: PendingRestaurant] = [:]
    func loadSession() throws -> SavedSession? { savedSession }
    func saveSession(_ value: SavedSession) throws { savedSession = value }
    func clearSession() throws { savedSession = nil }
    func loadCreation(scope: String) throws -> PendingCreation? { creations[scope] }
    func saveCreation(_ value: PendingCreation, scope: String) throws { creations[scope] = value }
    func clearCreation(scope: String) throws { creations[scope] = nil }
    func loadRestaurant(scope: String) throws -> PendingRestaurant? { pendingRestaurants[scope] }
    func saveRestaurant(_ value: PendingRestaurant, scope: String) throws { pendingRestaurants[scope] = value }
    func clearRestaurant(scope: String) throws { pendingRestaurants[scope] = nil }
}
#endif
