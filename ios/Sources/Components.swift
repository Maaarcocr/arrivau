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
            Text(delivery.status == .pending ? "Choose a driver" : "Due \(delivery.deadlineAt.epochDate.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(delivery.status == .pending ? .orange : .secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
struct SyncFooter: View {
    @EnvironmentObject private var store: DeliveryStore
    var body: some View {
        if store.syncErrorMessage != nil {
            Label("Couldn’t refresh. Pull down to try again.", systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("sync_error")
        }
    }
}
struct DeliveryFacts: View {
    let delivery: Delivery
    var body: some View {
        LabeledContent("Pickup", value: delivery.pickupAddress)
        LabeledContent("Drop-off", value: delivery.dropoffAddress)
        LabeledContent("Ready", value: delivery.readyAt.epochDate.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Deadline", value: delivery.deadlineAt.epochDate.formatted(date: .abbreviated, time: .shortened))
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
        } label: { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") }
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


/// The whole row is a button, so details do not require a precise chevron tap.
struct ExpandableDetails<Content: View>: View {
    let title: String
    let systemImage: String?
    let identifier: String
    let content: Content
    @State private var expanded = false

    init(_ title: String, systemImage: String? = nil, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                    Spacer(minLength: 12)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content }
        }
    }
}
