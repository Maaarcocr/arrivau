import Foundation

enum DispatcherDriverPresentation {
    static func activeDeliveries(_ deliveries: [Delivery], driverId: String) -> [Delivery] {
        deliveries.filter { $0.driverId == driverId && $0.status != .delivered }.sorted {
            if $0.deadlineAt != $1.deadlineAt { return $0.deadlineAt < $1.deadlineAt }
            return $0.id < $1.id
        }
    }

    static func completedDeliveries(_ deliveries: [Delivery], driverId: String) -> [Delivery] {
        deliveries.filter { $0.driverId == driverId && $0.status == .delivered }.sorted {
            let lhs = $0.deliveredAt ?? $0.createdAt
            let rhs = $1.deliveredAt ?? $1.createdAt
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
}
