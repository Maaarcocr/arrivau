import Foundation
import CoreLocation

struct Coordinate: Codable, Equatable, Sendable {
    let lat: Double
    let lng: Double
    var isValid: Bool { lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng) }
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    static let pachino = Coordinate(lat: 36.7163, lng: 15.0908)
}

#if DEBUG
enum DemoRole: String, CaseIterable, Identifiable {
    case dispatcher, driver1, driver2, dual
    var id: String { rawValue }
    var title: String {
        switch self { case .dispatcher: "Centrale"; case .driver1: "Corriere 1"; case .driver2: "Corriere 2"; case .dual: "Centrale e corriere" }
    }
    var token: String {
        switch self { case .dispatcher: "demo-dispatcher"; case .driver1: "demo-driver-1"; case .driver2: "demo-driver-2"; case .dual: "demo-dual" }
    }
    var driverId: String? {
        switch self { case .dispatcher: nil; case .driver1: "driver-1"; case .driver2: "driver-2"; case .dual: "dual-1" }
    }
}

#endif

enum UserRole: String, Codable, CaseIterable, Hashable {
    case dispatcher, driver
    var title: String { self == .dispatcher ? "Centrale" : "Corriere" }
}

struct Principal: Codable, Equatable {
    let id: String
    let name: String
    /// Kept for compatibility with servers that predate multi-capability accounts.
    let role: String
    let roles: [String]
    let teamId: String?
    let teamName: String?
    /// Absent on older/configured accounts; only the server grants self-deletion.
    let canDeleteAccount: Bool

    init(id: String, name: String, role: String, roles: [String]? = nil,
         teamId: String? = nil, teamName: String? = nil, canDeleteAccount: Bool = false) {
        self.id = id; self.name = name; self.role = role
        self.roles = roles ?? [role]
        self.teamId = teamId; self.teamName = teamName
        self.canDeleteAccount = canDeleteAccount
    }
    private enum CodingKeys: String, CodingKey { case id, name, role, roles, teamId, teamName, canDeleteAccount }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decode(String.self, forKey: .role)
        // Explicit empty, null or malformed capabilities must never grant legacy authority.
        roles = values.contains(.roles) ? try values.decode([String].self, forKey: .roles) : [role]
        teamId = try values.decodeIfPresent(String.self, forKey: .teamId)
        teamName = try values.decodeIfPresent(String.self, forKey: .teamName)
        canDeleteAccount = try values.decodeIfPresent(Bool.self, forKey: .canDeleteAccount) ?? false
        if values.contains(.teamId), teamId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw DecodingError.dataCorruptedError(forKey: .teamId, in: values, debugDescription: "Team identity must be nonempty")
        }
    }
    var displayName: String { ItalianPresentation.demoName(id: id, name: name) }
    var availableRoles: [UserRole] { UserRole.allCases.filter { roles.contains($0.rawValue) } }
    func supports(_ capability: UserRole) -> Bool { availableRoles.contains(capability) }
    /// The legacy primary role is a preference, never a capability grant.
    var serverRole: UserRole? {
        if let primary = UserRole(rawValue: role), supports(primary) { return primary }
        return availableRoles.first
    }
    var roleTitle: String { serverRole?.title ?? "Ruolo non riconosciuto" }
    var teamTitle: String? { teamName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? teamName : teamId }
}
struct Driver: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let active: Bool
    let capacity: Int
    let location: Coordinate?
    let locationUpdatedAt: Int?
    var displayName: String { ItalianPresentation.demoName(id: id, name: name) }
}

enum DeliveryStatus: String, Codable, CaseIterable {
    case pending, assigned, pickedUp = "picked_up", delivered
    var progressRank: Int {
        switch self { case .pending: 0; case .assigned: 1; case .pickedUp: 2; case .delivered: 3 }
    }
    var title: String {
        switch self { case .pending: "Da assegnare"; case .assigned: "Assegnata"; case .pickedUp: "In consegna"; case .delivered: "Consegnata" }
    }
}

enum ReadinessState: String, Codable {
    case unknown, estimated, ready
}

struct ReadinessUpdate: Codable, Equatable {
    let readyInMinutes: Int
    let expectedRevision: UInt64
}

struct Delivery: Codable, Identifiable, Equatable {
    let id: String
    let shopName: String
    let pickupAddress: String
    let pickup: Coordinate
    let dropoffAddress: String
    let dropoff: Coordinate
    let readyAt: Int
    let deadlineAt: Int
    let loadUnits: Int
    let maxRideSeconds: Int
    let status: DeliveryStatus
    let driverId: String?
    let createdAt: Int
    let pickedUpAt: Int?
    let deliveredAt: Int?
    let readinessState: ReadinessState
    let readinessRevision: UInt64
    let readinessUpdatedAt: Int?
    let onboardDeadlineAt: Int?
    let dispatchWaitingReason: String?

