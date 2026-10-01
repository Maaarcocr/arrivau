import SwiftUI

struct DispatcherView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var showingCreate = false
    private var openDeliveries: [Delivery] {
        store.deliveries.filter { $0.status != .delivered }.sorted {
            if ($0.status == .pending) != ($1.status == .pending) { return $0.status == .pending }
            return $0.deadlineAt < $1.deadlineAt
        }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(openDeliveries.isEmpty ? "Ready for the next delivery" : "\(openDeliveries.count) deliveries in progress")
                        .font(.title2.bold())
                    Button { showingCreate = true } label: {
                        Label("New delivery", systemImage: "plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("create_delivery")
                }.padding(.vertical, 6)
            }
            if !openDeliveries.isEmpty {
                Section("In progress") {
                    ForEach(openDeliveries) { delivery in
                        NavigationLink { DeliveryDetailView(deliveryId: delivery.id) } label: {
                            DeliveryRow(delivery: delivery)
                        }.accessibilityIdentifier("delivery_\(delivery.id)")
                    }
                }
            }
            Section {
                DisclosureGroup("Drivers · \(store.drivers.filter(\.active).count) on shift") {
                    ForEach(store.drivers) { driver in
                        HStack {
                            Label(driver.name, systemImage: "bicycle")
                            Spacer()
                            Text(driver.active ? "On shift" : "Off shift")
                                .font(.subheadline).foregroundStyle(driver.active ? .green : .secondary)
                        }.accessibilityIdentifier("driver_\(driver.id)")
                    }
                }.accessibilityIdentifier("drivers_details")
                if store.deliveries.contains(where: { $0.status == .delivered }) {
                    DisclosureGroup("Completed") {
                        ForEach(store.deliveries.filter { $0.status == .delivered }.sorted { $0.createdAt > $1.createdAt }) { delivery in
                            NavigationLink { DeliveryDetailView(deliveryId: delivery.id) } label: {
                                DeliveryRow(delivery: delivery)
                            }.accessibilityIdentifier("delivery_\(delivery.id)")
                        }
                    }.accessibilityIdentifier("completed_deliveries")
                }
            }
            SyncFooter()
        }
        .navigationTitle("Deliveries")
        .accessibilityIdentifier("dispatcher_screen")
        .refreshable { await store.refresh(force: true) }
        .sheet(isPresented: $showingCreate) { NewDeliveryView() }
    }
}

struct DeliveryDetailView: View {
    @EnvironmentObject private var store: DeliveryStore
    let deliveryId: String
    var onAssigned: (() -> Void)? = nil
    @State private var suggestions: [Suggestion]?
    @State private var suggesting = false
    @State private var changingDriver = false
    private var delivery: Delivery? { store.deliveries.first { $0.id == deliveryId } }
    private var needsAssignment: Bool { delivery?.status == .pending || (delivery?.status == .assigned && changingDriver) }

    var body: some View {
        Group {
            if let delivery {
                List {
                    Section {
                        HStack {
                            Text(delivery.shopName).font(.title2.bold())
                            Spacer()
                            Text(delivery.status == .pending ? "Needs driver" : delivery.status.title)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("delivery_status")
                        }
                        DeliveryFacts(delivery: delivery)
                    }
                    if needsAssignment {
                        Section("Choose a driver") {
                            if suggesting { ProgressView("Finding a driver…") }
                            else if let suggestions {
                                if let recommended = suggestions.first {
                                    assignment(recommended, recommended: true)
                                    if suggestions.count > 1 {
                                        DisclosureGroup("Other drivers") {
                                            ForEach(Array(suggestions.dropFirst())) { assignment($0, recommended: false) }
                                        }
                                    }
                                } else {
                                    Label("No driver available yet", systemImage: "bicycle")
                                        .accessibilityIdentifier("no_suggestions")
                                    Text("Ask a driver to start their shift and share their location, then try again.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Button("Try again") { Task { await loadSuggestions() } }
                                        .accessibilityIdentifier("retry_suggestions")
                                }
                            } else {
                                Button("Try finding a driver again") { Task { await loadSuggestions() } }
                                    .accessibilityIdentifier("retry_suggestions")
                            }
                        }
                    } else if let driverId = delivery.driverId {
                        Section {
                            Label(store.drivers.first { $0.id == driverId }?.name ?? "Assigned driver", systemImage: "bicycle")
                            if delivery.status == .assigned {
                                Button("Change driver") { changingDriver = true }
                                    .accessibilityIdentifier("change_driver")
                            }
                        }
                    }
                    SyncFooter()
                }
                .task(id: needsAssignment) { if needsAssignment { await loadSuggestions() } }
            } else { ContentUnavailableView("Delivery unavailable", systemImage: "shippingbox") }
        }
        .navigationTitle("Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(force: true)
            if needsAssignment { await loadSuggestions() }
        }
    }

    private func assignment(_ suggestion: Suggestion, recommended: Bool) -> some View {
        let name = store.drivers.first { $0.id == suggestion.driverId }?.name ?? "Driver"
        let dropoff = suggestion.route.stops.first { $0.deliveryId == deliveryId && $0.kind == .dropoff }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(name, systemImage: "bicycle").font(.headline)
                Spacer()
                if recommended { Text("Suggested").font(.caption).foregroundStyle(.secondary) }
            }
            if let dropoff {
                Text("Estimated delivery \(dropoff.arrivalAt.epochDate.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    if await store.assign(deliveryId: deliveryId, driverId: suggestion.driverId) {
                        changingDriver = false
                        suggestions = nil
                        onAssigned?()
                    } else {
                        await loadSuggestions()
                    }
                }
            } label: {
                Text("Assign to \(name)").frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isMutating || suggesting)
            .accessibilityIdentifier("assign_\(suggestion.driverId)")
        }.padding(.vertical, 6)
    }

    private func loadSuggestions() async {
        guard !suggesting else { return }
        suggesting = true
        suggestions = await store.suggestions(for: deliveryId)
        suggesting = false
    }
}

