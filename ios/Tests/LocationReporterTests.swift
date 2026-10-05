import XCTest
import Combine
import CoreLocation
@testable import Arrivau

/// Deterministic lifecycle contract, not evidence of physical-device GPS delivery.
@MainActor
final class LocationReporterTests: XCTestCase {
    func testBackgroundConsentNeverStartsANewSensorSessionWhileBackgrounded() {
        let reporter = LocationReporter(deterministic: true)
        var samples = 0
        reporter.onCoordinate = { _ in samples += 1 }
        reporter.configure(enabled: true, foreground: false, allowBackground: true)
        XCTAssertEqual(reporter.state, .waitingForForeground)
        XCTAssertEqual(reporter.compactMessage, "Posizione in pausa")
        XCTAssertEqual(samples, 0)
        reporter.configure(enabled: true, foreground: true, allowBackground: true)
        XCTAssertEqual(reporter.state, .simulated)
        XCTAssertEqual(samples, 1)
        reporter.configure(enabled: true, foreground: false, allowBackground: true)
        XCTAssertEqual(reporter.state, .simulated)
        XCTAssertEqual(samples, 1, "A foreground-started session continues without manufacturing a fresh sample")
        reporter.stop()
        reporter.configure(enabled: true, foreground: false, allowBackground: true)
        XCTAssertEqual(reporter.state, .waitingForForeground)
        XCTAssertEqual(samples, 1)
        reporter.stop()
    }

    func testForegroundOnlySharingPausesAndRestartsAfterInterruption() {
        let reporter = LocationReporter(deterministic: true)
        var samples = 0
        reporter.onCoordinate = { _ in samples += 1 }
        reporter.configure(enabled: true, foreground: true, allowBackground: false)
        XCTAssertEqual(samples, 1)
        reporter.configure(enabled: true, foreground: false, allowBackground: false)
        XCTAssertEqual(reporter.state, .waitingForForeground)
        XCTAssertEqual(samples, 1)
        reporter.configure(enabled: true, foreground: true, allowBackground: false)
        XCTAssertEqual(reporter.state, .simulated)
        XCTAssertEqual(samples, 2)
        reporter.configure(enabled: false, foreground: true, allowBackground: false)
        XCTAssertEqual(reporter.state, .stopped)
        XCTAssertEqual(reporter.compactMessage, "Posizione ferma")
    }

    func testDeterministicAuthorizationCallbackAndRefreshCannotClearSensorError() async {
        let reporter = LocationReporter(deterministic: true)
        reporter.configure(enabled: true, foreground: true, allowBackground: true)
        let failed = expectation(description: "Injected sensor error is visible")
        let failureObservation = reporter.$state.dropFirst().filter { $0 == .unavailable }.sink { _ in failed.fulfill() }
        let manager = CLLocationManager()
        reporter.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: 0))
        await fulfillment(of: [failed], timeout: 2)
        failureObservation.cancel()

        let unexpectedRecovery = expectation(description: "Only a fresh fix may recover the sensor error")
        unexpectedRecovery.isInverted = true
        let recoveryObservation = reporter.$state.dropFirst().filter { $0 == .simulated }.sink { _ in unexpectedRecovery.fulfill() }
        reporter.locationManagerDidChangeAuthorization(manager)
        reporter.configure(enabled: true, foreground: true, allowBackground: true)
        await fulfillment(of: [unexpectedRecovery], timeout: 0.1)
        recoveryObservation.cancel()
        XCTAssertEqual(reporter.state, .unavailable)
        XCTAssertEqual(reporter.compactMessage, "Posizione non disponibile")
        reporter.stop()
    }

    func testFreshSensorSampleRecoversErrorAndLateErrorCannotUndoStop() async {
        let reporter = LocationReporter(deterministic: true)
        reporter.configure(enabled: true, foreground: true, allowBackground: true)
        let failed = expectation(description: "Sensor error is visible")
        let failureObservation = reporter.$state.dropFirst().filter { $0 == .unavailable }.sink { _ in failed.fulfill() }
        let manager = CLLocationManager()
        reporter.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: 0))
        await fulfillment(of: [failed], timeout: 2)
        failureObservation.cancel()
        XCTAssertEqual(reporter.compactMessage, "Posizione non disponibile")
        let recovered = expectation(description: "Fresh sensor fix clears error")
        let recoveryObservation = reporter.$state.dropFirst().filter { $0 == .simulated }.sink { _ in recovered.fulfill() }
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 36.7163, longitude: 15.0908),
                             altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 50, timestamp: Date())
        reporter.locationManager(manager, didUpdateLocations: [fix])
        await fulfillment(of: [recovered], timeout: 2)
        recoveryObservation.cancel()
        XCTAssertEqual(reporter.compactMessage, "Posizione simulata · test")
        reporter.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: 0))
        reporter.stop()
        await Task.yield()
        XCTAssertEqual(reporter.state, .stopped)
    }

}
