import SwiftUI
import UIKit

struct DriverView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var showingShift = false
    private var active: Bool { store.currentDriver?.active == true }
    private var completed: [Delivery] {
        store.deliveries.filter { $0.status == .delivered }.sorted { ($0.deliveredAt ?? 0) > ($1.deliveredAt ?? 0) }
    }

    var body: some View {
        List {
            if let route = store.route, let stop = route.stops.first,
               let delivery = store.deliveries.first(where: { $0.id == stop.deliveryId }) {
                nextStop(stop, delivery: delivery, route: route)
            } else if active {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(store.route == nil ? "Loading your route" : "You're ready for deliveries", systemImage: "bicycle")
                            .font(.title2.bold())
                        Text(store.route == nil ? "Your next stop will appear here." : "No remaining stops. Your next delivery will appear here automatically.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(store.route == nil ? "loading_route" : "empty_route")
                    }.padding(.vertical, 8)
                }
            }

            if !active { startShift }
            if active {
                DriverLocationNotice(location: store.location)
                if let error = store.locationErrorMessage {
                    Section {
                        Label(error, systemImage: "location.slash").font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("location_error")
                        Text("Keep the app open. We'll retry when a fresh location is available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let route = store.route, !route.stops.isEmpty {
                Section {
                    DisclosureGroup {
                        RouteMap(stops: route.stops, driverLocation: store.currentDriver?.location)
                        ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(stop.title)").font(.headline)
                                Text(stop.address)
                                Text("Estimated \(stop.arrivalAt.epochDate.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).accessibilityIdentifier("route_stop_\(index)")
                        }
                        Text("About \(route.travelSeconds / 60) min travel · finish \(route.finishAt.epochDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Approximate times, without live traffic.").font(.caption).foregroundStyle(.secondary)
                    } label: {
                        Label("Route · \(route.stops.count) stops", systemImage: "map")
                    }.accessibilityIdentifier("route_details")
                }
            }

            if !completed.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(completed) { delivery in
                            DeliveryRow(delivery: delivery).accessibilityIdentifier("own_delivery_\(delivery.id)")
                        }
                    } label: {
                        Label("Completed · \(completed.count)", systemImage: "checkmark.circle")
                    }.accessibilityIdentifier("delivery_history")
                }
            }
            Section { SyncFooter() }
        }
        .navigationTitle("Your route")
        .accessibilityIdentifier("driver_screen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingShift = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: active ? "circle.fill" : "circle")
                            .font(.system(size: 8)).foregroundStyle(active ? .green : .secondary)
                        Text(active ? "On shift" : "Off shift").accessibilityIdentifier("shift_status")
                    }.font(.subheadline)
                }.accessibilityIdentifier("shift_settings")
            }
        }
        .sheet(isPresented: $showingShift) { DriverShiftSheet() }
        .refreshable { await store.refresh(force: true) }
    }

    private var startShift: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ready to deliver?").font(.title2.bold())
                Text("Share your location with dispatch while the app is open so they can assign nearby deliveries. You can stop sharing anytime.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await store.startShiftAndShareLocation() }
                } label: {
                    Label("Start shift & share location", systemImage: "location.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isMutating || store.currentDriver == nil)
                .accessibilityIdentifier("toggle_shift")
            }.padding(.vertical, 8)
        }
    }

    private func nextStop(_ stop: RouteStop, delivery: Delivery, route: DriverRoute) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEXT STOP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(stop.title) · \(delivery.shopName)")
                        .font(.title2.bold()).accessibilityIdentifier("next_stop_title")
                    Text(stop.address).font(.title3)
                }
                DirectionsButton(stop: stop)
                    .buttonStyle(.bordered)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let nextStatus = DeliveryAction.nextStatus(delivery: delivery, route: route, now: Int(context.date.timeIntervalSince1970))
                    VStack(alignment: .leading, spacing: 8) {
                        if stop.kind == .pickup && context.date < delivery.readyAt.epochDate {
                            Text("Ready at \(delivery.readyAt.epochDate.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await store.completeNextStop(delivery) }
                        } label: {
                            Label(stop.kind == .pickup ? "Confirm pickup" : "Confirm drop-off", systemImage: "checkmark")
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(nextStatus == nil || store.isMutating)
                        .accessibilityIdentifier(stop.kind == .pickup ? "confirm_pickup" : "confirm_dropoff")
                    }
                }
                if !route.feasible {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Route timing needs attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("Contact dispatch about the timing. Your next stop is still shown above.")
                            .font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup("View timing warnings") {
                            ForEach(route.warnings, id: \.self) { Text($0).font(.footnote) }
                        }.font(.footnote)
                    }
                }
            }.padding(.vertical, 8)
        }
    }
}

private struct DriverLocationNotice: View {
    @EnvironmentObject private var store: DeliveryStore
    @ObservedObject var location: LocationReporter
    @Environment(\.openURL) private var openURL

    var body: some View {
        if location.permissionDenied && store.locationSharing {
            Section {
                Label("Allow location to receive nearby deliveries", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold))
                Text("Location access is off. Open iOS Settings and allow location while using Arrivau.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.accessibilityIdentifier("open_location_settings")
            }
        } else if !store.locationSharing {
            Section {
                Text("Share your location with dispatch to receive nearby deliveries while the app is open.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { store.setLocationSharing(true) } label: {
                    Label("Resume location sharing", systemImage: "location.fill")
                }.accessibilityIdentifier("resume_location")
            }
        }
    }
}

private struct DriverShiftSheet: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    private var active: Bool { store.currentDriver?.active == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(store.principal?.name ?? "Driver", value: active ? "On shift" : "Off shift")
                    Toggle("Share location while on shift", isOn: Binding(
                        get: { store.locationSharing }, set: { store.setLocationSharing($0) }
                    )).disabled(!active).accessibilityIdentifier("share_location")
                    Toggle("Continue with screen locked", isOn: Binding(
                        get: { store.backgroundLocationSharing }, set: { store.setBackgroundLocationSharing($0) }
                    )).disabled(!active || !store.locationSharing).accessibilityIdentifier("background_location")
                    Text("This separate option keeps sharing with dispatch when your screen is locked or you're using Maps. iOS shows a location indicator.")
                        .font(.caption).foregroundStyle(.secondary)
                    LocationStatusView(location: store.location)
                    if let updated = store.currentDriver?.locationUpdatedAt {
                        LocationAgeLabel(timestamp: updated, accessibilityID: "location_sent")
                    }
                    Text("Stopping sharing or switching roles stops updates. Your last position remains with dispatch.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Location sharing") }
                if active {
                    DriverLocationNotice(location: store.location)
                    Section {
                        Button("End shift", role: .destructive) {
                            Task {
                                await store.setShift(active: false, capacity: store.currentDriver?.capacity ?? 2)
                                if store.currentDriver?.active == false { dismiss() }
                            }
                        }.disabled(store.isMutating).accessibilityIdentifier("toggle_shift")
                    } footer: {
                        Text("Ending your shift stops location sharing. Finish assigned deliveries first.")
                    }
                }
                Section {
                    DisclosureGroup("About this demo") {
                        Text("Location updates need a fresh position and a network connection. Background sharing needs real-device validation and won't recover after a force-quit. The last position becomes stale after five minutes.")
                            .font(.caption).foregroundStyle(.secondary)
                        if store.isUITesting {
                            Label("Simulated Pachino location", systemImage: "testtube.2").font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Your shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("close_shift_settings")
                }
            }
        }
    }
}

private struct LocationStatusView: View {
    @ObservedObject var location: LocationReporter
    var body: some View {
        Text(location.message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("location_status")
    }
}
