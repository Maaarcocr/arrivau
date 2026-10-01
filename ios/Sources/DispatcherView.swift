import SwiftUI

struct DispatcherView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var showingCreate = false
    var body: some View {
        List {
            Section {
                HStack {
                    Label("\(store.deliveries.filter { $0.status != .delivered }.count) open", systemImage: "shippingbox")
                    Spacer()
                    Text("\(store.drivers.filter(\.active).count) drivers on shift").foregroundStyle(.secondary)
                }.font(.subheadline)
                Button { showingCreate = true } label: { Label("Create delivery", systemImage: "plus.circle.fill") }
                    .accessibilityIdentifier("create_delivery")
            }
            Section("Deliveries") {
                if store.deliveries.isEmpty {
                    ContentUnavailableView("No deliveries yet", systemImage: "shippingbox", description: Text("Create one to start planning."))
                }
                ForEach(store.deliveries.sorted { $0.createdAt > $1.createdAt }) { delivery in
                    NavigationLink {
                        DeliveryDetailView(deliveryId: delivery.id)
                    } label: { DeliveryRow(delivery: delivery) }
                    .accessibilityIdentifier("delivery_\(delivery.id)")
                }
            }
            Section("Drivers") {
                ForEach(store.drivers) { driver in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(driver.name, systemImage: "bicycle")
                            Spacer()
                            Text(driver.active ? "On shift" : "Off shift").foregroundStyle(driver.active ? .green : .secondary)
                        }
                        Text("Capacity \(driver.capacity) · \(driver.location == nil ? "No location shared" : "Location available")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let updated = driver.locationUpdatedAt {
                            LocationAgeLabel(timestamp: updated)
                        }
                    }.accessibilityIdentifier("driver_\(driver.id)")
                }
            }
            Section { SyncFooter() }
        }
        .navigationTitle("Dispatch")
        .accessibilityIdentifier("dispatcher_screen")
        .refreshable { await store.refresh(force: true) }
        .sheet(isPresented: $showingCreate) { NewDeliveryView() }
    }
}

