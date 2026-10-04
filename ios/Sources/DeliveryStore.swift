import Foundation
import Combine

@MainActor
final class DeliveryStore: ObservableObject {
    var role: UserRole? { principal?.serverRole }
    @Published private(set) var principal: Principal?
    @Published private(set) var deliveries: [Delivery] = []
    @Published private(set) var drivers: [Driver] = []
    @Published private(set) var currentDriver: Driver?
    @Published private(set) var route: DriverRoute?
    @Published private(set) var pendingCreation: PendingCreation?
    @Published private(set) var createOutcomeUncertain = false
    @Published private(set) var isMutating = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var canRetryRestore = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var locationSharing = false
    @Published private(set) var backgroundLocationSharing = false
    @Published var errorMessage: String?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var locationErrorMessage: String?
    @Published var apiURL: String
    let location: LocationReporter
    let isUITesting: Bool
    let mode: ConnectionMode
    var isDemo: Bool {
        #if DEBUG
        mode == .demo
        #else
        false
        #endif
    }
    private var client: APIClient?
    private let urlSession: URLSession
    private let storage: SessionStorage
    private var sessionExpiresAt: Int?
    private var didAttemptRestore = false
    private var creationScope: String?
    private var foreground = false
    private var pollTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var sessionId = UUID()
    private var refreshId = UUID()
    private enum ActionKind: Equatable { case assignment(String), status(DeliveryStatus) }
    private struct PendingAction {
        let kind: ActionKind
        let key: String
    }
    private var pendingActions: [String: PendingAction] = [:]

