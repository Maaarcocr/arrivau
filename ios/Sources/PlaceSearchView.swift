import SwiftUI
import GooglePlaces

/// Only app-owned text and the durable provider identifier leave the picker.
/// Prediction names/addresses and Details coordinates are deliberately not retained.
struct DeliveryPlace: Identifiable, Equatable {
    let name: String
    let address: String
    let googlePlaceId: String
    var id: String { googlePlaceId }

    init(userInput: String, googlePlaceId: String) {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        name = text
        address = text
        self.googlePlaceId = googlePlaceId
    }

    init?(restaurant: Restaurant) {
        guard restaurant.hasGooglePlace, let placeID = restaurant.googlePlaceId else { return nil }
        name = restaurant.name
        address = restaurant.address
        googlePlaceId = placeID
    }

    #if DEBUG
    /// These labels belong to our isolated demo fixtures, not to Google.
    fileprivate init(fixtureName: String, fixtureAddress: String, googlePlaceId: String) {
        name = fixtureName; address = fixtureAddress; self.googlePlaceId = googlePlaceId
    }
    #endif
}

/// Transient Google display content. Never Codable or included in a saved request.
struct PlacePrediction: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}

enum PlaceSearchError: Error, LocalizedError {
    case notConfigured, searchFailed, invalidPlace
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Ricerca indirizzi non configurata. Chiedi al responsabile di attivare Google Places."
        case .searchFailed: return "Ricerca su Google Maps non riuscita. Controlla la connessione e riprova."
        case .invalidPlace: return "Questo indirizzo non ha un punto di consegna disponibile. Scegli un altro risultato."
        }
    }
}

@MainActor
protocol PlaceSearching: AnyObject {
    func predictions(for query: String) async throws -> [PlacePrediction]
    func resolve(_ prediction: PlacePrediction, userInput: String) async throws -> DeliveryPlace
    func resetSession()
}

@MainActor
final class GooglePlaceSearchService: PlaceSearching {
    private static var configured = false
    private var sessionToken: GMSAutocompleteSessionToken?
    /// ID + coordinate is an Essentials request. Never request names/addresses/Pro fields.
    static let detailProperties = [GMSPlaceProperty.placeID, GMSPlaceProperty.coordinate].map(\.rawValue)

    private func client() throws -> GMSPlacesClient {
        if !Self.configured {
            let key = (Bundle.main.object(forInfoDictionaryKey: "ARRIVAU_GOOGLE_MAPS_API_KEY") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("$("), GMSPlacesClient.provideAPIKey(key) else {
                throw PlaceSearchError.notConfigured
            }
            Self.configured = true
        }
        return GMSPlacesClient.shared()
    }

    func predictions(for query: String) async throws -> [PlacePrediction] {
        let client = try client()
        if sessionToken == nil { sessionToken = GMSAutocompleteSessionToken() }
        let filter = GMSAutocompleteFilter()
        filter.locationBias = GMSPlaceCircularLocationOption(Coordinate.pachino.clCoordinate, 15_000)
        let request = GMSAutocompleteRequest(query: query)
        request.filter = filter
        request.sessionToken = sessionToken
        return try await withCheckedThrowingContinuation { continuation in
            client.fetchAutocompleteSuggestions(from: request) { suggestions, error in
                guard error == nil, let suggestions else {
                    continuation.resume(throwing: PlaceSearchError.searchFailed); return
                }
                continuation.resume(returning: suggestions.compactMap { suggestion in
                    guard let place = suggestion.placeSuggestion else { return nil }
                    return PlacePrediction(id: place.placeID, title: place.attributedPrimaryText.string,
                                           subtitle: place.attributedSecondaryText?.string ?? "")
                })
            }
        }
    }

    func resolve(_ prediction: PlacePrediction, userInput: String) async throws -> DeliveryPlace {
        let client = try client()
        guard let token = sessionToken else { throw PlaceSearchError.searchFailed }
        // Details ends this billing session. Any later query must use a new token,
        // including when Details fails or the user dismisses while it is in flight.
        sessionToken = nil
        let request = GMSFetchPlaceRequest(placeID: prediction.id, placeProperties: Self.detailProperties, sessionToken: token)
        return try await withCheckedThrowingContinuation { continuation in
            client.fetchPlace(with: request) { place, error in
                guard error == nil, let place, let placeID = place.placeID, !placeID.isEmpty,
                      Coordinate(lat: place.coordinate.latitude, lng: place.coordinate.longitude).isValid else {
                    continuation.resume(throwing: PlaceSearchError.invalidPlace); return
                }
                // Coordinates are used only to verify that this suggestion is routable.
                // The server independently resolves and expires its own coordinate cache.
                continuation.resume(returning: DeliveryPlace(userInput: userInput, googlePlaceId: placeID))
            }
        }
    }

    func resetSession() { sessionToken = nil }
}

@MainActor
final class PlaceSearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [PlacePrediction] = []
    @Published private(set) var searching = false
    @Published private(set) var selecting = false
    @Published private(set) var error: String?
    private let service: any PlaceSearching
    private let debounceNanoseconds: UInt64
    private var searchTask: Task<Void, Never>?
    private var generation = UUID()
    private var active = true
    private var resolvingSelection: UUID?

