import CoreLocation
import Combine

/// Starts in foreground. Background continuation requires a separate, visible opt-in.
/// This is standard location tracking, not force-quit/reboot recovery.
@MainActor
final class LocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var message = "Condivisione della posizione disattivata"
    @Published private(set) var permissionDenied = false
    var onCoordinate: ((Coordinate) -> Void)?
    private let manager = CLLocationManager()
    private let deterministic: Bool
    private var requested = false
    private var running = false
    private var foreground = false
    private var backgroundOptIn = false
    private var lastReportedSampleAt: Date?

    init(deterministic: Bool) {
        self.deterministic = deterministic
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
    }

    func configure(enabled: Bool, foreground: Bool, allowBackground: Bool) {
        self.foreground = foreground
        self.backgroundOptIn = allowBackground
        guard enabled else { stop(); return }
        requested = true
        // Never start a new tracking session or request permission from the background.
        guard foreground || (running && allowBackground) else {
            manager.stopUpdatingLocation()
            running = false
            message = "Posizione in pausa finché non apri l’app"
            return
        }
        manager.allowsBackgroundLocationUpdates = allowBackground
        manager.showsBackgroundLocationIndicator = allowBackground
        if deterministic {
            if !running {
                running = true
                message = "Posizione di test: Pachino (simulata)"
                onCoordinate?(.pachino)
            }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            permissionDenied = false
            message = "Consenti l’accesso alla posizione per condividerla durante il turno"
            if foreground { manager.requestWhenInUseAuthorization() }
        case .authorizedAlways, .authorizedWhenInUse:
            permissionDenied = false
            if !running { manager.startUpdatingLocation(); running = true }
            message = allowBackground
                ? "Condivisione durante il turno, anche con lo schermo bloccato (indicatore iOS attivo)"
                : "Condivisione solo mentre l’app è aperta"
        case .denied, .restricted:
            permissionDenied = true
            manager.stopUpdatingLocation()
            running = false
            message = "Accesso alla posizione disattivato. Apri Impostazioni per consentirlo."
        @unknown default: message = "Autorizzazione alla posizione non disponibile"
        }
    }

    func stop() {
        requested = false
        running = false
        lastReportedSampleAt = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        message = "Condivisione della posizione disattivata"
    }

    // CLLocationManagerDelegate requirements are nonisolated. Copy sendable values and
    // explicitly return to MainActor; never pass the manager across actor boundaries.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.requested else { return }
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
        // Throttle fresh sensor samples; never refresh server freshness using a cached coordinate.
        if let lastReportedSampleAt, sample.timestamp.timeIntervalSince(lastReportedSampleAt) < 30 { return }
        if sample.coordinate.isValid {
            lastReportedSampleAt = sample.timestamp
            onCoordinate?(sample.coordinate)
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.requested else { return }
            self.message = "Posizione non disponibile. Controlla le autorizzazioni e riprova."
        }
    }
}

private struct LocationSample: Sendable {
    let coordinate: Coordinate
    let timestamp: Date
    let horizontalAccuracy: Double
}

