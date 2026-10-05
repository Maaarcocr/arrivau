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
            if delivery.canChangeReadiness {
                Text(delivery.readinessTitle).font(.caption).foregroundStyle(delivery.hasKnownReadiness ? Color.secondary : Color.orange)
            }
            Text("Entro le \(delivery.deadlineAt.epochDate.italianTime)")
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
            Label("Aggiornamento non riuscito. Scorri verso il basso per riprovare.", systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("sync_error")
        }
    }
}
struct DeliveryFacts: View {
    let delivery: Delivery
    var body: some View {
        LabeledContent("Ritiro", value: delivery.pickupAddress)
        LabeledContent("Destinazione", value: delivery.dropoffAddress)
        LabeledContent("Disponibilità", value: delivery.readinessTitle)
            // Expose one semantic field: SwiftUI may otherwise combine the child Text
            // with the title differently across OS versions and accessibility queries.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disponibilità")
            .accessibilityValue(delivery.readinessTitle)
            .accessibilityIdentifier("delivery_readiness")
        if delivery.canChangeReadiness, let target = delivery.pickupTargetAt {
            LabeledContent("Obiettivo ritiro", value: "Entro le \(target.epochDate.italianTime)")
        }
        if delivery.status == .pickedUp, let deadline = delivery.onboardDeadlineAt {
            LabeledContent("Tempo a bordo fino alle", value: deadline.epochDate.italianTime)
        }
        LabeledContent("Da consegnare entro", value: delivery.deadlineAt.epochDate.italianDateTime)
    }
}
struct RouteMap: View {
    let stops: [RouteStop]
    let driverLocation: Coordinate?
    var body: some View {
        Group {
            if stops.contains(where: { $0.googlePlaceId != nil }) {
                if stops.allSatisfy({ $0.googlePlaceId != nil }) {
                    GoogleRouteOverview(stops: stops, driverLocation: driverLocation)
                } else {
                    Text("Alcuni indirizzi devono essere selezionati di nuovo. Controlla le tappe nell’elenco.")
                        .font(.subheadline).foregroundStyle(.secondary).padding()
                }
            } else {
                Map {
                    if let driverLocation {
                        Marker("Corriere", systemImage: "bicycle", coordinate: driverLocation.clCoordinate).tint(.blue)
                    }
                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                        if let coordinate = stop.coordinate {
                            Marker("\(index + 1). \(stop.title)", coordinate: coordinate.clCoordinate)
                                .tint(stop.kind == .pickup ? .orange : .green)
                        }
                    }
                }
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // Keep the overview as one container without overwriting its child
        // labels/identifiers or hiding individual map controls from VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mappa del percorso")
        .accessibilityIdentifier("route_map")
    }
}

struct LocationAgeLabel: View {
    let timestamp: Int
    var accessibilityID = "location_age"
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let age = max(0, Int(context.date.timeIntervalSince1970) - timestamp)
            Text("Ultima posizione \(timestamp.epochDate.italianTimeWithSeconds) · \(age > 300 ? "non aggiornata (>5 min)" : "recente")")
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
            .accessibilityValue(expanded ? "Espanso" : "Compresso")
            if expanded { content }
        }
    }
}

/// Road estimates and their fallback/provenance remain visible in both roles.
struct RouteTravelNotice: View {
    let route: DriverRoute
    var identifier = "route_travel_estimate"
    var body: some View {
        if !route.stops.isEmpty {
            let estimate = route.travelEstimate ?? .legacy
            VStack(alignment: .leading, spacing: 4) {
                if let notice = estimate.notice {
                    Label(notice, systemImage: estimate.approximate ? "exclamationmark.triangle" : "road.lanes")
                        .foregroundStyle(estimate.approximate ? Color.orange : Color.secondary)
                        .accessibilityIdentifier(identifier)
                }
                if estimate.attribution != nil {
                    Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .accessibilityIdentifier("routing_attribution")
                }
                if let date = estimate.mapDate {
                    Text("Dati mappa: \(String(date.prefix(10)))").foregroundStyle(.secondary)
                }
            }.font(.caption)
        }
    }
}