    struct SelectionRequest {
        fileprivate let generation: UUID
        fileprivate let prediction: PlacePrediction
        fileprivate let userInput: String
    }

    init(service: any PlaceSearching, debounceNanoseconds: UInt64 = 350_000_000) {
        self.service = service; self.debounceNanoseconds = debounceNanoseconds
    }

    func updateQuery(_ value: String) {
        // TextField can write the same value back while resigning first responder.
        // That is not a new search and must not invalidate a tapped prediction.
        guard active, value != query else { return }
        query = value
        selecting = false
        search()
    }

    func search() {
        // A keyboard submit/focus transition must not replace an accepted tap.
        // A genuine edit goes through updateQuery and explicitly supersedes it.
        guard active, !selecting else { return }
        searchTask?.cancel()
        generation = UUID()
        let requestID = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; error = nil; selecting = false
        guard text.count >= 3 else {
            searching = false
            service.resetSession()
            return
        }
        searching = true
        searchTask = Task {
            do {
                if debounceNanoseconds > 0 { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                try Task.checkCancellation()
                let predictions = try await service.predictions(for: text)
                guard active, generation == requestID, !Task.isCancelled else { return }
                results = predictions; searching = false
            } catch {
                guard active, generation == requestID, !Task.isCancelled else { return }
                searching = false
                self.error = (error as? PlaceSearchError)?.errorDescription ?? PlaceSearchError.searchFailed.errorDescription
            }
        }
    }

    /// Claim the tap before the view blurs the keyboard or schedules async work.
    func beginSelection(_ prediction: PlacePrediction) -> SelectionRequest? {
        guard active, !selecting, results.contains(prediction) else { return nil }
        searchTask?.cancel()
        generation = UUID()
        selecting = true; searching = false; error = nil
        return SelectionRequest(generation: generation, prediction: prediction, userInput: query)
    }

    func select(_ prediction: PlacePrediction) async -> DeliveryPlace? {
        guard let request = beginSelection(prediction) else { return nil }
        return await resolveSelection(request)
    }

    func resolveSelection(_ request: SelectionRequest) async -> DeliveryPlace? {
        guard active, selecting, generation == request.generation,
              resolvingSelection != request.generation, !Task.isCancelled else { return nil }
        resolvingSelection = request.generation
        do {
            let selected = try await service.resolve(request.prediction, userInput: request.userInput)
            guard active, generation == request.generation, !Task.isCancelled else { return nil }
            selecting = false
            // Prevent a second tap from committing again before SwiftUI dismisses the sheet.
            active = false; results = []
            service.resetSession()
            return selected
        } catch {
            guard active, generation == request.generation, !Task.isCancelled else { return nil }
            selecting = false; results = []
            service.resetSession()
            self.error = (error as? PlaceSearchError)?.errorDescription ?? PlaceSearchError.searchFailed.errorDescription
            return nil
        }
    }

    func cancel() {
        active = false; generation = UUID()
        searchTask?.cancel(); searchTask = nil
        results = []; searching = false; selecting = false
        service.resetSession()
    }
}

@MainActor
struct PlaceSearchView: View {
    let title: String
    let onSelect: (DeliveryPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: PlaceSearchModel
    @State private var showingAbout = false
    @FocusState private var searchFocused: Bool
    private let fixtureMode: Bool

    init(title: String, isUITesting: Bool, onSelect: @escaping (DeliveryPlace) -> Void) {
        self.title = title; self.onSelect = onSelect
        #if DEBUG
        fixtureMode = isUITesting
        let service: any PlaceSearching
        if isUITesting { service = FixturePlaceSearchService() }
        else { service = GooglePlaceSearchService() }
        _model = StateObject(wrappedValue: PlaceSearchModel(service: service))
        #else
        fixtureMode = false
        _model = StateObject(wrappedValue: PlaceSearchModel(service: GooglePlaceSearchService()))
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Via, numero civico o attività", text: Binding(get: { model.query }, set: model.updateQuery))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { searchFocused = false; model.search() }
                        .disabled(model.selecting)
                        .accessibilityIdentifier("address_search")
                    Text("Conserviamo il testo che scrivi come riferimento. Il risultato scelto indica il punto esatto.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.searching || model.selecting {
                    ProgressView(model.selecting ? "Verifica indirizzo…" : "Ricerca…")
                        .accessibilityIdentifier("address_searching")
                }
                if !model.results.isEmpty {
                    Section {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, prediction in
                            Button {
                                guard let request = model.beginSelection(prediction) else { return }
                                searchFocused = false
                                Task {
                                    if let place = await model.resolveSelection(request) { onSelect(place); dismiss() }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(prediction.title).font(.headline).foregroundStyle(.primary)
                                    Text(prediction.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                            .disabled(model.selecting)
                            .accessibilityIdentifier("address_result_\(index)")
                        }
                    }
                }
                if let error = model.error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("address_error")
                    Button("Riprova") { model.search() }.accessibilityIdentifier("retry_address")
                } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
                    Text("Cerca vicino a Pachino. Per un’altra zona, indica anche il comune.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !model.searching && !model.selecting && model.results.isEmpty {
                    Text("Nessun indirizzo trovato. Prova con numero civico e comune.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("address_empty")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !fixtureMode {
                    // Compact attribution stays visible even when the prediction list scrolls.
                    HStack {
                        Text("Google Maps").font(.system(size: 14, weight: .regular)).lineLimit(1)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255))
                            .accessibilityLabel("Google Maps")
                        Spacer()
                        Button("Informazioni sui risultati", systemImage: "info.circle") { showingAbout = true }
                            .font(.caption)
                    }.padding().background(.regularMaterial)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { model.cancel(); dismiss() }.accessibilityIdentifier("cancel_address")
                }
            }
            .onAppear { searchFocused = true }
            .onDisappear { model.cancel() }
            .sheet(isPresented: $showingAbout) { PlaceSearchAboutView() }
        }
    }
}

