import SwiftUI

struct DriverView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var capacity = 2
    private var active: Bool { store.currentDriver?.active == true }
    var body: some View {
        List {
            Section {
                HStack {
                    Label(store.principal?.name ?? "Driver", systemImage: "bicycle")
                    Spacer()
                    Text(active ? "On shift" : "Off shift")
                        .foregroundStyle(active ? .green : .secondary)
                        .accessibilityIdentifier("shift_status")
                }.font(.headline)
                Stepper("Capacity: \(capacity) units", value: $capacity, in: 1...8)
                    .disabled(active || store.isMutating).accessibilityIdentifier("driver_capacity")
                Button(active ? "End shift" : "Start shift") {
                    Task { await store.setShift(active: !active, capacity: capacity) }
                }
                .disabled(store.isMutating || store.currentDriver == nil)
                .accessibilityIdentifier("toggle_shift")
                Toggle("Share location while on shift", isOn: Binding(
                    get: { store.locationSharing }, set: { store.setLocationSharing($0) }
                ))
                .disabled(!active).accessibilityIdentifier("share_location")
                Toggle("Continue with screen locked", isOn: Binding(
                    get: { store.backgroundLocationSharing }, set: { store.setBackgroundLocationSharing($0) }
                ))
                .disabled(!active || !store.locationSharing).accessibilityIdentifier("background_location")
                LocationStatusView(location: store.location)
                if let error = store.locationErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("location_error")
                }
                if let updated = store.currentDriver?.locationUpdatedAt {
                    LocationAgeLabel(timestamp: updated).accessibilityIdentifier("location_sent")
                }
                Text("Sharing starts only after opt-in on an active shift. The separate screen-lock switch enables background continuation and the iOS location indicator. Switching roles, disabling sharing or ending a shift stops updates. The shift and its last position remain on the server. Background delivery needs real-device validation; force-quit recovery is not provided.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Your shift") }

            if let route = store.route {
                if !route.feasible {
                    Section("Route needs attention") {
                        Label("Estimates no longer fit all constraints", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        ForEach(route.warnings, id: \.self) { Text($0).font(.footnote) }
                        Text("Contact dispatch. Your assigned stops remain visible below.").font(.footnote)
                    }
                }
                if let stop = route.stops.first,
                   let delivery = store.deliveries.first(where: { $0.id == stop.deliveryId }) {
                    Section("Next stop") {
                        Text("\(stop.title) · \(delivery.shopName)").font(.title3.bold()).accessibilityIdentifier("next_stop_title")
                        Text(stop.address)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let nextStatus = DeliveryAction.nextStatus(delivery: delivery, route: route, now: Int(context.date.timeIntervalSince1970))
                            if stop.kind == .pickup && context.date < delivery.readyAt.epochDate {
                                Text("Ready at \(delivery.readyAt.epochDate.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            }
                            Button(stop.kind == .pickup ? "Confirm pickup" : "Confirm drop-off") {
                                Task { await store.completeNextStop(delivery) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(nextStatus == nil || store.isMutating)
                            .accessibilityIdentifier(stop.kind == .pickup ? "confirm_pickup" : "confirm_dropoff")
                        }
                        DirectionsButton(stop: stop)
                    }
                }
                Section("Ordered route") {
                    if route.stops.isEmpty {
                        Label("No remaining stops", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            .accessibilityIdentifier("empty_route")
                    } else {
                        RouteMap(stops: route.stops, driverLocation: store.currentDriver?.location)
                        ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(stop.title)").font(.headline)
                                Text(stop.address)
                                Text("Estimated \(stop.arrivalAt.epochDate.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.accessibilityIdentifier("route_stop_\(index)")
                        }
                        Text("Approx. \(route.travelSeconds / 60) min travel · finish \(route.finishAt.epochDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Your deliveries") {
                if store.deliveries.isEmpty { Text("Nothing assigned yet").foregroundStyle(.secondary) }
                ForEach(store.deliveries.sorted { $0.createdAt > $1.createdAt }) { delivery in
                    DeliveryRow(delivery: delivery).accessibilityIdentifier("own_delivery_\(delivery.id)")
                }
            }
            Section { SyncFooter() }
        }
        .navigationTitle("Driver")
        .accessibilityIdentifier("driver_screen")
        .refreshable { await store.refresh(force: true) }
        .onChange(of: store.currentDriver?.capacity, initial: true) { _, value in if let value { capacity = value } }
    }
}

private struct LocationStatusView: View {
    @ObservedObject var location: LocationReporter
    var body: some View {
        Text(location.message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("location_status")
    }
}
