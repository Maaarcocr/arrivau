import SwiftUI
import MapKit

struct StatusPill: View {
    let status: DeliveryStatus
    private var color: Color {
        switch status { case .pending: .secondary; case .assigned: .blue; case .pickedUp: .orange; case .delivered: .green }
    }
    var body: some View {
        Text(status.title).font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}
struct DeliveryRow: View {
    let delivery: Delivery
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(delivery.shopName).font(.headline); Spacer(); StatusPill(status: delivery.status) }
            Label(delivery.dropoffAddress, systemImage: "mappin.and.ellipse")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text("Due \(delivery.deadlineAt.epochDate.formatted(date: .omitted, time: .shortened))")
                Spacer()
                Text("\(delivery.loadUnits) unit\(delivery.loadUnits == 1 ? "" : "s")")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
struct SyncFooter: View {
    @EnvironmentObject private var store: DeliveryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = store.syncErrorMessage {
                Label("Refresh failed: \(error)", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                    .accessibilityIdentifier("sync_error")
            }
            if let synced = store.lastSyncedAt {
                Text("Updated \(synced.formatted(date: .omitted, time: .standard)) · refreshes every 5s in foreground")
            } else { Text("Connecting to local API…") }
            Text("Estimates use straight-line distances, a road multiplier and constant speed. No live traffic or road routing.")
        }.font(.caption).foregroundStyle(.secondary)
    }
}
struct DeliveryFacts: View {
    let delivery: Delivery
    var body: some View {
        LabeledContent("Pickup", value: delivery.pickupAddress)
        LabeledContent("Drop-off", value: delivery.dropoffAddress)
        LabeledContent("Ready", value: delivery.readyAt.epochDate.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Deadline", value: delivery.deadlineAt.epochDate.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Load", value: "\(delivery.loadUnits) units")
        LabeledContent("Max ride", value: "\(delivery.maxRideSeconds / 60) minutes")
    }
}
struct RouteMap: View {
    let stops: [RouteStop]
    let driverLocation: Coordinate?
    var body: some View {
        Map {
            if let driverLocation {
                Marker("Driver", systemImage: "bicycle", coordinate: driverLocation.clCoordinate).tint(.blue)
            }
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                Marker("\(index + 1). \(stop.title)", coordinate: stop.coordinate.clCoordinate)
                    .tint(stop.kind == .pickup ? .orange : .green)
            }
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("route_map")
    }
}
struct DirectionsButton: View {
    let stop: RouteStop
    var body: some View {
        Button {
            let destination = MKMapItem(placemark: MKPlacemark(coordinate: stop.coordinate.clCoordinate))
            destination.name = stop.address
            destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        } label: { Label("Directions in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") }
        .accessibilityIdentifier("open_directions")
    }
}

struct LocationAgeLabel: View {
    let timestamp: Int
    var accessibilityID = "location_age"
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let age = max(0, Int(context.date.timeIntervalSince1970) - timestamp)
            Text("Last location \(timestamp.epochDate.formatted(date: .omitted, time: .standard)) · \(age > 300 ? "stale (>5 min)" : "recent")")
                .font(.caption).foregroundStyle(age > 300 ? Color.orange : Color.secondary)
                .accessibilityIdentifier(accessibilityID)
        }
    }
}
