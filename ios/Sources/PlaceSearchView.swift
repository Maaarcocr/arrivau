import SwiftUI
import MapKit

/// An address and its routing point are selected together, never independent text fields.
struct DeliveryPlace: Identifiable, Equatable {
    let name: String
    let address: String
    let coordinate: Coordinate
    var id: String { "\(address)|\(coordinate.lat)|\(coordinate.lng)" }

    init(name: String, address: String, coordinate: Coordinate) {
        self.name = name
        self.address = address
        self.coordinate = coordinate
    }

    init(item: MKMapItem) {
        let placemark = item.placemark
        let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let address = [street.isEmpty ? nil : street, placemark.locality].compactMap { $0 }.joined(separator: ", ")
        let name = item.name ?? address
        self.name = name
        self.address = address.isEmpty ? (placemark.title ?? name) : address
        self.coordinate = Coordinate(lat: placemark.coordinate.latitude, lng: placemark.coordinate.longitude)
    }
}

struct PlaceSearchView: View {
    let title: String
    let isUITesting: Bool
    let onSelect: (DeliveryPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [DeliveryPlace] = []
    @State private var searching = false
    @State private var searchAttempt = 0
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Via, numero civico o attività", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { searchFocused = false; searchAttempt += 1 }
                        .accessibilityIdentifier("address_search")
                }
                if searching { ProgressView("Ricerca…").accessibilityIdentifier("address_searching") }
                ForEach(results) { place in
                    Button {
                        onSelect(place)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(place.name).font(.headline).foregroundStyle(.primary)
                            Text(place.address).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("address_result_\(results.firstIndex(of: place) ?? 0)")
                }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("address_error")
                    Button("Riprova") { searchAttempt += 1 }.accessibilityIdentifier("retry_address")
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
                    Text("Cerca vicino a Pachino. Per un’altra zona, indica anche il comune.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !searching && results.isEmpty {
                    Text("Nessun indirizzo trovato. Prova con numero civico e comune.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("address_empty")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }.accessibilityIdentifier("cancel_address")
                }
            }
            .task { searchFocused = true }
            .task(id: "\(query)|\(searchAttempt)") { await search() }
        }
    }

    @MainActor private func search() async {
        results = []
        error = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { searching = false; return }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            #if DEBUG
            if isUITesting {
                results = Self.fixtureResults(for: text)
                searching = false
                return
            }
            #endif
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.region = MKCoordinateRegion(center: Coordinate.pachino.clCoordinate, latitudinalMeters: 15000, longitudinalMeters: 15000)
            let response = try await MKLocalSearch(request: request).start()
            try Task.checkCancellation()
            // Discard a late result if the address query changed while Maps was responding.
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            results = response.mapItems.map(DeliveryPlace.init).filter { $0.coordinate.isValid && !$0.address.isEmpty }
            searching = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            searching = false
            self.error = "Ricerca su Mappe non riuscita. Controlla la connessione e riprova con l’indirizzo."
        }
    }

    #if DEBUG
    private static func fixtureResults(for query: String) -> [DeliveryPlace] {
        if query.lowercased().contains("pizzeria") {
            return [DeliveryPlace(name: "Pizzeria Pachino Demo", address: "Via Roma 1, Pachino", coordinate: .pachino)]
        }
        if query.lowercased().contains("garibaldi") {
            return [DeliveryPlace(name: "Via Garibaldi 8", address: "Via Garibaldi 8, Pachino", coordinate: Coordinate(lat: 36.721, lng: 15.1))]
        }
        return []
    }
    #endif
}