    init(id: String, shopName: String, pickupAddress: String, pickup: Coordinate,
         dropoffAddress: String, dropoff: Coordinate, readyAt: Int, deadlineAt: Int,
         loadUnits: Int, maxRideSeconds: Int, status: DeliveryStatus, driverId: String?,
         createdAt: Int, pickedUpAt: Int?, deliveredAt: Int?,
         readinessState: ReadinessState = .estimated, readinessRevision: UInt64 = 0,
         readinessUpdatedAt: Int? = nil, onboardDeadlineAt: Int? = nil, dispatchWaitingReason: String? = nil) {
        self.id = id; self.shopName = shopName; self.pickupAddress = pickupAddress; self.pickup = pickup
        self.dropoffAddress = dropoffAddress; self.dropoff = dropoff; self.readyAt = readyAt
        self.deadlineAt = deadlineAt; self.loadUnits = loadUnits; self.maxRideSeconds = maxRideSeconds
        self.status = status; self.driverId = driverId; self.createdAt = createdAt
        self.pickedUpAt = pickedUpAt; self.deliveredAt = deliveredAt
        self.readinessState = readinessState; self.readinessRevision = readinessRevision
        self.readinessUpdatedAt = readinessUpdatedAt; self.onboardDeadlineAt = onboardDeadlineAt
        self.dispatchWaitingReason = dispatchWaitingReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, shopName, pickupAddress, pickup, dropoffAddress, dropoff, readyAt, deadlineAt
        case loadUnits, maxRideSeconds, status, driverId, createdAt, pickedUpAt, deliveredAt
        case readinessState, readinessRevision, readinessUpdatedAt, onboardDeadlineAt, dispatchWaitingReason
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        shopName = try values.decode(String.self, forKey: .shopName)
        pickupAddress = try values.decode(String.self, forKey: .pickupAddress)
        pickup = try values.decode(Coordinate.self, forKey: .pickup)
        dropoffAddress = try values.decode(String.self, forKey: .dropoffAddress)
        dropoff = try values.decode(Coordinate.self, forKey: .dropoff)
        readyAt = try values.decode(Int.self, forKey: .readyAt)
        deadlineAt = try values.decode(Int.self, forKey: .deadlineAt)
        loadUnits = try values.decode(Int.self, forKey: .loadUnits)
        maxRideSeconds = try values.decode(Int.self, forKey: .maxRideSeconds)
        status = try values.decode(DeliveryStatus.self, forKey: .status)
        driverId = try values.decodeIfPresent(String.self, forKey: .driverId)
        createdAt = try values.decode(Int.self, forKey: .createdAt)
        pickedUpAt = try values.decodeIfPresent(Int.self, forKey: .pickedUpAt)
        deliveredAt = try values.decodeIfPresent(Int.self, forKey: .deliveredAt)
        // Only a missing field is legacy data. An explicit unknown never inherits ready_at.
        readinessState = values.contains(.readinessState) ? try values.decode(ReadinessState.self, forKey: .readinessState) : .estimated
        readinessRevision = try values.decodeIfPresent(UInt64.self, forKey: .readinessRevision) ?? 0
        readinessUpdatedAt = try values.decodeIfPresent(Int.self, forKey: .readinessUpdatedAt)
        onboardDeadlineAt = try values.decodeIfPresent(Int.self, forKey: .onboardDeadlineAt)
        dispatchWaitingReason = try values.decodeIfPresent(String.self, forKey: .dispatchWaitingReason)
    }

    var hasKnownReadiness: Bool { readinessState != .unknown }
    var canChangeReadiness: Bool { status == .pending || status == .assigned }
    var pickupTargetAt: Int? { hasKnownReadiness ? readyAt + 600 : nil }
    var localizedDispatchWaitingReason: String? {
        switch dispatchWaitingReason {
        case "no_active_driver": return "Nessun corriere in turno. L’assegnazione riproverà automaticamente."
        case "capacity_or_route_limit": return "Percorso non assegnabile: verifica capacità, numero di tappe e viabilità. L’assegnazione riproverà appena possibile."
        case .some: return "Assegnazione in attesa. Controlla i corrieri in turno."
        case .none: return nil
        }
    }
    var readinessTitle: String { ItalianPresentation.readiness(self) }
}

enum StopKind: String, Codable {
    case pickup, dropoff
    var title: String { self == .pickup ? "Ritiro" : "Consegna" }
}
struct RouteStop: Codable, Identifiable, Equatable {
    let deliveryId: String
    let kind: StopKind
    let address: String
    let coordinate: Coordinate
    let arrivalAt: Int
    let departureAt: Int
    var id: String { "\(deliveryId)-\(kind.rawValue)" }
    var title: String { kind.title }
}
struct RouteTravelEstimate: Codable, Equatable {
    let mode: String
    let approximate: Bool
    let notice: String?
    let mapDate: String?
    let attribution: String?
    static let legacy = RouteTravelEstimate(mode: "approximate", approximate: true,
        notice: "Tempi di viaggio approssimativi: stima in linea d'aria, senza viabilità o traffico.",
        mapDate: nil, attribution: nil)
}
struct DriverRoute: Codable, Equatable {
    let driverId: String
    let stops: [RouteStop]
    let travelSeconds: Int
    let finishAt: Int
    let feasible: Bool
    let warnings: [String]
    let notices: [String]
    let estimatesAvailable: Bool
    let travelEstimate: RouteTravelEstimate?
    var unavailableEstimateMessage: String {
        warnings.contains { $0.hasPrefix("Percorso stradale non raggiungibile per ") }
            ? "Percorso non raggiungibile; orari non disponibili"
            : "Posizione non disponibile; orari da verificare"
    }
    var localizedWarnings: [String] { warnings.map(ItalianPresentation.routeWarning) }
    var localizedNotices: [String] {
        notices.map(ItalianPresentation.routeNotice).reduce(into: []) { result, text in
            if !result.contains(text) { result.append(text) }
        }
    }

