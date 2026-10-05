import CoreLocation
import Combine

/// Starts in foreground. Background continuation requires explicit, visible consent.
/// This is standard location tracking, not force-quit/reboot recovery.
@MainActor
final class LocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case stopped, waitingForForeground, permissionNeeded, permissionDenied, waitingForLocation
        case sharing, sharingInBackground, simulated, unavailable
    }
    @Published private(set) var state: State = .stopped
    var compactMessage: String {
        switch state {
        case .stopped: return "Posizione ferma"
        case .waitingForForeground: return "Posizione in pausa"
        case .permissionNeeded: return "Consenti la posizione"
        case .permissionDenied: return "Posizione non consentita"
        case .waitingForLocation: return "Ricerca posizione…"
        case .sharing: return "Posizione condivisa · app aperta"
        case .sharingInBackground: return "Posizione condivisa · anche a schermo bloccato"
        case .simulated: return "Posizione simulata · test"
        case .unavailable: return "Posizione non disponibile"
        }
    }
    @Published private(set) var message = "Condivisione della posizione disattivata"
    @Published private(set) var permissionDenied = false
    var onCoordinate: ((Coordinate) -> Void)?
    // The deterministic fixture must never subscribe to real sensor/authorization events.
    private let manager: CLLocationManager?
    private let deterministic: Bool
    private var requested = false
    private var running = false
    private var foreground = false
    private var backgroundOptIn = false
    private var lastReportedSampleAt: Date?
    private var hasCurrentFix = false
    private var lastReceivedSampleAt: Date?

    init(deterministic: Bool) {
        self.deterministic = deterministic
        manager = deterministic ? nil : CLLocationManager()
        super.init()
        manager?.delegate = self
        manager?.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager?.distanceFilter = kCLDistanceFilterNone
        manager?.pausesLocationUpdatesAutomatically = false
        manager?.allowsBackgroundLocationUpdates = false
    }

    func configure(enabled: Bool, foreground: Bool, allowBackground: Bool) {
        self.foreground = foreground
        self.backgroundOptIn = allowBackground
        guard enabled else { stop(); return }
        requested = true
        // Never start a new tracking session or request permission from the background.
        guard foreground || (running && allowBackground) else {
            manager?.stopUpdatingLocation()
            running = false
            hasCurrentFix = false
            state = .waitingForForeground
            message = "Posizione in pausa finché non apri l’app"
            return
        }
        if deterministic {
            // A repeated configuration is not a fresh fix and cannot clear a sensor error.
            if !running {
                running = true
                state = .simulated
                message = "Posizione di test: Pachino (simulata)"
                onCoordinate?(.pachino)
            }
            return
        }
        guard let manager else { return }
        manager.allowsBackgroundLocationUpdates = allowBackground
        manager.showsBackgroundLocationIndicator = allowBackground
        switch manager.authorizationStatus {
        case .notDetermined:
            permissionDenied = false
            state = .permissionNeeded
            message = "Consenti l’accesso alla posizione per condividerla durante il turno"
            if foreground { manager.requestWhenInUseAuthorization() }
        case .authorizedAlways, .authorizedWhenInUse:
            permissionDenied = false
            if !running {
                hasCurrentFix = false
                manager.startUpdatingLocation()
                running = true
            }
            updateSharingStatus()
        case .denied, .restricted:
            permissionDenied = true
            manager.stopUpdatingLocation()
            running = false
            hasCurrentFix = false
            state = .permissionDenied
            message = "Accesso alla posizione disattivato. Apri Impostazioni per consentirlo."
        @unknown default:
            manager.stopUpdatingLocation()
            running = false
            state = .unavailable
            message = "Autorizzazione alla posizione non disponibile"
        }
    }

    func stop() {
        requested = false
        running = false
        lastReportedSampleAt = nil
        hasCurrentFix = false
        lastReceivedSampleAt = nil
        manager?.stopUpdatingLocation()
        manager?.allowsBackgroundLocationUpdates = false
        manager?.showsBackgroundLocationIndicator = false
        state = .stopped
        message = "Condivisione della posizione disattivata"
    }

    // CLLocationManagerDelegate requirements are nonisolated. Copy sendable values and
    // explicitly return to MainActor; never pass the manager across actor boundaries.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.requested, !self.deterministic else { return }
            self.configure(enabled: true, foreground: self.foreground, allowBackground: self.backgroundOptIn)
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let sample = LocationSample(
            coordinate: Coordinate(lat: location.coordinate.latitude, lng: location.coordinate.longitude),
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy
        )
        Task { @MainActor [weak self] in self?.receive(sample) }
    }
    private func receive(_ sample: LocationSample) {
        guard requested, running, foreground || backgroundOptIn,
              sample.horizontalAccuracy >= 0,
              abs(sample.timestamp.timeIntervalSinceNow) < 60 else { return }
        guard sample.coordinate.isValid else { return }
        // A valid fix clears a sensor error even when upload throttling suppresses this sample.
        hasCurrentFix = true
        lastReceivedSampleAt = sample.timestamp
        updateSharingStatus()
        // Throttle fresh sensor samples; never refresh server freshness using a cached coordinate.
        if let lastReportedSampleAt, sample.timestamp.timeIntervalSince(lastReportedSampleAt) < 30 { return }
        lastReportedSampleAt = sample.timestamp
        onCoordinate?(sample.coordinate)
    }
    private func updateSharingStatus() {
        if deterministic {
            state = .simulated
            message = "Posizione di test: Pachino (simulata)"
        } else if hasCurrentFix, let lastReceivedSampleAt, abs(lastReceivedSampleAt.timeIntervalSinceNow) < 60 {
            state = backgroundOptIn ? .sharingInBackground : .sharing
            message = backgroundOptIn
                ? "Posizione condivisa anche a schermo bloccato"
                : "Condivisione solo mentre l’app è aperta"
        } else if state != .unavailable {
            state = .waitingForLocation
            message = "Ricerca di una posizione aggiornata…"
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.requested else { return }
            self.hasCurrentFix = false
            self.state = .unavailable
            self.message = "Posizione non disponibile. Controlla le autorizzazioni e riprova."
        }
    }
}

private struct LocationSample: Sendable {
    let coordinate: Coordinate
    let timestamp: Date
    let horizontalAccuracy: Double
}

