import SwiftUI

struct DispatcherView: View {
    @EnvironmentObject private var store: DeliveryStore
    @State private var showingCreate = false
    @State private var showingInvite = false
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
                    Text(openDeliveries.isEmpty ? "Nessuna consegna in corso" : "\(openDeliveries.count) \(openDeliveries.count == 1 ? "consegna in corso" : "consegne in corso")")
                        .font(.title2.bold())
                    Button { showingCreate = true } label: {
                        Label("Nuova consegna", systemImage: "plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("create_delivery")
                    .disabled(store.pendingCreation != nil || store.legacyCreationNeedsReview || store.isMutating)
                    if store.legacyCreationNeedsReview {
                        Text("Verifica con il responsabile la consegna precedente prima di crearne un’altra. La squadra della richiesta salvata non è verificabile.")
                            .font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("legacy_creation_review")
                        if let legacy = store.legacyPendingCreation {
                            ExpandableDetails("Richiesta precedente", identifier: "legacy_creation_details") {
                                Text(legacy.delivery.shopName).font(.headline)
                                Text("Ritiro: \(legacy.delivery.pickupAddress)")
                                Text("Destinazione: \(legacy.delivery.dropoffAddress)")
                                Text(legacy.delivery.readyAt.map { "Disponibilità prevista: \($0.epochDate.italianDateTime)" } ?? "Disponibilità da definire")
                                Text("Riferimento richiesta: \(legacy.idempotencyKey)").font(.caption).textSelection(.enabled)
                                Button("Ho verificato la consegna") {
                                    legacyReview = store.prepareLegacyCreationReview()
                                    showingLegacyReview = legacyReview != nil
                                }.disabled(store.isMutating).accessibilityIdentifier("review_legacy_creation")
                            }
                        }
                    }
                    if store.pendingCreation != nil {
                        Text("Verifica la consegna in sospeso prima di crearne un’altra.").font(.subheadline)
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
                if !store.isDemo {
                    Button { showingInvite = true } label: {
                        Label("Invita un corriere", systemImage: "person.badge.plus")
                    }
                    .disabled(store.isMutating).accessibilityIdentifier("invite_driver")
                }
                NavigationLink { DispatcherDriversView() } label: {
                    Label("Driver · \(store.drivers.filter(\.active).count) in turno", systemImage: "bicycle")
                }.accessibilityIdentifier("dispatcher_drivers")
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
        .sheet(isPresented: $showingInvite) { CreateDriverInviteView() }
        .confirmationDialog("Rimuovere il recupero locale?", isPresented: $showingLegacyReview,
                            titleVisibility: .visible, presenting: legacyReview) { review in
            Button("Ho verificato: rimuovi il recupero", role: .destructive) {
                store.clearLegacyCreationAfterReview(review)
                legacyReview = nil
            }.accessibilityIdentifier("confirm_clear_legacy_creation")
            Button("Annulla", role: .cancel) { legacyReview = nil }
        } message: { _ in
            Text("Hai verificato con il responsabile se la consegna esiste? Rimuovi solo il recupero su questo iPhone. La consegna sul server resta; crearne un’altra potrebbe duplicarla.")
        }
    }
}

struct DeliveryDetailView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    let deliveryId: String
    var onAssigned: (() -> Void)? = nil
    @State private var suggestions: [Suggestion]?
    @State private var assignedRoute: DriverRoute?
    @State private var suggesting = false
    @State private var changingDriver = false
    @State private var showingEstimate = false
    @State private var estimateRevision: UInt64 = 0
    @State private var suggestionRequestID = UUID()
    private var delivery: Delivery? { store.deliveries.first { $0.id == deliveryId } }
    private var needsAssignment: Bool {
        delivery?.hasKnownReadiness == true && delivery?.status == .assigned && changingDriver
    }
    private var suggestionContext: String { "\(needsAssignment)-\(delivery?.readinessRevision ?? 0)" }
    private var assignedRouteContext: String {
        "\(delivery?.driverId ?? "")-\(delivery?.status.rawValue ?? "")-\(delivery?.readinessRevision ?? 0)-\(store.lastSyncedAt?.timeIntervalSince1970 ?? 0)"
    }

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
                    if delivery.canChangeReadiness {
                        Section("Disponibilità del cibo") {
                            if let pending = store.pendingReadiness(for: deliveryId) {
                                Text("Modifica non confermata. Verifica la stessa richiesta prima di cambiarla.")
                                    .font(.subheadline).foregroundStyle(.orange)
                                Button("Riprova la stessa modifica") {
                                    Task { _ = await store.setReadiness(deliveryId: deliveryId, readyInMinutes: pending.readyInMinutes, expectedRevision: pending.expectedRevision) }
                                }.accessibilityIdentifier("retry_readiness")
                            } else {
                                Button("Pronta ora") {
                                    Task { _ = await store.setReadiness(deliveryId: deliveryId, readyInMinutes: 0, expectedRevision: delivery.readinessRevision) }
                                }
                                .disabled(delivery.readinessState == .ready)
                                .accessibilityIdentifier("ready_now")
                                Button("Pronta tra X minuti") {
                                    estimateRevision = delivery.readinessRevision
                                    showingEstimate = true
                                }.accessibilityIdentifier("estimate_readiness")
                            }
                            if !delivery.hasKnownReadiness {
                                Text("Quando sarà pronta, l’app cercherà un corriere disponibile.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.disabled(store.isMutating)
                    }
                    if delivery.status == .pending, delivery.hasKnownReadiness {
                        Section {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let assignmentState = Int(context.date.timeIntervalSince1970) < delivery.readyAt
                                    ? "Assegnazione prevista quando pronta" : "In attesa di un corriere"
                                Label(assignmentState, systemImage: "bicycle")
                                    // Keep the changing state on one semantic row; a Label's
                                    // SF Symbol must not inherit the query identifier.
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Assegnazione")
                                    .accessibilityValue(assignmentState)
                                    .accessibilityIdentifier("automatic_assignment_status")
                            }
                            if let reason = delivery.localizedDispatchWaitingReason {
                                Text(reason).font(.subheadline).foregroundStyle(.orange)
                                    .accessibilityIdentifier("dispatch_waiting_reason")
                            }
                            if delivery.readinessRevision == 0 {
                                Text("Conferma la disponibilità per avviare l’assegnazione automatica.")
                                    .font(.subheadline).foregroundStyle(.orange)
                            }
                        }
                    }
                    if needsAssignment {
                        Section("Cambia corriere") {
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
                                    Text("Chiedi a un corriere di avviare il turno, poi riprova.")
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
                            if delivery.status != .delivered {
                                if let assignedRoute {
                                    routeSummary(assignedRoute)
                                } else {
                                    Text("Orari del percorso da verificare").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            if delivery.status == .assigned {
                                Button("Cambia corriere") { changingDriver = true }
                                    .accessibilityIdentifier("change_driver")
                            }
                        }
                    }
                    if store.role == .dispatcher, store.principal?.supports(.dispatcher) == true {
                        Section {
                            Button("Elimina consegna", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                            .disabled(store.isMutating)
                            .accessibilityIdentifier("delete_delivery")
                        }
                    }
                    SyncFooter()
                }
                .task(id: assignedRouteContext) {
                    assignedRoute = nil
                    let planned = await store.assignedRoute(for: deliveryId)
                    guard !Task.isCancelled else { return }
                    assignedRoute = planned
                }
                .task(id: suggestionContext) {
                    if needsAssignment { await loadSuggestions() }
                    else { suggestionRequestID = UUID(); suggestions = nil; suggesting = false }
                }
            } else { ContentUnavailableView("Consegna non disponibile", systemImage: "shippingbox") }
        }
        .navigationTitle("Consegna")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Eliminare definitivamente questa consegna?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Elimina definitivamente", role: .destructive) {
                Task {
                    if await store.deleteDelivery(deliveryId: deliveryId) { dismiss() }
                }
            }.accessibilityIdentifier("confirm_delete_delivery")
            Button("Annulla", role: .cancel) { }.accessibilityIdentifier("cancel_delete_delivery")
        } message: {
            Text("\(delivery?.shopName ?? "Consegna") • \(delivery?.status.title ?? "Stato da verificare"). La consegna verrà rimossa anche dallo storico e dal percorso del corriere. L’operazione non è annullabile. Se è già assegnata o ritirata, avvisa il corriere e concorda come gestire il cibo prima di eliminarla.")
        }
        .sheet(isPresented: $showingEstimate) {
            ReadinessEstimateView(deliveryId: deliveryId, expectedRevision: estimateRevision)
        }
        .refreshable {
            await store.refresh(force: true)
            if needsAssignment { await loadSuggestions() }
        }
    }

