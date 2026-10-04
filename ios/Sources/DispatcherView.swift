import SwiftUI

struct DispatcherView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var showingCreate = false
    @State private var showingLegacyReview = false
    @State private var legacyReview: DeliveryStore.LegacyCreationReview?
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
                    Text(openDeliveries.isEmpty ? "Tutto pronto per la prossima consegna" : "\(openDeliveries.count) \(openDeliveries.count == 1 ? "consegna in corso" : "consegne in corso")")
                        .font(.title2.bold())
                    Button { showingCreate = true } label: {
                        Label("Nuova consegna", systemImage: "plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("create_delivery")
                    .disabled(store.pendingCreation != nil || store.legacyCreationNeedsReview || store.isMutating)
                    if store.legacyCreationNeedsReview {
                        Text("C’è una richiesta non confermata della configurazione precedente, senza una squadra verificabile. Per evitare duplicati o invii alla squadra sbagliata, le nuove creazioni sono sospese. Verifica con il responsabile sul vecchio server se la consegna esiste, poi rimuovi soltanto questo recupero locale.")
                            .font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("legacy_creation_review")
                        if let legacy = store.legacyPendingCreation {
                            ExpandableDetails("Richiesta precedente", identifier: "legacy_creation_details") {
                                Text(legacy.delivery.shopName).font(.headline)
                                Text("Ritiro: \(legacy.delivery.pickupAddress)")
                                Text("Destinazione: \(legacy.delivery.dropoffAddress)")
                                Text("Pronta: \(legacy.delivery.readyAt.epochDate.italianDateTime)")
                                Text("Riferimento richiesta: \(legacy.idempotencyKey)").font(.caption).textSelection(.enabled)
                                Button("Ho verificato la consegna") {
                                    legacyReview = store.prepareLegacyCreationReview()
                                    showingLegacyReview = legacyReview != nil
                                }.disabled(store.isMutating).accessibilityIdentifier("review_legacy_creation")
                            }
                        }
                    }
                    if store.pendingCreation != nil {
                        Text("C’è una creazione da verificare. Riprova la stessa richiesta prima di crearne un’altra.").font(.subheadline)
                        Button("Verifica la creazione in sospeso") { Task { _ = await store.retryPendingCreation() } }
                            .disabled(store.isMutating || store.legacyCreationNeedsReview).accessibilityIdentifier("retry_pending_creation")
                    }
                }.padding(.vertical, 6)
            }
            if !openDeliveries.isEmpty {
                Section("In corso") {
                    ForEach(openDeliveries) { delivery in
                        NavigationLink { DeliveryDetailView(deliveryId: delivery.id) } label: {
                            DeliveryRow(delivery: delivery)
                        }.accessibilityIdentifier("delivery_\(delivery.id)")
                    }
                }
            }
            Section {
                ExpandableDetails("Corrieri · \(store.drivers.filter(\.active).count) in turno", identifier: "drivers_details") {
                    ForEach(store.drivers) { driver in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(driver.displayName, systemImage: "bicycle")
                                Spacer()
                                Text(driver.active ? "In turno" : "Fuori turno")
                                    .font(.subheadline).foregroundStyle(driver.active ? .green : .secondary)
                            }
                            if let timestamp = driver.locationUpdatedAt {
                                LocationAgeLabel(timestamp: timestamp, accessibilityID: "driver_location_age_\(driver.id)")
                            } else {
                                Text("Posizione non disponibile").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("driver_location_age_\(driver.id)")
                            }
                        }.accessibilityIdentifier("driver_\(driver.id)")
                    }
                }
                if store.deliveries.contains(where: { $0.status == .delivered }) {
                    ExpandableDetails("Completate", identifier: "completed_deliveries") {
                        ForEach(store.deliveries.filter { $0.status == .delivered }.sorted { $0.createdAt > $1.createdAt }) { delivery in
                            NavigationLink { DeliveryDetailView(deliveryId: delivery.id) } label: {
                                DeliveryRow(delivery: delivery)
                            }.accessibilityIdentifier("delivery_\(delivery.id)")
                        }
                    }
                }
            }
            SyncFooter()
        }
        .navigationTitle("Consegne")
        .accessibilityIdentifier("dispatcher_screen")
        .refreshable { await store.refresh(force: true) }
        .sheet(isPresented: $showingCreate) { NewDeliveryView() }
        .confirmationDialog("Rimuovere il recupero locale?", isPresented: $showingLegacyReview,
                            titleVisibility: .visible, presenting: legacyReview) { review in
            Button("Ho verificato: rimuovi il recupero", role: .destructive) {
                store.clearLegacyCreationAfterReview(review)
                legacyReview = nil
            }.accessibilityIdentifier("confirm_clear_legacy_creation")
            Button("Annulla", role: .cancel) { legacyReview = nil }
        } message: { _ in
            Text("Conferma solo dopo aver verificato con il responsabile sul vecchio server se la consegna esiste. Verrà rimossa soltanto questa richiesta salvata su questo iPhone; nessuna consegna sul server viene cancellata. Una nuova creazione potrebbe duplicare una consegna già esistente.")
        }
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
                            Text(delivery.status == .pending ? "Da assegnare" : delivery.status.title)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("delivery_status")
                        }
                        DeliveryFacts(delivery: delivery)
                    }
                    if needsAssignment {
                        Section("Scegli un corriere") {
                            if suggesting { ProgressView("Ricerca di un corriere…") }
                            else if let suggestions {
                                if let recommended = suggestions.first {
                                    assignment(recommended, recommended: true)
                                    if suggestions.count > 1 {
                                        ExpandableDetails("Altri corrieri", identifier: "other_drivers") {
                                            ForEach(Array(suggestions.dropFirst())) { assignment($0, recommended: false) }
                                        }
                                    }
                                } else {
                                    Label("Nessun corriere disponibile", systemImage: "bicycle")
                                        .accessibilityIdentifier("no_suggestions")
                                    Text("Chiedi a un corriere di iniziare il turno e condividere la posizione, poi riprova.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Button("Riprova") { Task { await loadSuggestions() } }
                                        .accessibilityIdentifier("retry_suggestions")
                                }
                            } else {
                                Button("Cerca di nuovo un corriere") { Task { await loadSuggestions() } }
                                    .accessibilityIdentifier("retry_suggestions")
                            }
                        }
                    } else if let driverId = delivery.driverId {
                        Section {
                            Label(store.drivers.first { $0.id == driverId }?.displayName ?? "Corriere assegnato", systemImage: "bicycle")
                            if delivery.status == .assigned {
                                Button("Cambia corriere") { changingDriver = true }
                                    .accessibilityIdentifier("change_driver")
                            }
                        }
                    }
                    SyncFooter()
                }
                .task(id: needsAssignment) { if needsAssignment { await loadSuggestions() } }
            } else { ContentUnavailableView("Consegna non disponibile", systemImage: "shippingbox") }
        }
        .navigationTitle("Consegna")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(force: true)
            if needsAssignment { await loadSuggestions() }
        }
    }

    private func assignment(_ suggestion: Suggestion, recommended: Bool) -> some View {
        let name = store.drivers.first { $0.id == suggestion.driverId }?.displayName ?? "Corriere"
        let dropoff = suggestion.route.stops.first { $0.deliveryId == deliveryId && $0.kind == .dropoff }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(name, systemImage: "bicycle").font(.headline)
                Spacer()
                if recommended { Text("Consigliato").font(.caption).foregroundStyle(.secondary) }
            }
            if let dropoff {
                Text("Consegna prevista alle \(dropoff.arrivalAt.epochDate.italianTime)")
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
                Text("Assegna a \(name)").frame(maxWidth: .infinity).padding(.vertical, 5)
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
                            placeButton(title: "Ritiro", place: pickup, icon: "storefront", identifier: "choose_pickup") { selectingPickup = true }
                            placeButton(title: "Destinazione", place: dropoff, icon: "mappin.and.ellipse", identifier: "choose_dropoff") { selectingDropoff = true }
                        }
                        Section {
                            ExpandableDetails(customTiming ? "Pronta alle \(readyAt.italianTime) · entro le \(deadlineAt.italianTime)" : "Pronta ora · consegna entro un’ora", systemImage: "clock", identifier: "delivery_timing") {
                                DatePicker("Pronta alle", selection: $readyAt).accessibilityIdentifier("ready_at")
                                    .onChange(of: readyAt) { _, _ in customTiming = true }
                                DatePicker("Da consegnare entro", selection: $deadlineAt).accessibilityIdentifier("deadline_at")
                                    .onChange(of: deadlineAt) { _, _ in customTiming = true }
                            }
                        }
                        if let validationError {
                            Section { Text(validationError).foregroundStyle(.red).accessibilityIdentifier("form_error") }
                        }
                    }
                    .disabled(creationUncertain || submitting)
                    .navigationTitle("Nuova consegna")
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 8) {
                            Button {
                                Task {
                                    if creationUncertain { await retryCreation() }
                                    else { await create() }
                                }
                            } label: {
                                HStack {
                                    if submitting { ProgressView().tint(.white) }
                                    Text(creationUncertain ? "Riprova la stessa creazione" : (submitting ? "Creazione…" : "Scegli il corriere"))
                                }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pickup == nil || dropoff == nil || submitting || store.isMutating)
                            .accessibilityIdentifier("submit_delivery")
                            Text(creationUncertain ? "La stessa richiesta evita duplicati. Puoi chiudere e verificarla più tardi." : "Crea la consegna e suggerisce un corriere")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding().background(.regularMaterial)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdId == nil ? "Annulla" : "Fine") { dismiss() }
                        .disabled(submitting || store.isMutating)
                        .accessibilityIdentifier(createdId == nil ? "cancel_delivery" : "done_delivery")
                }
            }
            .sheet(isPresented: $selectingPickup) {
                PlaceSearchView(title: "Ritiro", isUITesting: store.isUITesting) { pickup = $0 }
            }
            .sheet(isPresented: $selectingDropoff) {
                PlaceSearchView(title: "Destinazione", isUITesting: store.isUITesting) { dropoff = $0 }
            }
        }.interactiveDismissDisabled(submitting || store.isMutating)
    }

    private func placeButton(title: String, place: DeliveryPlace?, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(.orange).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(place?.name ?? "Scegli un indirizzo").font(.headline).foregroundStyle(Color.primary)
                    if let place { Text(place.address).font(.subheadline).foregroundStyle(Color.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 8)
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }

    private func retryCreation() async {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }
        if let created = await store.retryPendingCreation() { createdId = created.id; creationUncertain = false }
        else { creationUncertain = store.pendingCreation != nil }
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

