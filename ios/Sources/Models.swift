import Foundation
import CoreLocation

struct Coordinate: Codable, Equatable, Sendable {
    let lat: Double
    let lng: Double
    var isValid: Bool { lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng) }
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    static let pachino = Coordinate(lat: 36.7163, lng: 15.0908)
}

enum DemoRole: String, CaseIterable, Identifiable {
    case dispatcher, driver1, driver2
    var id: String { rawValue }
    var title: String {
        switch self { case .dispatcher: "Dispatcher"; case .driver1: "Driver 1"; case .driver2: "Driver 2" }
    }
    var token: String {
        switch self { case .dispatcher: "demo-dispatcher"; case .driver1: "demo-driver-1"; case .driver2: "demo-driver-2" }
    }
    var driverId: String? {
        switch self { case .dispatcher: nil; case .driver1: "driver-1"; case .driver2: "driver-2" }
    }
}

struct Principal: Decodable, Equatable { let id: String; let name: String; let role: String }
struct Driver: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let active: Bool
    let capacity: Int
    let location: Coordinate?
    let locationUpdatedAt: Int?
}

enum DeliveryStatus: String, Codable, CaseIterable {
    case pending, assigned, pickedUp = "picked_up", delivered
    var title: String {
        switch self { case .pending: "Pending"; case .assigned: "Assigned"; case .pickedUp: "On board"; case .delivered: "Delivered" }
    }
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
}

enum StopKind: String, Codable { case pickup, dropoff }
struct RouteStop: Codable, Identifiable, Equatable {
    let deliveryId: String
    let kind: StopKind
    let address: String
    let coordinate: Coordinate
    let arrivalAt: Int
    let departureAt: Int
    var id: String { "\(deliveryId)-\(kind.rawValue)" }
    var title: String { kind == .pickup ? "Pick up" : "Drop off" }
}
struct DriverRoute: Codable, Equatable {
    let driverId: String
    let stops: [RouteStop]
    let travelSeconds: Int
    let finishAt: Int
    let feasible: Bool
    let warnings: [String]
}
struct Suggestion: Codable, Identifiable, Equatable {
    let driverId: String
    let incrementalTravelSeconds: Int
    let route: DriverRoute
    var id: String { driverId }
}
struct NewDelivery: Codable, Equatable {
    let shopName: String
    let pickupAddress: String
    let pickup: Coordinate
    let dropoffAddress: String
    let dropoff: Coordinate
    let readyAt: Int
    let deadlineAt: Int
    let loadUnits: Int
    let maxRideSeconds: Int

    var validationError: String? {
        if [shopName, pickupAddress, dropoffAddress].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Enter the shop name and both addresses."
        }
        if !pickup.isValid || !dropoff.isValid { return "Enter valid latitude and longitude values." }
        if deadlineAt < readyAt { return "The deadline must be after the ready time." }
        if !(1...8).contains(loadUnits) { return "Load must be between 1 and 8 units." }
        if !(60...7200).contains(maxRideSeconds) { return "Maximum ride must be between 1 and 120 minutes." }
        return nil
    }
}

enum DeliveryAction {
    /// Only the first committed route stop may be completed. The server is authoritative.
    static func nextStatus(delivery: Delivery, route: DriverRoute?, now: Int) -> DeliveryStatus? {
        guard let route, let stop = route.stops.first,
              route.driverId == delivery.driverId, stop.deliveryId == delivery.id else { return nil }
        switch (stop.kind, delivery.status) {
        case (.pickup, .assigned): return now >= delivery.readyAt ? .pickedUp : nil
        case (.dropoff, .pickedUp): return .delivered
        default: return nil
        }
    }
}

extension Int {
    var epochDate: Date { Date(timeIntervalSince1970: TimeInterval(self)) }
}