    private func routeSummary(_ route: DriverRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if route.estimatesAvailable {
                if let pickup = route.stops.first(where: { $0.deliveryId == deliveryId && $0.kind == .pickup }) {
                    Text("Ritiro previsto alle \(pickup.arrivalAt.epochDate.italianTime)")
                        .accessibilityIdentifier("assigned_pickup_eta")
                }
                if let dropoff = route.stops.first(where: { $0.deliveryId == deliveryId && $0.kind == .dropoff }) {
                    Text("Consegna prevista alle \(dropoff.arrivalAt.epochDate.italianTime)")
                }
            } else {
                Text(route.unavailableEstimateMessage)
                    .foregroundStyle(.orange).accessibilityIdentifier("route_estimates_unavailable")
            }
            RouteTravelNotice(route: route)
            ForEach(route.localizedNotices, id: \.self) { notice in
                Label(notice, systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
            }
            ForEach(route.localizedWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }.font(.subheadline)
    }

    private func assignment(_ suggestion: Suggestion, recommended: Bool) -> some View {
        let name = store.drivers.first { $0.id == suggestion.driverId }?.displayName ?? "Corriere"
        let pickup = suggestion.route.stops.first { $0.deliveryId == deliveryId && $0.kind == .pickup }
        let dropoff = suggestion.route.stops.first { $0.deliveryId == deliveryId && $0.kind == .dropoff }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(name, systemImage: "bicycle").font(.headline)
                Spacer()
                if recommended { Text("Consigliato").font(.caption).foregroundStyle(.secondary) }
            }
            if suggestion.route.estimatesAvailable, let pickup {
                Text("Ritiro previsto alle \(pickup.arrivalAt.epochDate.italianTime)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pickup_eta_\(suggestion.driverId)")
            }
            if !suggestion.route.estimatesAvailable {
                Text(suggestion.route.unavailableEstimateMessage).font(.subheadline).foregroundStyle(.orange)
            }
            RouteTravelNotice(route: suggestion.route)
            ForEach(suggestion.route.localizedWarnings, id: \.self) { warning in
                Text(warning).font(.footnote).foregroundStyle(.orange)
            }
            ForEach(suggestion.route.localizedNotices, id: \.self) { notice in
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if suggestion.route.estimatesAvailable, let dropoff {
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
        guard needsAssignment else { return }
        let request = UUID()
        suggestionRequestID = request
        suggesting = true
        suggestions = nil
        let fetched = await store.suggestions(for: deliveryId)
        guard suggestionRequestID == request, !Task.isCancelled else { return }
        suggestions = fetched
        suggesting = false
    }
}

struct NewDeliveryView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pickup: Restaurant?
    @State private var dropoff: DeliveryPlace?
    @State private var selectingPickup = false
    @State private var selectingDropoff = false
    @State private var customTiming = false
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
                            placeButton(title: "Ristorante", place: pickup.flatMap(DeliveryPlace.init(restaurant:)), icon: "storefront", identifier: "choose_pickup") { selectingPickup = true }
                            placeButton(title: "Destinazione", place: dropoff, icon: "mappin.and.ellipse", identifier: "choose_dropoff") { selectingDropoff = true }
                        }
                        Section {
                            ExpandableDetails(customTiming ? "Consegna entro le \(deadlineAt.italianTime)" : "Consegna entro un’ora", systemImage: "clock", identifier: "delivery_timing") {
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
                                    Text(creationUncertain ? "Riprova la stessa creazione" : (submitting ? "Creazione…" : "Crea consegna"))
                                }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled((!creationUncertain && (pickup?.hasGooglePlace != true || dropoff == nil)) || submitting || store.isMutating)
                            .accessibilityIdentifier("submit_delivery")
                            Text(creationUncertain ? "Puoi chiudere e riprovare senza creare duplicati." : "Potrai indicare dopo quando il cibo è pronto")
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
                RestaurantPickerView { pickup = $0 }
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
        guard !submitting, let pickup, pickup.hasGooglePlace, let dropoff else { return }
        submitting = true
        defer { submitting = false }
        let now = Date()
        let draft = NewDelivery(
            shopName: pickup.name, pickupAddress: pickup.address,
            dropoffAddress: dropoff.address,
            readyAt: nil,
            deadlineAt: Int((customTiming ? deadlineAt : now.addingTimeInterval(3600)).timeIntervalSince1970),
            loadUnits: 1, maxRideSeconds: 1800, restaurantId: pickup.id,
            pickupGooglePlaceId: pickup.googlePlaceId, dropoffGooglePlaceId: dropoff.googlePlaceId
        )
        validationError = draft.validationError
        guard validationError == nil else { return }
        if let created = await store.create(draft) { createdId = created.id }
        else if store.createOutcomeUncertain { creationUncertain = true }
    }
}


