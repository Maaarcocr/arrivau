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
        List {
            if let route = store.route, let stop = route.stops.first,
               let delivery = store.deliveries.first(where: { $0.id == stop.deliveryId }) {
                nextStop(stop, delivery: delivery, route: route)
            } else if active {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(store.route == nil ? "Caricamento del percorso" : "Tutto pronto per le consegne", systemImage: "bicycle")
                            .font(.title2.bold())
                        Text(store.route == nil ? "La prossima tappa apparirà qui." : "Non ci sono altre tappe. La prossima consegna apparirà qui automaticamente.")
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
                        Text("Tieni aperta l’app. Riproveremo appena sarà disponibile una posizione aggiornata.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let route = store.route, !route.stops.isEmpty {
                Section {
                    ExpandableDetails("Percorso · \(route.stops.count) \(route.stops.count == 1 ? "tappa" : "tappe")", systemImage: "map", identifier: "route_details") {
                        RouteMap(stops: route.stops, driverLocation: store.currentDriver?.location)
                        ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(stop.title)").font(.headline)
                                Text(stop.address)
                                if route.estimatesAvailable {
                                    Text("Arrivo previsto alle \(stop.arrivalAt.epochDate.italianTime)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4).accessibilityIdentifier("route_stop_\(index)")
                        }
                        if route.estimatesAvailable {
                            Text("Circa \(route.travelSeconds / 60) min di viaggio · fine alle \(route.finishAt.epochDate.italianTime)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Tempi indicativi, senza traffico in tempo reale.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(route.unavailableEstimateMessage).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
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
            Section { SyncFooter() }
        }
        .navigationTitle("Il tuo percorso")
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
            VStack(alignment: .leading, spacing: 14) {
                Text("Pronto a consegnare?").font(.title2.bold())
                Text("Condividi la posizione con la centrale mentre l’app è aperta, per ricevere consegne nelle vicinanze. Puoi interrompere la condivisione in qualsiasi momento.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await store.startShiftAndShareLocation() }
                } label: {
                    Label("Avvia turno e condividi posizione", systemImage: "location.fill")
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
                    Text("PROSSIMA TAPPA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(stop.title) · \(delivery.shopName)")
                        .font(.title2.bold()).accessibilityIdentifier("next_stop_title")
                    Text(stop.address).font(.title3)
                }
                if !route.estimatesAvailable {
                    Text(route.unavailableEstimateMessage)
                        .font(.subheadline).foregroundStyle(.orange).accessibilityIdentifier("route_estimates_unavailable")
                }
                RouteTravelNotice(route: route)
                Button {
                    navigationDestination = store.navigationDestination
                } label: {
                    Label("Naviga con Google", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .disabled(store.navigationDestination == nil)
                .accessibilityIdentifier("open_directions")
                Text("Posizione e destinazione saranno usate da Google per indicazioni e ricalcolo. Avvia da fermo.")
                    .font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let nextStatus = DeliveryAction.nextStatus(delivery: delivery, route: route, now: Int(context.date.timeIntervalSince1970))
                    VStack(alignment: .leading, spacing: 8) {
                        if stop.kind == .pickup {
                            Text(delivery.readinessTitle)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("driver_readiness")
                            if route.estimatesAvailable {
                                Text("Ritiro previsto alle \(stop.arrivalAt.epochDate.italianTime)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            if let target = delivery.pickupTargetAt {
                                Text("Obiettivo ritiro entro le \(target.epochDate.italianTime)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let deadline = delivery.onboardDeadlineAt {
                            Text("Tempo a bordo fino alle \(deadline.epochDate.italianTime)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await store.completeNextStop(delivery) }
                        } label: {
                            Label(stop.kind == .pickup ? "Conferma ritiro" : "Conferma consegna", systemImage: "checkmark")
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(nextStatus == nil || store.isMutating)
                        .accessibilityIdentifier(stop.kind == .pickup ? "confirm_pickup" : "confirm_dropoff")
                    }
                }
                ForEach(route.localizedNotices, id: \.self) { notice in
                    Label(notice, systemImage: "clock.badge.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("route_notice")
                }
                if !route.feasible || !route.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Controlla i tempi del percorso", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("Contatta la centrale per gli orari. La prossima tappa rimane indicata qui sopra.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ExpandableDetails("Vedi gli avvisi sugli orari", identifier: "route_warnings") {
                            ForEach(route.localizedWarnings, id: \.self) { Text($0).font(.footnote) }
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
                Label("Consenti la posizione per ricevere consegne vicine", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold))
                Text("L’accesso alla posizione è disattivato. Apri le Impostazioni di iOS e consenti la posizione mentre usi Arrivau.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apri Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.accessibilityIdentifier("open_location_settings")
            }
        } else if !store.locationSharing {
            Section {
                Text("Condividi la posizione con la centrale per ricevere consegne vicine mentre l’app è aperta.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { store.setLocationSharing(true) } label: {
                    Label("Riprendi condivisione posizione", systemImage: "location.fill")
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
                    LabeledContent(store.principal?.displayName ?? "Corriere", value: active ? "In turno" : "Fuori turno")
                    Toggle("Condividi la posizione durante il turno", isOn: Binding(
                        get: { store.locationSharing }, set: { store.setLocationSharing($0) }
                    )).disabled(!active).accessibilityIdentifier("share_location")
                    Toggle("Continua con lo schermo bloccato", isOn: Binding(
                        get: { store.backgroundLocationSharing }, set: { store.setBackgroundLocationSharing($0) }
                    )).disabled(!active || !store.locationSharing).accessibilityIdentifier("background_location")
                    Text("Questa opzione separata mantiene la condivisione con la centrale quando lo schermo è bloccato o usi Mappe. iOS mostra un indicatore della posizione.")
                        .font(.caption).foregroundStyle(.secondary)
                    LocationStatusView(location: store.location)
                    if let updated = store.currentDriver?.locationUpdatedAt {
                        LocationAgeLabel(timestamp: updated, accessibilityID: "location_sent")
                    }
                    Text("Passare tra Centrale e Corriere nello stesso account mantiene il consenso già dato. Ferma la condivisione, termina il turno o esci per interrompere gli aggiornamenti. L’ultima posizione rimane alla centrale.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Condivisione posizione") }
                if active {
                    DriverLocationNotice(location: store.location)
                    Section {
                        Button("Termina turno", role: .destructive) {
                            Task {
                                await store.setShift(active: false, capacity: store.currentDriver?.capacity ?? 2)
                                if store.currentDriver?.active == false { dismiss() }
                            }
                        }.disabled(store.isMutating).accessibilityIdentifier("toggle_shift")
                    } footer: {
                        Text("Terminando il turno si interrompe la condivisione della posizione. Completa prima le consegne assegnate.")
                    }
                }
                Section {
                    ExpandableDetails("Informazioni sulla demo", identifier: "driver_demo_details") {
                        Text("Gli aggiornamenti richiedono una posizione recente e una connessione di rete. La condivisione in background deve essere verificata su un dispositivo reale e non riprende dopo una chiusura forzata. Dopo cinque minuti, l’ultima posizione non è più considerata aggiornata.")
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

