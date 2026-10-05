import SwiftUI
import UIKit

struct DriverView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var showingShift = false
    @State private var navigationDestination: NavigationDestination?
    private var active: Bool { store.currentDriver?.active == true }
    private var completed: [Delivery] {
        store.deliveries.filter { $0.status == .delivered }.sorted { ($0.deliveredAt ?? 0) > ($1.deliveredAt ?? 0) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            List {
                if active || store.route?.stops.isEmpty == false {
                    Section {
                        RouteMap(stops: store.route?.stops ?? [], driverLocation: store.currentDriver?.location)
                            .listRowInsets(EdgeInsets())
                    }
                }
                if let route = store.route, let stop = route.stops.first,
                   let delivery = store.deliveries.first(where: { $0.id == stop.deliveryId }) {
                    nextStop(stop, delivery: delivery, route: route)
                } else if active {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(store.route == nil ? "Caricamento del percorso" : "In attesa di consegne", systemImage: "bicycle")
                                .font(.headline)
                            Text("La prossima tappa apparirà qui automaticamente.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier(store.route == nil ? "loading_route" : "empty_route")
                        }.padding(.vertical, 4)
                    }
                }
                if !active { startShift }
                if active {
                    DriverLocationNotice(location: store.location, now: context.date)
                    if let error = store.locationErrorMessage {
                        Section {
                            Label(error, systemImage: "location.slash").font(.footnote).foregroundStyle(.orange)
                                .accessibilityIdentifier("location_error")
                        }
                    }
                }
                if let route = store.route, route.stops.count > 1 {
                    Section {
                        ExpandableDetails("Altre tappe · \(route.stops.count - 1)", systemImage: "list.bullet", identifier: "route_details") {
                            ForEach(Array(route.stops.enumerated().dropFirst()), id: \.element.id) { index, stop in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1). \(stop.title)").font(.headline)
                                    Text(stop.address).font(.subheadline)
                                    if route.estimatesAvailable {
                                        Text("Arrivo \(stop.arrivalAt.epochDate.italianTime)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4).accessibilityIdentifier("route_stop_\(index)")
                            }
                            if route.estimatesAvailable {
                                Text("Circa \(route.travelSeconds / 60) min di viaggio · fine alle \(route.finishAt.epochDate.italianTime)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let route = store.route, !route.stops.isEmpty {
                    routeDetails(route)
                }
                if !completed.isEmpty {
                    Section {
                        ExpandableDetails("Completate · \(completed.count)", systemImage: "checkmark.circle", identifier: "delivery_history") {
                            ForEach(completed) { delivery in
                                DeliveryRow(delivery: delivery).accessibilityIdentifier("own_delivery_\(delivery.id)")
                            }
                        }
                    }
                }
                if store.syncErrorMessage != nil {
                    Section { SyncFooter() }
                }
            }
            .listSectionSpacing(.compact)
        }
        .navigationTitle("Il tuo percorso")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("driver_screen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingShift = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: active ? "circle.fill" : "circle")
                            .font(.system(size: 8)).foregroundStyle(active ? .green : .secondary)
                        Text(active ? "In turno" : "Fuori turno").accessibilityIdentifier("shift_status")
                    }.font(.subheadline)
                }.accessibilityIdentifier("shift_settings")
            }
        }
        .sheet(isPresented: $showingShift) { DriverShiftSheet() }
        .fullScreenCover(item: $navigationDestination) { destination in
            DriverNavigationView(destination: destination, isUITesting: store.isUITesting)
        }
        .refreshable { await store.refresh(force: true) }
    }

    private var startShift: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pronto a consegnare?").font(.title2.bold())
                Text(DriverPresentation.shiftConsent)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shift_location_consent")
                Button {
                    Task { await store.startShiftAndShareLocation() }
                } label: {
                    Label("Avvia turno e condividi posizione", systemImage: "location.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isMutating || store.currentDriver == nil)
                .accessibilityIdentifier("toggle_shift")
            }.padding(.vertical, 4)
        }
    }

    private func nextStop(_ stop: RouteStop, delivery: Delivery, route: DriverRoute) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROSSIMA TAPPA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(DriverPresentation.nextStopTitle(stop, delivery: delivery))
                        .font(.headline).accessibilityIdentifier("next_stop_title")
                    Text(stop.address).font(.subheadline)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if stop.kind == .pickup {
                        Text(DriverPresentation.readiness(delivery)).accessibilityIdentifier("driver_readiness")
                    }
                    if let timing = DriverPresentation.timing(stop, delivery: delivery, route: route) {
                        Text(timing).accessibilityIdentifier("next_stop_timing")
                    }
                    if let summary = DriverPresentation.travelSummary(route) {
                        Text(summary)
                            .foregroundStyle((route.travelEstimate ?? .legacy).approximate ? Color.orange : Color.secondary)
                            .accessibilityIdentifier("route_travel_estimate")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let nextStatus = DeliveryAction.nextStatus(delivery: delivery, route: route, now: Int(context.date.timeIntervalSince1970))
                    Button {
                        Task { await store.completeNextStop(delivery) }
                    } label: {
                        Label(stop.kind == .pickup ? "Conferma ritiro" : "Conferma consegna", systemImage: "checkmark")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!active || nextStatus == nil || store.isMutating)
                    .accessibilityIdentifier(stop.kind == .pickup ? "confirm_pickup" : "confirm_dropoff")
                }
                Button {
                    navigationDestination = store.navigationDestination
                } label: {
                    Label("Naviga con Google", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderless)
                .disabled(store.navigationDestination == nil)
                .accessibilityIdentifier("open_directions")
                Text("Google usa posizione e destinazione per le indicazioni. Avvia da fermo.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(DriverPresentation.alerts(route), id: \.self) { alert in
                    Label(alert, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier(!route.estimatesAvailable && alert == route.unavailableEstimateMessage
                            ? "route_estimates_unavailable" : "route_notice")
                }
            }.padding(.vertical, 4)
        }
    }

    private func routeDetails(_ route: DriverRoute) -> some View {
        Section {
            ExpandableDetails("Dettagli degli orari", identifier: "route_warnings") {
                RouteTravelNotice(route: route, identifier: "route_travel_detail")
                ForEach(Array(Set(route.localizedWarnings + route.localizedNotices)).sorted(), id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                }
            }.font(.footnote)
        }
    }
}

