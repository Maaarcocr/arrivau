import Foundation
import Combine

@MainActor
final class DeliveryStore: ObservableObject {
    @Published private(set) var role: DemoRole?
    @Published private(set) var principal: Principal?
    @Published private(set) var deliveries: [Delivery] = []
    @Published private(set) var drivers: [Driver] = []
    @Published private(set) var currentDriver: Driver?
    @Published private(set) var route: DriverRoute?
    @Published private(set) var createOutcomeUncertain = false
    @Published private(set) var isMutating = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var locationSharing = false
    @Published private(set) var backgroundLocationSharing = false
    @Published var errorMessage: String?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var locationErrorMessage: String?
    @Published var apiURL: String
    let location: LocationReporter
    let isUITesting: Bool
    private var client: APIClient?
    private let urlSession: URLSession
    private var foreground = false
    private var pollTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var sessionId = UUID()
    private var refreshId = UUID()

    init(session: URLSession = .shared, deterministicLocation: Bool? = nil) {
        urlSession = session
        #if DEBUG
        isUITesting = deterministicLocation ?? ProcessInfo.processInfo.arguments.contains("--uitesting")
        let configuredURL = ProcessInfo.processInfo.environment["ARRIVAU_API_URL"] ?? ""
        apiURL = configuredURL.isEmpty ? APIConfiguration.defaultURL : configuredURL
        #else
        isUITesting = false
        apiURL = APIConfiguration.defaultURL
        #endif
        location = LocationReporter(deterministic: isUITesting)
        location.onCoordinate = { [weak self] coordinate in self?.reportLocation(coordinate) }
    }

    func login(as selectedRole: DemoRole) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let api = APIClient(baseURL: try APIConfiguration.validatedURL(apiURL), token: selectedRole.token, session: urlSession)
            let user = try await api.me()
            guard user.role == (selectedRole == .dispatcher ? "dispatcher" : "driver"),
                  selectedRole.driverId == nil || user.id == selectedRole.driverId else {
                throw APIError(message: "The API returned an unexpected demo identity.")
            }
            sessionId = UUID()
            client = api
            principal = user
            role = selectedRole
            errorMessage = nil
            createOutcomeUncertain = false
            locationSharing = false
            backgroundLocationSharing = false
            await refresh(force: true)
            startPolling()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Switching roles does not silently end the server-side shift or cancel work.
    func logout() {
        sessionId = UUID()
        refreshId = UUID()
        pollTask?.cancel(); pollTask = nil
        locationTask?.cancel(); locationTask = nil
        location.stop()
        locationSharing = false
        backgroundLocationSharing = false
        role = nil; principal = nil; client = nil; currentDriver = nil
        deliveries = []; drivers = []; route = nil
        errorMessage = nil; syncErrorMessage = nil; locationErrorMessage = nil
        createOutcomeUncertain = false
        lastSyncedAt = nil; isRefreshing = false; isMutating = false
    }

    func setForeground(_ value: Bool) {
        foreground = value
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
        guard let api = client, let selectedRole = role, force || (!isRefreshing && !isMutating) else { return }
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
                deliveries = fetchedJobs
                route = fetchedRoute
                synchronizeLocation()
            }
            lastSyncedAt = Date()
            syncErrorMessage = nil
        } catch is CancellationError { }
        catch {
            guard session == sessionId, refreshId == requestId, !Task.isCancelled else { return }
            syncErrorMessage = error.localizedDescription
        }
    }

    func create(_ delivery: NewDelivery) async -> Delivery? {
        guard !isMutating else { return nil }
        if let validation = delivery.validationError { errorMessage = validation; return nil }
        createOutcomeUncertain = false
        return await mutate({ try await $0.create(delivery) }, onFailure: { error in
            // The server may have created the delivery even if its response never reached us.
            if error is URLError || error.localizedDescription.contains("response did not match") || error.localizedDescription.contains("invalid response") {
                self.createOutcomeUncertain = true
                self.errorMessage = "Couldn’t confirm creation. Check the delivery list before trying again."
            }
        }, apply: applyConfirmedDelivery)
    }
    func assign(deliveryId: String, driverId: String) async -> Bool {
        guard !isMutating, let current = deliveries.first(where: { $0.id == deliveryId }),
              current.status == .pending || current.status == .assigned else { return false }
        if current.status == .assigned && current.driverId == driverId { return true }
        let result: Delivery? = await mutate({ try await $0.assign(deliveryId: deliveryId, driverId: driverId) }, apply: applyConfirmedDelivery)
        return result != nil
    }
    func completeNextStop(_ delivery: Delivery) async {
        // A second tap from an old view must never advance the following stop.
        guard !isMutating,
              let current = deliveries.first(where: { $0.id == delivery.id }),
              current.status == delivery.status else { return }
        guard let next = DeliveryAction.nextStatus(delivery: current, route: route, now: Int(Date().timeIntervalSince1970)) else {
            errorMessage = "Follow the first route stop and wait until the pickup is ready."
            return
        }
        let _: Delivery? = await mutate({ try await $0.status(deliveryId: current.id, status: next) }) { result in
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
        let _: Driver? = await mutate({ try await $0.shift(active: active, capacity: capacity) }) { result in
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
        guard let api = client else { return nil }
        let session = sessionId
        do {
            let suggestions = try await api.suggestions(deliveryId: deliveryId)
            return session == sessionId && !Task.isCancelled ? suggestions : nil
        } catch {
            let failure = error as NSError
            guard !(error is CancellationError), !Task.isCancelled,
                  !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return nil }
            if session == sessionId { errorMessage = error.localizedDescription }
            return nil
        }
    }
    func setLocationSharing(_ value: Bool) {
        locationSharing = value && role?.driverId != nil && currentDriver?.active == true
        if !locationSharing { backgroundLocationSharing = false; locationErrorMessage = nil }
        synchronizeLocation()
    }
    func setBackgroundLocationSharing(_ value: Bool) {
        backgroundLocationSharing = value && locationSharing && currentDriver?.active == true
        synchronizeLocation()
    }
    private var mayShareLocation: Bool {
        (foreground || backgroundLocationSharing) && locationSharing && role?.driverId != nil && currentDriver?.active == true
    }
    private func synchronizeLocation() {
        if !mayShareLocation { locationTask?.cancel(); locationTask = nil }
        location.configure(
            enabled: locationSharing && role?.driverId != nil && currentDriver?.active == true,
            foreground: foreground, allowBackground: backgroundLocationSharing
        )
    }
    private func reportLocation(_ coordinate: Coordinate) {
        guard mayShareLocation, let api = client else { return }
        locationTask?.cancel()
        let session = sessionId
        locationTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let driver = try await api.location(coordinate)
                guard let self, session == self.sessionId, self.mayShareLocation, !Task.isCancelled else { return }
                self.currentDriver = driver
                self.locationErrorMessage = nil
            } catch is CancellationError { }
            catch {
                guard let self, session == self.sessionId, self.mayShareLocation, !Task.isCancelled else { return }
                self.locationErrorMessage = "Location could not be sent: \(error.localizedDescription)"
            }
        }
    }
    private func mutate<T>(_ operation: (APIClient) async throws -> T, onFailure: (Error) -> Void = { _ in }, apply: (T) -> Void) async -> T? {
        guard let api = client, !isMutating else { return nil }
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
            errorMessage = error.localizedDescription
            onFailure(error)
            // A response can be lost after a committed write; reconcile before another action.
            await refresh(force: true)
            return nil
        }
    }
}