    init(driverId: String, stops: [RouteStop], travelSeconds: Int, finishAt: Int,
         feasible: Bool, warnings: [String], notices: [String] = [], estimatesAvailable: Bool = true, travelEstimate: RouteTravelEstimate? = nil) {
        self.driverId = driverId; self.stops = stops; self.travelSeconds = travelSeconds
        self.finishAt = finishAt; self.feasible = feasible; self.warnings = warnings; self.notices = notices
        self.estimatesAvailable = estimatesAvailable; self.travelEstimate = travelEstimate
    }
    private enum CodingKeys: String, CodingKey { case driverId, stops, travelSeconds, finishAt, feasible, warnings, notices, estimatesAvailable, travelEstimate }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        driverId = try values.decode(String.self, forKey: .driverId)
        stops = try values.decode([RouteStop].self, forKey: .stops)
        travelSeconds = try values.decode(Int.self, forKey: .travelSeconds)
        finishAt = try values.decode(Int.self, forKey: .finishAt)
        feasible = try values.decode(Bool.self, forKey: .feasible)
        warnings = try values.decode([String].self, forKey: .warnings)
        notices = try values.decodeIfPresent([String].self, forKey: .notices) ?? []
        estimatesAvailable = try values.decodeIfPresent(Bool.self, forKey: .estimatesAvailable) ?? true
        travelEstimate = try values.decodeIfPresent(RouteTravelEstimate.self, forKey: .travelEstimate)
    }
}
struct Suggestion: Codable, Identifiable, Equatable {
    let driverId: String
    let incrementalTravelSeconds: Int
    let route: DriverRoute
    var id: String { driverId }
}
struct Restaurant: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let coordinate: Coordinate
    let createdAt: Int
}
struct NewRestaurant: Codable, Equatable {
    let name: String
    let address: String
    let coordinate: Coordinate
    var validationError: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Scegli un indirizzo e inserisci il nome del ristorante."
        }
        guard coordinate.isValid else { return "Scegli un indirizzo valido per il ristorante." }
        return nil
    }
}
struct PendingRestaurant: Codable, Equatable {
    let idempotencyKey: String
    let restaurant: NewRestaurant
}

struct NewDelivery: Codable, Equatable {
    let shopName: String
    let pickupAddress: String
    let pickup: Coordinate
    let dropoffAddress: String
    let dropoff: Coordinate
    let readyAt: Int?
    let deadlineAt: Int
    let loadUnits: Int
    let maxRideSeconds: Int

    let restaurantId: String?

    init(shopName: String, pickupAddress: String, pickup: Coordinate, dropoffAddress: String,
         dropoff: Coordinate, readyAt: Int?, deadlineAt: Int, loadUnits: Int, maxRideSeconds: Int,
         restaurantId: String? = nil) {
        self.shopName = shopName; self.pickupAddress = pickupAddress; self.pickup = pickup
        self.dropoffAddress = dropoffAddress; self.dropoff = dropoff; self.readyAt = readyAt
        self.deadlineAt = deadlineAt; self.loadUnits = loadUnits; self.maxRideSeconds = maxRideSeconds
        self.restaurantId = restaurantId
    }

    var validationError: String? {
        if [shopName, pickupAddress, dropoffAddress].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Inserisci il nome del negozio ed entrambi gli indirizzi."
        }
        if !pickup.isValid || !dropoff.isValid { return "Inserisci valori validi di latitudine e longitudine." }
        if let readyAt, deadlineAt < readyAt { return "Il termine di consegna non può precedere l’orario di disponibilità." }
        if !(1...8).contains(loadUnits) { return "Il carico deve essere compreso tra 1 e 8 unità." }
        if !(60...7200).contains(maxRideSeconds) { return "Il tempo massimo di trasporto deve essere compreso tra 1 e 120 minuti." }
        return nil
    }
}

enum DeliveryAction {
    /// Only the first committed route stop may be completed. The server is authoritative.
    static func nextStatus(delivery: Delivery, route: DriverRoute?, now: Int) -> DeliveryStatus? {
        guard let route, let stop = route.stops.first,
              route.driverId == delivery.driverId, stop.deliveryId == delivery.id else { return nil }
        switch (stop.kind, delivery.status) {
        case (.pickup, .assigned): return delivery.hasKnownReadiness && now >= delivery.readyAt ? .pickedUp : nil
        case (.dropoff, .pickedUp): return .delivered
        default: return nil
        }
    }
}

extension Int {
    var epochDate: Date { Date(timeIntervalSince1970: TimeInterval(self)) }
}