    init(session: URLSession = APIClient.secureSession, deterministicLocation: Bool? = nil,
         mode: ConnectionMode? = nil, storage: SessionStorage? = nil) {
        urlSession = session
        #if DEBUG
        isUITesting = deterministicLocation ?? ProcessInfo.processInfo.arguments.contains("--uitesting")
        self.mode = mode ?? ((isUITesting || ProcessInfo.processInfo.arguments.contains("--demo")) ? .demo : .pilot)
        if let storage { self.storage = storage }
        else if self.mode == .demo { self.storage = MemorySessionStorage() }
        else { self.storage = KeychainSessionStorage() }
        let configuredURL = ProcessInfo.processInfo.environment["ARRIVAU_API_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "ARRIVAU_API_URL") as? String ?? ""
        apiURL = configuredURL.isEmpty ? (self.mode == .demo ? "http://localhost:8080" : "") : configuredURL
        #else
        isUITesting = false
        self.mode = .pilot
        self.storage = storage ?? KeychainSessionStorage()
        apiURL = Bundle.main.object(forInfoDictionaryKey: "ARRIVAU_API_URL") as? String ?? ""
        #endif
        location = LocationReporter(deterministic: isUITesting)
        location.onCoordinate = { [weak self] coordinate in self?.reportLocation(coordinate) }
    }

    func login(username: String, password: String) async {
        guard !isMutating, principal == nil, !isDemo else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { errorMessage = "Inserisci nome utente e password."; return }
        didAttemptRestore = true
        let attempt = UUID()
        sessionId = attempt
        isMutating = true
        errorMessage = nil
        defer { if sessionId == attempt { isMutating = false } }
        do {
            let endpoint = try APIConfiguration.validatedURL(apiURL, mode: .pilot)
            let anonymous = APIClient(baseURL: endpoint, token: "", session: urlSession)
            let result = try await anonymous.login(username: username, password: password)
            let api = APIClient(baseURL: endpoint, token: result.token, session: urlSession)
            guard sessionId == attempt, !Task.isCancelled else { try? await api.revokeSession(); return }
            guard !result.token.isEmpty, result.user.serverRole != nil, result.expiresAt > Int(Date().timeIntervalSince1970) else {
                try? await api.revokeSession()
                throw APIError(message: "Il server ha restituito una sessione non valida.")
            }
            do {
                try storage.saveSession(SavedSession(endpoint: endpoint.absoluteString, token: result.token, expiresAt: result.expiresAt))
                try install(api, user: result.user, expiresAt: result.expiresAt)
            } catch {
                try? storage.clearSession()
                try? await api.revokeSession()
                throw error
            }
            await refresh(force: true)
            startPolling()
        } catch {
            guard sessionId == attempt else { return }
            errorMessage = (error as? APIError)?.isUnauthorized == true
                ? "Nome utente o password non validi. Riprova con le credenziali fornite dal responsabile."
                : ItalianPresentation.errorMessage(error)
        }
    }

    /// Restore authority only after the server validates the saved opaque session.
    /// Location sharing always needs a new explicit opt-in after app launch/login.
    func restoreSession(retry: Bool = false) async {
        guard !isDemo, principal == nil, !isMutating, retry || !didAttemptRestore else { return }
        didAttemptRestore = true
        let attempt = UUID()
        sessionId = attempt
        isRestoringSession = true
        isMutating = true
        canRetryRestore = false
        defer { if sessionId == attempt { isMutating = false; isRestoringSession = false } }
        do {
            guard let saved = try storage.loadSession() else { return }
            guard saved.expiresAt > Int(Date().timeIntervalSince1970), !saved.token.isEmpty else {
                invalidateSession(message: "Sessione scaduta. Accedi di nuovo.")
                return
            }
            let endpoint = try APIConfiguration.validatedURL(saved.endpoint)
            apiURL = endpoint.absoluteString
            let api = APIClient(baseURL: endpoint, token: saved.token, session: urlSession)
            let identity = try await api.identity()
            guard sessionId == attempt, !Task.isCancelled else { return }
            guard let expiresAt = identity.expiresAt, expiresAt > Int(Date().timeIntervalSince1970), identity.user.serverRole != nil else {
                invalidateSession(message: "Sessione non valida. Accedi di nuovo.")
                return
            }
            try storage.saveSession(SavedSession(endpoint: endpoint.absoluteString, token: saved.token, expiresAt: expiresAt))
            try install(api, user: identity.user, expiresAt: expiresAt)
            await refresh(force: true)
            startPolling()
        } catch {
            guard sessionId == attempt else { return }
            if handleUnauthorized(error) { return }
            canRetryRestore = true
            errorMessage = "Accesso salvato non verificato. \(ItalianPresentation.errorMessage(error))"
        }
    }

    #if DEBUG
    func login(as selectedRole: DemoRole) async {
        guard isDemo, !isMutating else { return }
        let attempt = UUID()
        sessionId = attempt
        isMutating = true
        defer { if sessionId == attempt { isMutating = false } }
        do {
            let api = APIClient(baseURL: try APIConfiguration.validatedURL(apiURL, mode: .demo), token: selectedRole.token, session: urlSession)
            let user = try await api.me()
            guard sessionId == attempt, !Task.isCancelled else { return }
            guard user.role == (selectedRole == .dispatcher ? "dispatcher" : "driver"),
                  selectedRole.driverId == nil || user.id == selectedRole.driverId else {
                throw APIError(message: "L’API ha restituito un’identità demo inattesa.")
            }
            try install(api, user: user, expiresAt: nil)
            await refresh(force: true)
            startPolling()
        } catch { if sessionId == attempt { errorMessage = ItalianPresentation.errorMessage(error) } }
    }
    #endif

    private func install(_ api: APIClient, user: Principal, expiresAt: Int?) throws {
        let scope = "\(api.baseURL.absoluteString)|\(user.id)"
        let pending = try storage.loadCreation(scope: scope)
        client = api
        apiURL = api.baseURL.absoluteString
        principal = user
        creationScope = scope
        pendingCreation = pending
        createOutcomeUncertain = pending != nil
        sessionExpiresAt = expiresAt
        errorMessage = nil
        canRetryRestore = false
        locationSharing = false
        backgroundLocationSharing = false
        scheduleExpiry()
    }

    /// Local privacy controls stop immediately, even if server revocation cannot reach the network.
    func logout() {
        var previous = client
        if previous == nil, !isDemo, let saved = try? storage.loadSession(),
           let endpoint = try? APIConfiguration.validatedURL(saved.endpoint) {
            previous = APIClient(baseURL: endpoint, token: saved.token, session: urlSession)
        }
        let revoke = !isDemo
        invalidateSession(message: nil)
        let signedOut = sessionId
        guard revoke, let previous else { return }
        Task { [weak self] in
            do { try await previous.revokeSession() }
            catch {
                guard (error as? APIError)?.isUnauthorized != true,
                      let self, self.sessionId == signedOut, self.principal == nil else { return }
                self.errorMessage = "Sei uscito da questo iPhone e la posizione è ferma. La revoca sul server non è confermata: chiedi al responsabile di revocare la sessione; altrimenti resterà valida fino alla scadenza."
            }
        }
    }

    private func invalidateSession(message: String?) {
        sessionId = UUID()
        refreshId = UUID()
        pollTask?.cancel(); pollTask = nil
        locationTask?.cancel(); locationTask = nil
        expiryTask?.cancel(); expiryTask = nil
        location.stop()
        locationSharing = false
        backgroundLocationSharing = false
        principal = nil; client = nil; currentDriver = nil
        deliveries = []; drivers = []; route = nil
        errorMessage = message; syncErrorMessage = nil; locationErrorMessage = nil
        pendingCreation = nil; creationScope = nil; pendingActions = [:]
        createOutcomeUncertain = false
        sessionExpiresAt = nil
        lastSyncedAt = nil; isRefreshing = false; isMutating = false; isRestoringSession = false
        canRetryRestore = false
        do { try storage.clearSession() }
        catch {
            canRetryRestore = true
            errorMessage = "La posizione è ferma, ma non è stato possibile rimuovere la sessione protetta. Sblocca l’iPhone e riprova a dimenticare l’accesso."
        }
    }

    private func handleUnauthorized(_ error: Error) -> Bool {
        guard (error as? APIError)?.isUnauthorized == true else { return false }
        invalidateSession(message: "Sessione scaduta o revocata. La condivisione della posizione è ferma. Accedi di nuovo.")
        return true
    }
    @discardableResult private func validateSession() -> Bool {
        if let expiry = sessionExpiresAt, expiry <= Int(Date().timeIntervalSince1970) {
            invalidateSession(message: "Sessione scaduta. La condivisione della posizione è ferma. Accedi di nuovo.")
            return false
        }
        return true
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiry = sessionExpiresAt else { return }
        let session = sessionId
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, Double(expiry) - Date().timeIntervalSince1970))) }
            catch { return }
            guard let self, self.sessionId == session else { return }
            self.validateSession()
        }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        guard validateSession() else { return }
        if value { startPolling() }
        else { pollTask?.cancel(); pollTask = nil }
        synchronizeLocation()
    }

    private func startPolling() {
        guard foreground, role != nil, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard validateSession(), let api = client, let selectedRole = role, force || (!isRefreshing && !isMutating) else { return }
        let session = sessionId
        let requestId = UUID()
        refreshId = requestId
        isRefreshing = true
        defer { if refreshId == requestId { isRefreshing = false } }
        do {
            async let jobs = api.deliveries()
            if selectedRole == .dispatcher {
                let people = try await api.drivers()
                let fetchedJobs = try await jobs
                guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
                drivers = people
                deliveries = fetchedJobs
            } else {
                async let planned = api.route()
                let driver = try await api.shift()
                let (fetchedJobs, fetchedRoute) = try await (jobs, planned)
                guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
                currentDriver = driver
                if !driver.active { setLocationSharing(false) }
                deliveries = fetchedJobs
                route = fetchedRoute
                synchronizeLocation()
            }
            reconcilePendingActions()
            lastSyncedAt = Date()
            syncErrorMessage = nil
        } catch is CancellationError { }
        catch {
            guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
            if handleUnauthorized(error) { return }
            syncErrorMessage = ItalianPresentation.errorMessage(error)
        }
    }

    func create(_ delivery: NewDelivery) async -> Delivery? {
        guard validateSession(), !isMutating, role == .dispatcher, let scope = creationScope else { return nil }
        if let validation = delivery.validationError { errorMessage = validation; return nil }
        if let pendingCreation, pendingCreation.delivery != delivery {
            errorMessage = "Verifica prima la creazione in sospeso. Riprovarla userà la stessa richiesta, senza duplicarla."
            return nil
        }
        let pending = pendingCreation ?? PendingCreation(idempotencyKey: UUID().uuidString, delivery: delivery)
        // Persist the exact body and key BEFORE transmission. Relaunch must not invent a new create.
        do { try storage.saveCreation(pending, scope: scope) }
        catch { errorMessage = ItalianPresentation.errorMessage(error); return nil }
        pendingCreation = pending
        createOutcomeUncertain = false
        return await mutate({ try await $0.create(pending.delivery, idempotencyKey: pending.idempotencyKey) }, onFailure: { error in
            if error is URLError || error is CancellationError || (error as? APIError)?.mutationOutcomeUncertain == true {
                self.createOutcomeUncertain = true
                self.errorMessage = "Creazione non confermata. Riprova la stessa richiesta: il server eviterà duplicati, anche se era già stata salvata."
            } else {
                self.clearPendingCreation(scope: scope)
            }
        }) { result in
            self.applyConfirmedDelivery(result)
            self.clearPendingCreation(scope: scope)
        }
    }
    func retryPendingCreation() async -> Delivery? {
        guard let pendingCreation else { return nil }
        return await create(pendingCreation.delivery)
    }
    private func clearPendingCreation(scope: String) {
        do {
            try storage.clearCreation(scope: scope)
            pendingCreation = nil
            createOutcomeUncertain = false
        } catch {
            // Keep the same key until local cleanup succeeds. A replay is safe.
            createOutcomeUncertain = true
            errorMessage = "Consegna verificata, ma il recupero locale non è stato aggiornato. Riprova la stessa richiesta per completare la verifica."
        }
    }
    func assign(deliveryId: String, driverId: String) async -> Bool {
        guard !isMutating, let current = deliveries.first(where: { $0.id == deliveryId }),
              current.status == .pending || current.status == .assigned else { return false }
        if current.status == .assigned && current.driverId == driverId { return true }
        guard let key = actionKey(for: deliveryId, kind: .assignment(driverId)) else { return false }
        let result: Delivery? = await mutate({ try await $0.assign(deliveryId: deliveryId, driverId: driverId, idempotencyKey: key) }, onFailure: { error in
            self.releaseActionIfDefinitive(error, deliveryId: deliveryId)
        }) { result in
            self.pendingActions[deliveryId] = nil
            self.applyConfirmedDelivery(result)
        }
        return result != nil
    }
    func completeNextStop(_ delivery: Delivery) async {
        // A second tap from an old view must never advance the following stop.
        guard !isMutating,
              let current = deliveries.first(where: { $0.id == delivery.id }),
              current.status == delivery.status else { return }
        guard let next = DeliveryAction.nextStatus(delivery: current, route: route, now: Int(Date().timeIntervalSince1970)) else {
            errorMessage = "Segui la prima tappa del percorso e attendi che la consegna sia pronta per il ritiro."
            return
        }
        guard let key = actionKey(for: current.id, kind: .status(next)) else { return }
        let _: Delivery? = await mutate({ try await $0.status(deliveryId: current.id, status: next, idempotencyKey: key) }, onFailure: { error in
            self.releaseActionIfDefinitive(error, deliveryId: current.id)
        }) { result in
            self.pendingActions[current.id] = nil
            self.applyConfirmedDelivery(result)
            // Only remove the stop the server confirmed. A later refresh replans the remainder.
            if let route = self.route, let stop = route.stops.first,
               stop.deliveryId == result.id,
               (stop.kind == .pickup && result.status == .pickedUp) || (stop.kind == .dropoff && result.status == .delivered) {
                self.route = DriverRoute(driverId: route.driverId, stops: Array(route.stops.dropFirst()),
                                         travelSeconds: route.travelSeconds, finishAt: route.finishAt,
                                         feasible: route.feasible, warnings: route.warnings)
            }
        }
    }
    /// While an outcome is unknown, repeat only that exact logical action with its original key.
    /// A fresh server read after relaunch is required before any route action is available.
    private func actionKey(for deliveryId: String, kind: ActionKind) -> String? {
        if let pending = pendingActions[deliveryId] {
            guard pending.kind == kind else {
                errorMessage = "La modifica precedente non è ancora verificata. Aggiorna i dati o riprova la stessa operazione prima di cambiarla."
                return nil
            }
            return pending.key
        }
        let key = UUID().uuidString
        pendingActions[deliveryId] = PendingAction(kind: kind, key: key)
        return key
    }
    private func releaseActionIfDefinitive(_ error: Error, deliveryId: String) {
        if !(error is URLError), !(error is CancellationError), (error as? APIError)?.mutationOutcomeUncertain != true {
            pendingActions[deliveryId] = nil
        }
    }
    private func reconcilePendingActions() {
        for delivery in deliveries {
            guard let pending = pendingActions[delivery.id] else { continue }
            switch pending.kind {
            case .assignment(let target):
                if delivery.driverId == target, delivery.status != .pending { pendingActions[delivery.id] = nil }
            case .status(let target):
                if delivery.status == target || delivery.status == .delivered { pendingActions[delivery.id] = nil }
            }
        }
    }

    /// This single, explicitly labeled action opts into foreground location only after the server starts the shift.
    func startShiftAndShareLocation() async {
        guard !isMutating, let driver = currentDriver, !driver.active else { return }
        let _: Driver? = await mutate({ try await $0.shift(active: true, capacity: driver.capacity) }) { result in
            self.currentDriver = result
            if result.active { self.setLocationSharing(true) }
        }
    }
    func setShift(active: Bool, capacity: Int) async {
        guard !isMutating, currentDriver?.active != active else { return }
        let _: Driver? = await mutate({ try await $0.shift(active: active, capacity: capacity) }, onFailure: { error in
            if !active, error is URLError || error is CancellationError || (error as? APIError)?.mutationOutcomeUncertain == true {
                self.setLocationSharing(false)
                self.errorMessage = "Fine turno non confermata. La posizione è comunque ferma su questo iPhone: aggiorna i dati per verificare il turno."
            }
        }) { result in
            self.currentDriver = result
            if !result.active { self.setLocationSharing(false) }
            self.synchronizeLocation()
        }
    }
    private func applyConfirmedDelivery(_ delivery: Delivery) {
        if let index = deliveries.firstIndex(where: { $0.id == delivery.id }) { deliveries[index] = delivery }
        else { deliveries.append(delivery) }
    }
    func suggestions(for deliveryId: String) async -> [Suggestion]? {
        guard validateSession(), let api = client else { return nil }
        let session = sessionId
        do {
            let suggestions = try await api.suggestions(deliveryId: deliveryId)
            return session == sessionId && !Task.isCancelled ? suggestions : nil
        } catch {
            let failure = error as NSError
            guard !(error is CancellationError), !Task.isCancelled,
                  !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return nil }
            if session == sessionId, !handleUnauthorized(error) { errorMessage = ItalianPresentation.errorMessage(error) }
            return nil
        }
    }
    func setLocationSharing(_ value: Bool) {
        guard validateSession() else { return }
        locationSharing = value && role == .driver && currentDriver?.active == true
        if !locationSharing { backgroundLocationSharing = false; locationErrorMessage = nil }
        synchronizeLocation()
    }
    func setBackgroundLocationSharing(_ value: Bool) {
        guard validateSession() else { return }
        backgroundLocationSharing = value && locationSharing && currentDriver?.active == true
        synchronizeLocation()
    }
    private var mayShareLocation: Bool {
        (foreground || backgroundLocationSharing) && locationSharing && role == .driver && currentDriver?.active == true
    }
    private func synchronizeLocation() {
        if !mayShareLocation { locationTask?.cancel(); locationTask = nil }
        location.configure(
            enabled: locationSharing && role == .driver && currentDriver?.active == true,
            foreground: foreground, allowBackground: backgroundLocationSharing
        )
    }
    private func reportLocation(_ coordinate: Coordinate) {
        guard validateSession(), mayShareLocation, let api = client else { return }
        locationTask?.cancel()
        let session = sessionId
        locationTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let driver = try await api.location(coordinate)
                guard let self, session == self.sessionId, self.mayShareLocation, !Task.isCancelled else { return }
                self.currentDriver = driver
                if !driver.active { self.setLocationSharing(false) }
                self.locationErrorMessage = nil
            } catch is CancellationError { }
            catch {
                guard let self, session == self.sessionId, self.mayShareLocation, !Task.isCancelled else { return }
                if self.handleUnauthorized(error) { return }
                if (error as? APIError)?.statusCode == 409 {
                    // Another device may have ended the shift while this app was backgrounded.
                    // Stop collection/transmission immediately rather than waiting for foreground polling.
                    self.setLocationSharing(false)
                    self.locationErrorMessage = "Il server non consente più la posizione per questo turno. La condivisione è ferma: aggiorna i dati prima di riprenderla."
                    return
                }
                self.locationErrorMessage = "Invio della posizione non riuscito: \(ItalianPresentation.errorMessage(error))"
            }
        }
    }
    private func mutate<T>(_ operation: (APIClient) async throws -> T, onFailure: (Error) -> Void = { _ in }, apply: (T) -> Void) async -> T? {
        guard validateSession(), let api = client, !isMutating else { return nil }
        let session = sessionId
        isMutating = true
        errorMessage = nil
        defer { if session == sessionId { isMutating = false } }
        do {
            let value = try await operation(api)
            guard session == sessionId else { return nil }
            // A refresh begun before this write may contain stale state. Ignore its result.
            refreshId = UUID()
            isRefreshing = false
            apply(value)
            await refresh(force: true)
            return session == sessionId ? value : nil
        } catch {
            guard session == sessionId else { return nil }
            if handleUnauthorized(error) { return nil }
            errorMessage = ItalianPresentation.errorMessage(error)
            onFailure(error)
            // A response can be lost after a committed write; reconcile before another action.
            await refresh(force: true)
            return nil
        }
    }
}


