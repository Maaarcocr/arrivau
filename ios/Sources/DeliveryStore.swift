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
    private var foreground = false
    private var pollTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var sessionId = UUID()
    private var refreshId = UUID()

    init() {
        #if DEBUG
        isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
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
            let api = APIClient(baseURL: try APIConfiguration.validatedURL(apiURL), token: selectedRole.token)
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
        guard let api = client, let selectedRole = role, force || !isRefreshing else { return }
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
        if let validation = delivery.validationError { errorMessage = validation; return nil }
        return await mutate { try await $0.create(delivery) }
    }
    func assign(deliveryId: String, driverId: String) async -> Bool {
        let result: Delivery? = await mutate { try await $0.assign(deliveryId: deliveryId, driverId: driverId) }
        return result != nil
    }
    func completeNextStop(_ delivery: Delivery) async {
        guard let next = DeliveryAction.nextStatus(delivery: delivery, route: route, now: Int(Date().timeIntervalSince1970)) else {
            errorMessage = "Follow the first route stop and wait until the pickup is ready."
            return
        }
        let _: Delivery? = await mutate { try await $0.status(deliveryId: delivery.id, status: next) }
    }
    func setShift(active: Bool, capacity: Int) async {
        let session = sessionId
        let _: Driver? = await mutate { api in
            let result = try await api.shift(active: active, capacity: capacity)
            guard session == self.sessionId else { return result }
            // Apply a confirmed shift change before the follow-up reads, which could fail.
            self.currentDriver = result
            if !result.active { self.setLocationSharing(false) }
            self.synchronizeLocation()
            return result
        }
    }
    func suggestions(for deliveryId: String) async -> [Suggestion]? {
        guard let api = client else { return nil }
        let session = sessionId
        do {
            let suggestions = try await api.suggestions(deliveryId: deliveryId)
            return session == sessionId ? suggestions : nil
        } catch {
            if session == sessionId { errorMessage = error.localizedDescription }
            return nil
        }
    }
    func setLocationSharing(_ value: Bool) {
        locationSharing = value
        if !value { backgroundLocationSharing = false; locationErrorMessage = nil }
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
    private func mutate<T>(_ operation: (APIClient) async throws -> T) async -> T? {
        guard let api = client, !isMutating else { return nil }
        let session = sessionId
        isMutating = true
        errorMessage = nil
        defer { if session == sessionId { isMutating = false } }
        do {
            let value = try await operation(api)
            guard session == sessionId else { return nil }
            await refresh(force: true)
            return value
        } catch {
            if session == sessionId { errorMessage = error.localizedDescription }
            return nil
        }
    }
}