private struct ReadinessEstimateView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    let deliveryId: String
    let expectedRevision: UInt64
    @State private var minutes = 10
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Stepper("Pronta tra \(minutes) minuti", value: $minutes, in: 1...120)
                    .accessibilityIdentifier("readiness_minutes")
                Text("Potrai confermare «Pronta ora» in seguito.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Salva previsione") {
                    guard !submitting else { return }
                    submitting = true
                    Task {
                        _ = await store.setReadiness(deliveryId: deliveryId, readyInMinutes: minutes, expectedRevision: expectedRevision)
                        submitting = false
                        // A lost response leaves an exact-request retry on the delivery screen.
                        dismiss()
                    }
                }.accessibilityIdentifier("save_readiness")
            }
            .disabled(submitting || store.isMutating)
            .navigationTitle("Quando sarà pronta?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                        .disabled(submitting || store.isMutating)
                        .accessibilityIdentifier("cancel_readiness")
                }
            }
        }.interactiveDismissDisabled(submitting || store.isMutating)
    }
}

private struct RestaurantPickerView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    let select: (Restaurant) -> Void
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if let pending = store.pendingRestaurant {
                    Section {
                        Text("Salvataggio di \(pending.restaurant.name) da verificare.")
                        Button("Riprova lo stesso salvataggio") {
                            Task {
                                if let restaurant = await store.createRestaurant(pending.restaurant) {
                                    if restaurant.hasGooglePlace { select(restaurant); dismiss() }
                                    else { showingAdd = true }
                                }
                            }
                        }.disabled(store.isMutating).accessibilityIdentifier("retry_restaurant")
                    }
                }
                Section {
                    ForEach(store.restaurants) { restaurant in
                        Button {
                            if restaurant.hasGooglePlace { select(restaurant); dismiss() }
                            else { showingAdd = true }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(restaurant.name).font(.headline)
                                Text(restaurant.address).font(.subheadline).foregroundStyle(.secondary)
                                if !restaurant.hasGooglePlace {
                                    Text("Indirizzo precedente: cerca e salva di nuovo su Google Maps")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }.foregroundStyle(.primary)
                        }.accessibilityIdentifier("restaurant_\(restaurant.id)")
                    }
                    if store.loadingRestaurants { ProgressView("Caricamento ristoranti…") }
                    else if let error = store.restaurantLoadError {
                        Text(error).foregroundStyle(.orange)
                        Button("Riprova") { Task { await store.loadRestaurants() } }
                            .accessibilityIdentifier("reload_restaurants")
                    } else if store.restaurants.isEmpty {
                        Text("Aggiungi un ristorante per iniziare.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button("Aggiungi ristorante", systemImage: "plus") { showingAdd = true }
                        .disabled(store.isMutating || store.pendingRestaurant != nil)
                        .accessibilityIdentifier("add_restaurant")
                }
            }
            .navigationTitle("Ristoranti")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }.disabled(store.isMutating)
                        .accessibilityIdentifier("cancel_restaurant_picker")
                }
            }
            .task { await store.loadRestaurants() }
            .refreshable { await store.loadRestaurants() }
            .sheet(isPresented: $showingAdd) {
                NewRestaurantView { restaurant in
                    select(restaurant)
                    showingAdd = false
                    dismiss()
                }
            }
        }.interactiveDismissDisabled(store.isMutating)
    }
}

