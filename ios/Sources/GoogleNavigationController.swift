import UIKit
import CoreLocation
import GoogleMaps
import GoogleNavigation
import Network

/// UIKit/SDK boundary. No SDK instance, network request or sensor starts at app launch.
/// This controller belongs to one presented trip and never owns a DeliveryStore.
@MainActor
final class GoogleNavigationController: UIViewController, DriverNavigationEngine, CLLocationManagerDelegate, GMSNavigatorListener {
    private var destination: NavigationDestination?
    private var event: ((DriverNavigationState) -> Void)?
    private var token = UUID()
    private let permission = CLLocationManager()
    private var session: GMSNavigationSession?
    private var map: GMSMapView?
    private var timeout: Task<Void, Never>?
    private var network: NWPathMonitor?
    private var foreground = true
    private var backgroundAllowed = false
    private var muted = false
    private var pendingStart = false
    private var termsPending = false
    private var routeReady = false
    private var arrived = false
    private var connected = true
    private var savedIdleTimer: Bool?
    private let configuration: GoogleNavigationConfiguration
    private static var configured = false

    init(configuration: GoogleNavigationConfiguration = .init(info: Bundle.main.infoDictionary ?? [:])) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        permission.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginWhenVisible()
    }

    func start(to destination: NavigationDestination, event: @escaping (DriverNavigationState) -> Void) {
        stop()
        token = UUID()
        self.destination = destination
        self.event = event
        pendingStart = true
        event(.preparing)
        beginWhenVisible()
    }
    private func beginWhenVisible() {
        guard pendingStart, foreground, isViewLoaded, view.window != nil else { return }
        guard let key = configuration.apiKey else { fail(.missingKey); return }
        guard let placeID = destination?.googlePlaceID, !placeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail(.destinationSource); return }
        switch permission.authorizationStatus {
        case .notDetermined:
            event?(.permissionNeeded)
            permission.requestWhenInUseAuthorization()
            return
        case .denied, .restricted: fail(.locationDenied); return
        case .authorizedAlways, .authorizedWhenInUse:
            guard permission.accuracyAuthorization == .fullAccuracy else { fail(.preciseLocationRequired); return }
        @unknown default: fail(.locationDenied); return
        }
        guard !termsPending else { return }
        if !Self.configured {
            GMSNavigationServices.setAbnormalTerminationReportingEnabled(false)
            guard GMSServices.provideAPIKey(key) else { fail(.missingKey); return }
            Self.configured = true
        }
        termsPending = true
        let request = token
        let options = GMSNavigationTermsAndConditionsOptions(companyName: "Arrivau")
        GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) { [weak self] accepted in
            guard let self, self.token == request, self.pendingStart else { return }
            self.termsPending = false
            guard accepted else { self.fail(.termsDeclined); return }
            // A terms dialog may outlive a foreground interruption; never start GPS in background.
            guard self.foreground else { return }
            self.startAuthorizedTrip()
        }
    }
    private func startAuthorizedTrip() {
        guard pendingStart, let destination, let placeID = destination.googlePlaceID,
              let waypoint = GMSNavigationWaypoint(placeID: placeID, title: destination.title),
              let session = GMSNavigationServices.createNavigationSession() else { fail(.unavailable); return }
        pendingStart = false
        self.session = session
        session.travelMode = .driving
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: destination.coordinate.lat, longitude: destination.coordinate.lng, zoom: 15)
        let map = GMSMapView(options: options)
        self.map = map
        guard map.enableNavigation(with: session), let navigator = session.navigator else { fail(.unavailable); return }
        map.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(map)
        NSLayoutConstraint.activate([
            map.leadingAnchor.constraint(equalTo: view.leadingAnchor), map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            map.topAnchor.constraint(equalTo: view.topAnchor), map.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigator.add(self)
        navigator.sendsBackgroundNotifications = false
        navigator.voiceGuidance = muted ? .silent : .alertsAndGuidance
        navigator.volumeLevel = .normal
        session.roadSnappedLocationProvider?.allowsBackgroundLocationUpdates = backgroundAllowed
        session.isStarted = true
        map.isMyLocationEnabled = true
        event?(.routing)
        let request = token
        armRoutingTimeout(request: request)
        navigator.setDestinations([waypoint]) { [weak self] status in
            guard let self, self.token == request, self.session != nil else { return }
            self.timeout?.cancel(); self.timeout = nil
            guard status == .OK else { self.fail(Self.failure(for: status)); return }
            self.routeReady = true
            self.applyActivity()
            self.map?.cameraMode = .following
            self.startNetworkMonitor(request: request)
        }
    }

    private static func failure(for status: GMSRouteStatus) -> NavigationFailure {
        switch status {
        case .networkError: .network
        case .noRouteFound, .waypointError: .noRoute
        case .locationUnavailable: .timedOut
        case .apiKeyNotAuthorized, .quotaExceeded: .unavailable
        default: .unavailable
        }
    }
    private func fail(_ error: NavigationFailure) {
        let notify = event
        stop()
        notify?(.failed(error))
    }
    func stop() {
        token = UUID()
        pendingStart = false
        termsPending = false
        timeout?.cancel(); timeout = nil
        network?.cancel(); network = nil
        // Detach identity/callbacks first: SDK cleanup can synchronously notify its listeners.
        let previous = session
        session = nil
        event = nil
        routeReady = false
        arrived = false
        connected = true
        if let navigator = previous?.navigator { _ = navigator.remove(self) }
        previous?.navigator?.isGuidanceActive = false
        previous?.navigator?.clearDestinations()
        previous?.navigator?.sendsBackgroundNotifications = false
        previous?.roadSnappedLocationProvider?.stopUpdatingLocation()
        previous?.roadSnappedLocationProvider?.allowsBackgroundLocationUpdates = false
        previous?.isStarted = false
        map?.isMyLocationEnabled = false
        map?.isNavigationEnabled = false
        map?.removeFromSuperview()
        map = nil
        destination = nil
        restoreIdleTimer()
    }
    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        if foreground, pendingStart { beginWhenVisible() }
        if foreground, session != nil {
            switch permission.authorizationStatus {
            case .denied, .restricted: fail(.locationDenied); return
            default: break
            }
            guard permission.accuracyAuthorization == .fullAccuracy else { fail(.preciseLocationRequired); return }
        }
        applyActivity()
    }
    func setBackgroundAllowed(_ allowed: Bool) {
        backgroundAllowed = allowed
        session?.roadSnappedLocationProvider?.allowsBackgroundLocationUpdates = allowed
        applyActivity()
    }
    func setMuted(_ muted: Bool) {
        self.muted = muted
        session?.navigator?.voiceGuidance = muted ? .silent : .alertsAndGuidance
    }
    private func applyActivity() {
        guard let session else { return }
        let active = !arrived && (foreground || backgroundAllowed)
        session.isStarted = active
        session.navigator?.isGuidanceActive = active && routeReady
        if active {
            if !routeReady { armRoutingTimeout(request: token) }
            session.roadSnappedLocationProvider?.startUpdatingLocation()
            if foreground {
                if savedIdleTimer == nil { savedIdleTimer = UIApplication.shared.isIdleTimerDisabled }
                UIApplication.shared.isIdleTimerDisabled = true
            } else { restoreIdleTimer() }
        } else {
            timeout?.cancel(); timeout = nil
            session.roadSnappedLocationProvider?.stopUpdatingLocation()
            restoreIdleTimer()
        }
        if arrived { event?(.arrived) }
        else if !active { event?(.paused) }
        else { event?(routeReady ? (connected ? .navigating : .navigatingOffline) : .routing) }
    }
    private func armRoutingTimeout(request: UUID) {
        guard timeout == nil, !routeReady, foreground || backgroundAllowed else { return }
        // Do not charge deliberately paused/background time against the GPS/routing deadline.
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.token == request, !self.routeReady else { return }
            self.fail(.timedOut)
        }
    }
    private func restoreIdleTimer() {
        if let savedIdleTimer { UIApplication.shared.isIdleTimerDisabled = savedIdleTimer }
        savedIdleTimer = nil
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.pendingStart { self.beginWhenVisible() }
            else if self.session != nil {
                switch self.permission.authorizationStatus {
                case .denied, .restricted: self.fail(.locationDenied)
                default:
                    if self.permission.accuracyAuthorization != .fullAccuracy { self.fail(.preciseLocationRequired) }
                }
            }
        }
    }
    func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        guard navigator === session?.navigator, routeReady, !arrived else { return }
        arrived = true
        // Arrival is advisory only. Only the existing explicit server-confirmed action completes work.
        applyActivity()
    }
    func navigatorDidChangeRoute(_ navigator: GMSNavigator) {
        guard navigator === session?.navigator, routeReady, !arrived else { return }
        // SDK reroutes within this one destination; never replace the server's stop order.
        applyActivity()
    }
    private func startNetworkMonitor(request: UUID) {
        let monitor = NWPathMonitor()
        network = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.token == request, !self.arrived else { return }
                // Keep any cached route, but do not pretend live rerouting works offline.
                self.connected = connected
                self.applyActivity()
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.arrivau.navigation-network"))
    }
}
