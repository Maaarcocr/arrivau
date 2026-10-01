import XCTest

/// Requires a real Rust API with a fresh empty demo database on localhost:8080.
/// Only the sensor input is deterministic; login, creation, assignment and status use HTTP.
final class DeliveryFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var apiURL: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        let configured = ProcessInfo.processInfo.environment["ARRIVAU_API_URL"] ?? ""
        let baseURL = configured.hasPrefix("http") ? configured : "http://localhost:8080"
        app.launchEnvironment["ARRIVAU_API_URL"] = baseURL
        apiURL = try XCTUnwrap(URL(string: baseURL))
        app.launch()
    }
    override func tearDownWithError() throws {
        if let failureCount = testRun?.failureCount, failureCount > 0 {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Delivery flow failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Accessibility hierarchy at failure"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    @MainActor
    func testDispatcherToDriverLifecycle() async throws {
        login("driver1")
        let shift = app.buttons["toggle_shift"]
        XCTAssertTrue(shift.waitForExistence(timeout: 15))
        XCTAssertEqual(shift.label, "Start shift", "Run against a fresh demo database")
        tap(shift)
        waitForLabel(app.staticTexts["shift_status"], "On shift")
        let beforeOptIn = try await readDriverFromServer()
        XCTAssertTrue(beforeOptIn.active)
        XCTAssertNil(beforeOptIn.location, "Starting a shift must not transmit a location without opt-in")
        let optInAt = Int(Date().timeIntervalSince1970)
        tap(app.switches["share_location"])
        XCTAssertEqual(app.switches["share_location"].value as? String, "1")
        try await waitForServerLocation(since: optInAt)
        let sentLabel = app.staticTexts["location_sent"]
        reveal(sentLabel)
        XCTAssertTrue(sentLabel.waitForExistence(timeout: 15))
        switchRole()

        login("dispatcher")
        tap(app.buttons["create_delivery"])
        let shopName = "UI test pizza \(UUID().uuidString.prefix(6))"
        let shop = app.textFields["shop_name"]
        XCTAssertTrue(shop.waitForExistence(timeout: 5))
        replace(shop, with: shopName)
        // Defaults are ready in the past, due one hour ahead, 1 unit, Pachino coordinates.
        tap(app.buttons["submit_delivery"])
        XCTAssertTrue(app.buttons["create_delivery"].waitForExistence(timeout: 15))
        let deliveryRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", shopName)).firstMatch
        XCTAssertTrue(deliveryRow.waitForExistence(timeout: 15))
        tap(deliveryRow)
        tap(app.buttons["suggest_drivers"])
        tap(app.buttons["assign_driver-1"], timeout: 15)
        waitForLabel(app.staticTexts["delivery_status"], "Assigned")
        // Detail navigation may hide the parent toolbar; return before switching identities.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        switchRole()

        login("driver1")
        tap(app.switches["share_location"])
        tap(app.buttons["confirm_pickup"], timeout: 15)
        tap(app.buttons["confirm_dropoff"], timeout: 15)
        reveal(app.staticTexts["empty_route"])
        XCTAssertTrue(app.staticTexts["empty_route"].waitForExistence(timeout: 15))
        let delivered = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", shopName, "Delivered")).firstMatch
        reveal(delivered)
        XCTAssertTrue(delivered.exists)
        // Return to the shift controls and end the shift, verifying the location stop path.
        for _ in 0..<5 { if app.buttons["toggle_shift"].isHittable { break }; app.swipeDown() }
        tap(app.buttons["toggle_shift"])
        waitForLabel(app.staticTexts["shift_status"], "Off shift")
        XCTAssertEqual(app.switches["share_location"].value as? String, "0")
        switchRole()

        login("dispatcher")
        let completedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", shopName)).firstMatch
        tap(completedRow)
        waitForLabel(app.staticTexts["delivery_status"], "Delivered")
        XCTAssertFalse(app.buttons["suggest_drivers"].exists)
    }

    func testCancelCreationAndRejectRemoteServer() {
        login("dispatcher")
        tap(app.buttons["create_delivery"])
        tap(app.buttons["cancel_delivery"])
        XCTAssertTrue(app.buttons["create_delivery"].exists)
        tap(app.buttons["create_delivery"])
        XCTAssertEqual(app.textFields["shop_name"].value as? String, "Pizzeria Pachino")
        tap(app.buttons["cancel_delivery"])
        switchRole()
        replace(app.textFields["api_url"], with: "http://example.com")
        tap(app.buttons["login_dispatcher"])
        XCTAssertTrue(app.alerts["Couldn’t complete that"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "loopback")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["login_dispatcher"].exists)
    }

    private struct ServerDriver: Decodable {
        struct Location: Decodable { let lat: Double; let lng: Double }
        let active: Bool
        let location: Location?
        let locationUpdatedAt: Int?
    }
    private func readDriverFromServer() async throws -> ServerDriver {
        var request = URLRequest(url: apiURL.appendingPathComponent("v1/shift"))
        request.timeoutInterval = 5
        request.setValue("Bearer demo-driver-1", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Shift read failed: \(String(decoding: data, as: UTF8.self))")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ServerDriver.self, from: data)
    }
    private func waitForServerLocation(since timestamp: Int) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let driver = try await readDriverFromServer()
            if let location = driver.location, let updated = driver.locationUpdatedAt, updated >= timestamp {
                XCTAssertEqual(location.lat, 36.7163, accuracy: 0.000001)
                XCTAssertEqual(location.lng, 15.0908, accuracy: 0.000001)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("The app did not persist a fresh deterministic Pachino location to the real API after opt-in")
    }

    private func login(_ role: String) {
        tap(app.buttons["login_\(role)"])
        let destination = role == "dispatcher" ? app.buttons["create_delivery"] : app.buttons["toggle_shift"]
        XCTAssertTrue(destination.waitForExistence(timeout: 20), "Check the running Rust API and fresh database")
    }
    private func switchRole() { tap(app.buttons["switch_role"]) }
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        if !element.waitForExistence(timeout: min(timeout, 3)) { reveal(element) }
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        reveal(element)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<7 {
            if element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<7 {
            if element.isHittable { return }
            app.swipeDown()
        }
    }
    private func replace(_ field: XCUIElement, with value: String) {
        tap(field)
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText(value)
    }
    private func waitForLabel(_ element: XCUIElement, _ label: String) {
        let predicate = NSPredicate(format: "label == %@", label)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 15)
    }
}