private struct NewRestaurantView: View {
    @EnvironmentObject private var store: DeliveryStore
    @Environment(\.dismiss) private var dismiss
    let select: (Restaurant) -> Void
    @State private var place: DeliveryPlace?
    @State private var name = ""
    @State private var searching = false
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Button { searching = true } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(place?.address ?? "Scegli l’indirizzo del ristorante")
                    }
                }.disabled(store.pendingRestaurant != nil).accessibilityIdentifier("restaurant_address")
                TextField("Nome del ristorante", text: $name)
                    .disabled(store.pendingRestaurant != nil).accessibilityIdentifier("restaurant_name")
                Button(store.pendingRestaurant == nil ? "Salva ristorante" : "Riprova lo stesso salvataggio") {
                    guard !submitting, let place else { return }
                    submitting = true
                    let draft = store.pendingRestaurant?.restaurant ?? NewRestaurant(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: place.address,
                        googlePlaceId: place.googlePlaceId)
                    Task {
                        if let restaurant = await store.createRestaurant(draft) { select(restaurant) }
                        submitting = false
                    }
                }
                .disabled(place == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting || store.isMutating)
                .accessibilityIdentifier("save_restaurant")
            }
            .disabled(submitting || store.isMutating)
            .navigationTitle("Nuovo ristorante")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }.disabled(submitting || store.isMutating)
                        .accessibilityIdentifier("cancel_restaurant")
                }
            }
            .sheet(isPresented: $searching) {
                PlaceSearchView(title: "Ristorante", isUITesting: store.isUITesting) { selected in
                    // The picker carries address-search text, not the restaurant's name.
                    // Keep the independently entered name when selecting or changing an address.
                    place = selected
                }
            }
        }.interactiveDismissDisabled(submitting || store.isMutating)
    }
}