struct DeliveryDetailView: View {
    @EnvironmentObject private var store: DeliveryStore
    let deliveryId: String
    @State private var suggestions: [Suggestion]?
    @State private var suggesting = false
    private var delivery: Delivery? { store.deliveries.first { $0.id == deliveryId } }
    var body: some View {
        Group {
            if let delivery {
                List {
                    Section {
                        HStack {
                            Text(delivery.shopName).font(.title2.bold())
                            Spacer()
                            Text(delivery.status.title).font(.subheadline.bold())
                                .accessibilityIdentifier("delivery_status")
                        }
                        DeliveryFacts(delivery: delivery)
                        if let driverId = delivery.driverId { LabeledContent("Driver", value: store.drivers.first { $0.id == driverId }?.name ?? driverId) }
                    }
                    if delivery.status == .pending || delivery.status == .assigned {
                        Section {
                            Button {
                                suggesting = true
                                Task {
                                    suggestions = await store.suggestions(for: delivery.id)
                                    suggesting = false
                                }
                            } label: {
                                Label(suggesting ? "Checking routes…" : "Suggest drivers", systemImage: "sparkles")
                            }
                            .disabled(suggesting || store.isMutating)
                            .accessibilityIdentifier("suggest_drivers")
                            if let suggestions {
                                if suggestions.isEmpty {
                                    Text("No feasible driver. Start a shift, opt into location sharing, and check capacity and delivery times.")
                                        .foregroundStyle(.secondary).accessibilityIdentifier("no_suggestions")
                                }
                                ForEach(suggestions) { suggestion in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(store.drivers.first { $0.id == suggestion.driverId }?.name ?? suggestion.driverId).font(.headline)
                                        Text("\(max(0, suggestion.incrementalTravelSeconds) / 60) extra travel minutes · \(suggestion.route.stops.count) stops")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        Button("Assign to \(store.drivers.first { $0.id == suggestion.driverId }?.name ?? suggestion.driverId)") {
                                            Task {
                                                if await store.assign(deliveryId: delivery.id, driverId: suggestion.driverId) { self.suggestions = nil }
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(store.isMutating)
                                        .accessibilityIdentifier("assign_\(suggestion.driverId)")
                                        ForEach(Array(suggestion.route.stops.enumerated()), id: \.element.id) { index, stop in
                                            Text("\(index + 1). \(stop.title) · \(stop.address) · \(stop.arrivalAt.epochDate.formatted(date: .omitted, time: .shortened))")
                                                .font(.caption)
                                        }
                                    }.padding(.vertical, 6)
                                }
                            }
                        } header: { Text("Assignment") } footer: {
                            Text("Suggestions include only active, located drivers whose full proposed route fits the constraints. Assignment is checked again by the server.")
                        }
                    }
                    Section { SyncFooter() }
                }
            } else { ContentUnavailableView("Delivery unavailable", systemImage: "shippingbox") }
        }
        .navigationTitle("Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(force: true) }
    }
}

struct NewDeliveryView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var shopName = "Pizzeria Pachino"
    @State private var pickupAddress = "Via Roma 1, Pachino"
    @State private var pickupLat = "36.7163"
    @State private var pickupLng = "15.0908"
    @State private var dropoffAddress = "Via Garibaldi 8, Pachino"
    @State private var dropoffLat = "36.7210"
    @State private var dropoffLng = "15.1000"
    @State private var readyAt = Date().addingTimeInterval(-60)
    @State private var deadlineAt = Date().addingTimeInterval(3600)
    @State private var loadUnits = 1
    @State private var maxRideMinutes = 30
    @State private var validationError: String?
    @FocusState private var focusedField: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Pickup") {
                    TextField("Shop name", text: $shopName).focused($focusedField, equals: "shop_name").accessibilityIdentifier("shop_name")
                    TextField("Pickup address", text: $pickupAddress).focused($focusedField, equals: "pickup_address").accessibilityIdentifier("pickup_address")
                    coordinateFields(lat: $pickupLat, lng: $pickupLng, prefix: "pickup")
                }
                Section("Drop-off") {
                    TextField("Drop-off address", text: $dropoffAddress).focused($focusedField, equals: "dropoff_address").accessibilityIdentifier("dropoff_address")
                    coordinateFields(lat: $dropoffLat, lng: $dropoffLng, prefix: "dropoff")
                }
                Section("Timing & load") {
                    DatePicker("Ready at", selection: $readyAt).accessibilityIdentifier("ready_at")
                    DatePicker("Deliver by", selection: $deadlineAt).accessibilityIdentifier("deadline_at")
                    Stepper("Load: \(loadUnits) units", value: $loadUnits, in: 1...8).accessibilityIdentifier("load_units")
                    Stepper("Max ride: \(maxRideMinutes) min", value: $maxRideMinutes, in: 1...120, step: 1)
                        .accessibilityIdentifier("max_ride_minutes")
                }
                Section {
                    Text("Sample addresses and coordinates are editable fixtures around Pachino, not verified customer destinations. Coordinates drive the route estimate; addresses are labels only. Times use the device’s local timezone.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let validationError { Text(validationError).foregroundStyle(.red).accessibilityIdentifier("form_error") }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New delivery")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }.accessibilityIdentifier("dismiss_keyboard")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isMutating).accessibilityIdentifier("cancel_delivery")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(store.isMutating).accessibilityIdentifier("submit_delivery")
                }
            }
        }.interactiveDismissDisabled(store.isMutating)
    }
    @ViewBuilder private func coordinateFields(lat: Binding<String>, lng: Binding<String>, prefix: String) -> some View {
        TextField("Latitude", text: lat).keyboardType(.numbersAndPunctuation).focused($focusedField, equals: "\(prefix)_lat").accessibilityIdentifier("\(prefix)_lat")
        TextField("Longitude", text: lng).keyboardType(.numbersAndPunctuation).focused($focusedField, equals: "\(prefix)_lng").accessibilityIdentifier("\(prefix)_lng")
    }
    private func create() async {
        guard let pLat = Double(pickupLat), let pLng = Double(pickupLng),
              let dLat = Double(dropoffLat), let dLng = Double(dropoffLng) else {
            validationError = "Coordinates must be decimal numbers, using a dot (for example 36.7163)."
            return
        }
        let draft = NewDelivery(
            shopName: shopName.trimmingCharacters(in: .whitespacesAndNewlines),
            pickupAddress: pickupAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            pickup: Coordinate(lat: pLat, lng: pLng),
            dropoffAddress: dropoffAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            dropoff: Coordinate(lat: dLat, lng: dLng),
            readyAt: Int(readyAt.timeIntervalSince1970), deadlineAt: Int(deadlineAt.timeIntervalSince1970),
            loadUnits: loadUnits, maxRideSeconds: maxRideMinutes * 60
        )
        validationError = draft.validationError
        guard validationError == nil else { return }
        if await store.create(draft) != nil { dismiss() }
    }
}
