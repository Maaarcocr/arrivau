import Foundation
import Combine

/// A snapshot of only the server's first stop. Changing estimates must not restart guidance.
struct NavigationDestination: Identifiable, Equatable {
    let accountID: String
    let teamID: String?
    let stopID: String
    let googlePlaceID: String?
    let coordinate: Coordinate?
    let title: String
    let address: String
    var id: String { "\(accountID):\(stopID)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountID == rhs.accountID && lhs.teamID == rhs.teamID && lhs.stopID == rhs.stopID &&
        lhs.googlePlaceID == rhs.googlePlaceID &&
        (lhs.googlePlaceID != nil || lhs.coordinate == rhs.coordinate)
    }

    static func next(principal: Principal?, role: UserRole?, driver: Driver?, route: DriverRoute?) -> Self? {
        guard role == .driver, let principal, principal.supports(.driver),
              driver?.id == principal.id, driver?.active == true,
              route?.driverId == principal.id, let stop = route?.stops.first,
              stop.coordinate?.isValid != false,
              stop.coordinate != nil || stop.googlePlaceId != nil else { return nil }
        return Self(accountID: principal.id, teamID: principal.teamId, stopID: stop.id, googlePlaceID: stop.googlePlaceId,
                    coordinate: stop.coordinate, title: stop.title, address: stop.address)
    }
}

struct GoogleNavigationConfiguration {
    let apiKey: String?
    init(info: [String: Any]) {
        let value = (info["ARRIVAU_GOOGLE_MAPS_API_KEY"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Missing build-setting expansion, placeholders and malformed keys fail closed.
        apiKey = value.range(of: "^AIza[A-Za-z0-9_-]{35}$", options: .regularExpression) == nil ? nil : value
    }
}

enum DriverNavigationState: Equatable {
    case idle, preparing, permissionNeeded, routing, navigating, navigatingOffline, arrived, paused, stopped
    case failed(NavigationFailure)

    var message: String {
        switch self {
        case .idle, .preparing: "Preparazione di Google Maps…"
        case .permissionNeeded: "Consenti la posizione precisa per navigare."
        case .routing: "Calcolo del percorso…"
        case .navigating: "Segui le indicazioni di Google Maps"
        case .navigatingOffline: "Connessione assente: le indicazioni già caricate possono continuare, il ricalcolo potrebbe non riuscire."
        case .arrived: "Sei arrivato. Torna alla tappa per confermare il ritiro o la consegna."
        case .paused: "Navigazione in pausa. Riapri l’app per riprendere."
        case .stopped: "Navigazione terminata"
        case .failed(let failure): failure.message
        }
    }
    var canRetry: Bool {
        if case .failed(let error) = self { return error.canRetry }
        return false
    }
}

enum NavigationFailure: Equatable {
    case missingKey, destinationSource, locationDenied, preciseLocationRequired, termsDeclined
    case network, noRoute, unavailable, destinationChanged, timedOut
    var message: String {
        switch self {
        case .missingKey: "Navigazione non ancora configurata. Chiedi alla centrale di attivare Google Maps."
        case .destinationSource: "Navigazione non ancora attivata per questi indirizzi. Contatta la centrale."
        case .locationDenied: "La posizione è disattivata. Consenti l’accesso nelle Impostazioni di iOS."
        case .preciseLocationRequired: "Attiva Posizione precisa nelle Impostazioni di iOS per usare le indicazioni."
        case .termsDeclined: "Per navigare devi accettare le condizioni di Google. La tappa resta invariata."
        case .network: "Connessione non disponibile. Controlla la rete e riprova da fermo."
        case .noRoute: "Google non trova un percorso per questa tappa. Contatta la centrale."
        case .unavailable: "Google Maps non è disponibile. Riprova da fermo o contatta la centrale."
        case .destinationChanged: "La prossima tappa è cambiata. Torna al percorso per controllarla."
        case .timedOut: "Non è arrivato un percorso. Controlla posizione e rete, poi riprova da fermo."
        }
    }
    var canRetry: Bool {
        switch self {
        case .missingKey, .destinationSource, .destinationChanged: false
        default: true
        }
    }
    var needsSettings: Bool { self == .locationDenied || self == .preciseLocationRequired }
}

@MainActor
protocol DriverNavigationEngine: AnyObject {
    func start(to destination: NavigationDestination, event: @escaping (DriverNavigationState) -> Void)
    func stop()
    func setForeground(_ foreground: Bool)
    func setBackgroundAllowed(_ allowed: Bool)
    func setMuted(_ muted: Bool)
}

/// Owns an explicitly started trip, never the backend delivery state.
/// Generation checks reject callbacks after close, retry, logout or a changed first stop.
@MainActor
final class DriverNavigationSession: ObservableObject {
    let destination: NavigationDestination
    let engine: any DriverNavigationEngine
    @Published private(set) var state: DriverNavigationState = .idle
    @Published private(set) var backgroundAllowed = false
    @Published private(set) var muted = false
    private var generation = UUID()
    private var invalidated = false

    init(destination: NavigationDestination, engine: any DriverNavigationEngine) {
        self.destination = destination
        self.engine = engine
    }
    func start() {
        guard !invalidated, state == .idle || state.canRetry else { return }
        generation = UUID()
        let request = generation
        state = .preparing
        engine.start(to: destination) { [weak self] state in
            guard let self, !self.invalidated, self.generation == request else { return }
            self.state = state
        }
        engine.setBackgroundAllowed(backgroundAllowed)
        engine.setMuted(muted)
    }
    func validate(current: NavigationDestination?) {
        guard current != destination, !invalidated else { return }
        stop()
        state = .failed(.destinationChanged)
    }
    func stop() {
        generation = UUID()
        invalidated = true
        engine.stop()
        state = .stopped
    }
    func setForeground(_ foreground: Bool) { if !invalidated { engine.setForeground(foreground) } }
    func setBackgroundAllowed(_ allowed: Bool) {
        guard !invalidated else { return }
        backgroundAllowed = allowed
        engine.setBackgroundAllowed(allowed)
    }
    func setMuted(_ value: Bool) {
        guard !invalidated else { return }
        muted = value
        engine.setMuted(value)
    }
}

extension DeliveryStore {
    var navigationDestination: NavigationDestination? {
        NavigationDestination.next(principal: principal, role: role, driver: currentDriver, route: route)
    }
}
