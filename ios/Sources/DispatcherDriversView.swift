import SwiftUI

/// These screens use the dispatcher's existing team-scoped snapshot, never a second account.
struct DispatcherDriversView: View {
    @EnvironmentObject private var store: DeliveryStore
    private var drivers: [Driver] {
        store.drivers.sorted {
            if $0.active != $1.active { return $0.active }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
    var body: some View {
        List {
            if drivers.isEmpty {
                ContentUnavailableView("Nessun corriere", systemImage: "bicycle",
                                       description: Text("I corrieri della squadra appariranno qui."))
            }
            ForEach(drivers) { driver in
                NavigationLink { DispatcherDriverView(driverId: driver.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        DispatcherDriverHeading(driver: driver)
                        let count = DispatcherDriverPresentation.activeDeliveries(store.deliveries, driverId: driver.id).count
                        Text("\(count) consegne in corso").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("driver_\(driver.id)")
            }
            SyncFooter()
        }
        .navigationTitle("Driver")
        .refreshable { await store.refresh(force: true) }
    }
}

struct DispatcherDriverView: View {
    @EnvironmentObject private var store: DeliveryStore
    let driverId: String
    private var driver: Driver? { store.drivers.first { $0.id == driverId } }
    var body: some View {
        List {
            if let driver {
                Section { DispatcherDriverHeading(driver: driver) }
                Section {
                    NavigationLink { DispatcherDriverLiveView(driverId: driverId) } label: {
                        Label("Mappa e percorso live", systemImage: "map")
                    }.accessibilityIdentifier("driver_live_route")
                    NavigationLink { DispatcherDriverHistoryView(driverId: driverId) } label: {
                        Label("Consegne e storico", systemImage: "shippingbox")
                    }.accessibilityIdentifier("driver_deliveries")
                }
            } else {
                ContentUnavailableView("Corriere non disponibile", systemImage: "person.crop.circle.badge.questionmark")
            }
            SyncFooter()
        }
        .navigationTitle(driver?.displayName ?? "Driver")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(force: true) }
    }
}

private struct DispatcherDriverHeading: View {
    let driver: Driver
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(driver.displayName).font(.headline)
                Spacer()
                Text(driver.active ? "In turno" : "Fuori turno")
                    .font(.subheadline).foregroundStyle(driver.active ? Color.green : Color.secondary)
            }
            if driver.location != nil, let timestamp = driver.locationUpdatedAt {
                LocationAgeLabel(timestamp: timestamp, accessibilityID: "driver_location_age_\(driver.id)")
            } else {
                Text("Posizione non disponibile").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DispatcherDriverLiveView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.scenePhase) private var scenePhase
    let driverId: String
    @State private var route: DriverRoute?
    @State private var loading = true
    @State private var failed = false
    @State private var requestID = UUID()
    private var driver: Driver? { store.drivers.first { $0.id == driverId } }

    var body: some View {
        List {
            if let driver {
                Section {
                    DispatcherDriverHeading(driver: driver)
                    Text("Aggiornamento circa ogni 5 secondi mentre l’app è aperta. La mappa mostra l’ultima posizione ricevuta e le prossime tappe, non la traccia GPS percorsa.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    RouteMap(stops: route?.stops ?? [], driverLocation: driver.location)
                        .listRowInsets(EdgeInsets())
                }
                if failed {
                    Section {
                        Label("Percorso non disponibile. Riprova ad aggiornare.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange).accessibilityIdentifier("driver_route_error")
                        Button("Riprova") { Task { await loadRoute() } }.disabled(loading)
                    }
                } else if loading && route == nil {
                    ProgressView("Caricamento del percorso…")
                }
                if let route {
                    if route.stops.isEmpty {
                        Text("Nessuna tappa in programma").foregroundStyle(.secondary)
                            .accessibilityIdentifier("driver_route_empty")
                    } else {
                        Section("Prossime tappe · \(route.stops.count)") {
                            ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                                NavigationLink { DeliveryDetailView(deliveryId: stop.deliveryId) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(index + 1). \(stop.title)").font(.headline)
                                        if let delivery = store.deliveries.first(where: { $0.id == stop.deliveryId }) {
                                            Text(delivery.shopName).font(.subheadline)
                                        }
                                        Text(stop.address).font(.subheadline).foregroundStyle(.secondary)
                                        if route.estimatesAvailable {
                                            Text("Arrivo previsto \(stop.arrivalAt.epochDate.italianTime)").font(.caption)
                                        }
                                    }
                                }.accessibilityIdentifier("dispatcher_route_stop_\(index)")
                            }
                        }
                        Section("Stime del percorso") {
                            if !route.estimatesAvailable {
                                Text(route.unavailableEstimateMessage).foregroundStyle(.orange)
                            }
                            RouteTravelNotice(route: route)
                            ForEach(Array(route.localizedWarnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).foregroundStyle(.orange)
                            }
                            ForEach(route.localizedNotices, id: \.self) { Text($0).foregroundStyle(.orange) }
                        }.font(.footnote)
                    }
                }
            } else {
                ContentUnavailableView("Corriere non disponibile", systemImage: "bicycle")
            }
            SyncFooter()
        }
        .navigationTitle("Percorso live")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("dispatcher_driver_live_route")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await loadRoute()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
        .onDisappear { requestID = UUID() }
        .refreshable {
            await store.refresh(force: true)
            await loadRoute()
        }
    }

    @MainActor private func loadRoute() async {
        let request = UUID()
        requestID = request
        loading = true
        let fetched = await store.dispatcherRoute(driverId: driverId)
        guard requestID == request, !Task.isCancelled else { return }
        // Do not keep an old plan visible as current when its refresh fails.
        route = fetched
        failed = fetched == nil && driver != nil
        loading = false
    }
}

struct DispatcherDriverHistoryView: View {
    @EnvironmentObject private var store: DeliveryStore
    let driverId: String
    private var active: [Delivery] { DispatcherDriverPresentation.activeDeliveries(store.deliveries, driverId: driverId) }
    private var completed: [Delivery] { DispatcherDriverPresentation.completedDeliveries(store.deliveries, driverId: driverId) }
    var body: some View {
        List {
            if let driver = store.drivers.first(where: { $0.id == driverId }) {
                Section { Text(driver.displayName).font(.headline) }
                if active.isEmpty && completed.isEmpty {
                    ContentUnavailableView("Nessuna consegna", systemImage: "shippingbox",
                                           description: Text("Le consegne assegnate a questo corriere appariranno qui."))
                }
                if !active.isEmpty { deliveriesSection("In corso · \(active.count)", deliveries: active) }
                if !completed.isEmpty { deliveriesSection("Completate · \(completed.count)", deliveries: completed) }
            } else {
                ContentUnavailableView("Corriere non disponibile", systemImage: "bicycle")
            }
            SyncFooter()
        }
        .navigationTitle("Consegne e storico")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("dispatcher_driver_history")
        .refreshable { await store.refresh(force: true) }
    }

    private func deliveriesSection(_ title: String, deliveries: [Delivery]) -> some View {
        Section(title) {
            ForEach(deliveries) { delivery in
                NavigationLink { DeliveryDetailView(deliveryId: delivery.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        DeliveryRow(delivery: delivery)
                        if let timestamp = delivery.deliveredAt {
                            Text("Consegnata il \(timestamp.epochDate.italianDateTime)")
                                .accessibilityIdentifier("history_completed_at_\(delivery.id)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("history_delivery_\(delivery.id)")
            }
        }
    }
}