private struct DriverLocationNotice: View {
    @EnvironmentObject private var store: DeliveryStore
    @ObservedObject var location: LocationReporter
    var now: Date = .now
    @Environment(\.openURL) private var openURL

    var body: some View {
        if location.permissionDenied && store.locationSharing {
            Section {
                Label("Posizione non consentita", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold))
                Button("Consenti la posizione nelle Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.accessibilityIdentifier("open_location_settings")
            }
        } else if !store.locationSharing {
            Section {
                Button { store.setLocationSharing(true) } label: {
                    Label("Riprendi condivisione posizione", systemImage: "location.fill")
                }.accessibilityIdentifier("resume_location")
                Text("Con la centrale, mentre l’app è aperta. Per continuare a schermo bloccato, apri Il tuo turno.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !store.canSwitchRole, store.locationErrorMessage == nil,
                  [.waitingForForeground, .waitingForLocation, .permissionNeeded, .unavailable].contains(location.state) {
            Section {
                Label(location.compactMessage, systemImage: "location.slash")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("location_sensor_notice")
            }
        }
        if let updated = store.currentDriver?.locationUpdatedAt,
           Int(now.timeIntervalSince1970) - updated > 300,
           !(store.route?.stops.isEmpty == false && store.route?.warnings.contains("Driver location is older than 5 minutes; estimates may be inaccurate") == true) {
            Section {
                Label("GPS oltre 5 minuti: verifica posizione e rete", systemImage: "location.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("location_stale_notice")
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
                    LabeledContent("Stato", value: active ? "In turno" : "Fuori turno")
                    Toggle("Condividi la posizione", isOn: Binding(
                        get: { store.locationSharing }, set: { store.setLocationSharing($0) }
                    )).disabled(!active).accessibilityIdentifier("share_location")
                    Toggle("Anche a schermo bloccato", isOn: Binding(
                        get: { store.backgroundLocationSharing }, set: { store.setBackgroundLocationSharing($0) }
                    )).disabled(!active || !store.locationSharing).accessibilityIdentifier("background_location")
                    if let updated = store.currentDriver?.locationUpdatedAt {
                        LocationAgeLabel(timestamp: updated, accessibilityID: "location_sent")
                    }
                } footer: {
                    Text("La posizione è condivisa con la centrale solo durante il turno. Ferma la condivisione o esci per interromperla. L’ultima posizione resta alla centrale.")
                }
                if active {
                    if store.location.permissionDenied && store.locationSharing {
                        DriverLocationNotice(location: store.location)
                    }
                    Section {
                        Button("Termina turno", role: .destructive) {
                            Task {
                                await store.setShift(active: false, capacity: store.currentDriver?.capacity ?? 2)
                                if store.currentDriver?.active == false { dismiss() }
                            }
                        }.disabled(store.isMutating).accessibilityIdentifier("toggle_shift")
                    } footer: {
                        Text("Completa o fai riassegnare le consegne in corso prima di terminare il turno.")
                    }
                }
                Section {
                    ExpandableDetails("Dettagli della posizione", identifier: "driver_demo_details") {
                        LocationStatusView(location: store.location)
                        Text("Gli aggiornamenti richiedono una posizione recente e rete. Con lo schermo bloccato iOS mostra l’indicatore. Dopo una chiusura forzata, riapri l’app e riprendi la condivisione. Cambiare vista nello stesso account mantiene il consenso dato.")
                            .font(.caption).foregroundStyle(.secondary)
                        if store.isUITesting {
                            Label("Posizione simulata a Pachino", systemImage: "testtube.2").font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Il tuo turno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }.accessibilityIdentifier("close_shift_settings")
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