private struct PlaceSearchAboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("Google Maps ordina i risultati locali combinando soprattutto pertinenza, distanza e notorietà, per trovare quelli più utili alla ricerca.")
                Link("Come vengono ordinati i risultati", destination: URL(string: "https://support.google.com/maps/answer/3092445?ref_topic=3092444")!)
                Link("Termini di Google Maps", destination: URL(string: "https://maps.google.com/help/terms_maps/")!)
                Link("Privacy di Google", destination: URL(string: "https://policies.google.com/privacy")!)
                DisclosureGroup("Licenze di Google Places") {
                    Text(GMSPlacesClient.openSourceLicenseInfo()).font(.caption).textSelection(.enabled)
                }
            }
            .navigationTitle("Informazioni sui risultati")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
    }
}

#if DEBUG
@MainActor
private final class FixturePlaceSearchService: PlaceSearching {
    private static let pickup = PlacePrediction(id: "arrivau-test-pachino-pickup", title: "Pizzeria Pachino Demo", subtitle: "Via Roma 1, Pachino")
    private static let dropoff = PlacePrediction(id: "arrivau-test-pachino-dropoff", title: "Via Garibaldi 8", subtitle: "Via Garibaldi 8, Pachino")
    func predictions(for query: String) async throws -> [PlacePrediction] {
        if query.lowercased().contains("pizzeria") { return [Self.pickup] }
        if query.lowercased().contains("garibaldi") { return [Self.dropoff] }
        return []
    }
    func resolve(_ prediction: PlacePrediction, userInput: String) async throws -> DeliveryPlace {
        guard [Self.pickup, Self.dropoff].contains(prediction) else { throw PlaceSearchError.invalidPlace }
        return DeliveryPlace(fixtureName: prediction.title, fixtureAddress: prediction.subtitle, googlePlaceId: prediction.id)
    }
    func resetSession() { }
}
#endif