struct NewDeliveryView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pickup: DeliveryPlace?
    @State private var dropoff: DeliveryPlace?
    @State private var selectingPickup = false
    @State private var selectingDropoff = false
    @State private var customTiming = false
    @State private var timingExpanded = false
    @State private var readyAt = Date()
    @State private var deadlineAt = Date().addingTimeInterval(3600)
    @State private var validationError: String?
    @State private var createdId: String?
    @State private var submitting = false
    @State private var creationUncertain = false

    var body: some View {
        NavigationStack {
            Group {
                if let createdId {
                    DeliveryDetailView(deliveryId: createdId, onAssigned: { dismiss() })
                } else {
                    Form {
                        Section {
                            placeButton(title: "Pickup", place: pickup, icon: "storefront", identifier: "choose_pickup") { selectingPickup = true }
                            placeButton(title: "Deliver to", place: dropoff, icon: "mappin.and.ellipse", identifier: "choose_dropoff") { selectingDropoff = true }
                        }
                        Section {
                            DisclosureGroup(isExpanded: $timingExpanded) {
                                DatePicker("Ready at", selection: $readyAt).accessibilityIdentifier("ready_at")
                                    .onChange(of: readyAt) { _, _ in customTiming = true }
                                DatePicker("Deliver by", selection: $deadlineAt).accessibilityIdentifier("deadline_at")
                                    .onChange(of: deadlineAt) { _, _ in customTiming = true }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Timing")
                                    Text(customTiming ? "Ready \(readyAt.formatted(date: .omitted, time: .shortened)) · due \(deadlineAt.formatted(date: .omitted, time: .shortened))" : "Ready now · deliver within an hour")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("delivery_timing")
                        }
                        if let validationError {
                            Section { Text(validationError).foregroundStyle(.red).accessibilityIdentifier("form_error") }
                        }
                    }
                    .navigationTitle("New delivery")
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 8) {
                            Button {
                                if creationUncertain { dismiss() }
                                else { Task { await create() } }
                            } label: {
                                HStack {
                                    if submitting { ProgressView().tint(.white) }
                                    Text(creationUncertain ? "Check deliveries" : (submitting ? "Creating…" : "Continue to driver"))
                                }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pickup == nil || dropoff == nil || submitting || store.isMutating)
                            .accessibilityIdentifier("submit_delivery")
                            Text(creationUncertain ? "Check whether this delivery was saved before trying again" : "Creates the delivery, then suggests a driver")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding().background(.regularMaterial)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdId == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(submitting || store.isMutating)
                        .accessibilityIdentifier(createdId == nil ? "cancel_delivery" : "done_delivery")
                }
            }
            .sheet(isPresented: $selectingPickup) {
                PlaceSearchView(title: "Pickup", isUITesting: store.isUITesting) { pickup = $0 }
            }
            .sheet(isPresented: $selectingDropoff) {
                PlaceSearchView(title: "Deliver to", isUITesting: store.isUITesting) { dropoff = $0 }
            }
        }.interactiveDismissDisabled(submitting || store.isMutating)
    }

    private func placeButton(title: String, place: DeliveryPlace?, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(.orange).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(place?.name ?? "Choose an address").font(.headline).foregroundStyle(.primary)
                    if let place { Text(place.address).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 8)
        }.accessibilityIdentifier(identifier)
    }

    private func create() async {
        guard !submitting, let pickup, let dropoff else { return }
        submitting = true
        defer { submitting = false }
        let now = Date()
        let draft = NewDelivery(
            shopName: pickup.name, pickupAddress: pickup.address, pickup: pickup.coordinate,
            dropoffAddress: dropoff.address, dropoff: dropoff.coordinate,
            readyAt: Int((customTiming ? readyAt : now).timeIntervalSince1970),
            deadlineAt: Int((customTiming ? deadlineAt : now.addingTimeInterval(3600)).timeIntervalSince1970),
            loadUnits: 1, maxRideSeconds: 1800
        )
        validationError = draft.validationError
        guard validationError == nil else { return }
        if let created = await store.create(draft) { createdId = created.id }
        else if store.createOutcomeUncertain { creationUncertain = true }
    }
}
