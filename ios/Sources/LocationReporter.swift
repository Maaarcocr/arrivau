import CoreLocation
import Combine

/// Starts in foreground. Background continuation requires a separate, visible opt-in.
/// This is standard location tracking, not force-quit/reboot recovery.
@MainActor
final class LocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var message = "Location sharing is off"
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
            message = "Location paused until the app is open"
            return
        }
        manager.allowsBackgroundLocationUpdates = allowBackground
        manager.showsBackgroundLocationIndicator = allowBackground
        if deterministic {
            if !running {
                running = true
                message = "UI test location: Pachino (simulated)"
                onCoordinate?(.pachino)
            }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            permissionDenied = false
            message = "Allow location to share your position during this shift"
            if foreground { manager.requestWhenInUseAuthorization() }
        case .authorizedAlways, .authorizedWhenInUse:
            permissionDenied = false
            if !running { manager.startUpdatingLocation(); running = true }
            message = allowBackground
                ? "Sharing on shift, including with the screen locked (iOS indicator enabled)"
                : "Sharing only while the app is open"
        case .denied, .restricted:
            permissionDenied = true
            manager.stopUpdatingLocation()
            running = false
            message = "Location access is off. Open Settings to allow it."
        @unknown default: message = "Location permission is unavailable"
        }
    }

    func stop() {
        requested = false
        running = false
        lastReportedSampleAt = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        message = "Location sharing is off"
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
        let detail = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.requested else { return }
            self.message = "Location unavailable: \(detail)"
        }
    }
}

private struct LocationSample: Sendable {
    let coordinate: Coordinate
    let timestamp: Date
    let horizontalAccuracy: Double
}

