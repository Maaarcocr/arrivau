import XCTest

/// Requires a real Rust API with a fresh empty demo database on localhost:8080.
/// Only sensor input and address search are deterministic; delivery and shift actions use HTTP.
final class DeliveryFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var apiURL: URL!
    private let shopName = "Pizzeria Pachino Demo"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        let configured = ProcessInfo.processInfo.environment["ARRIVAU_API_URL"] ?? ""
        let baseURL = configured.hasPrefix("http") ? configured : "http://localhost:8080"
        app.launchEnvironment["ARRIVAU_API_URL"] = baseURL
        var readURL = try XCTUnwrap(URLComponents(string: baseURL))
        // CI binds the demo server to IPv4; avoid localhost's slow IPv6 fallback in test reads.
        if readURL.host == "localhost" { readURL.host = "127.0.0.1" }
        apiURL = try XCTUnwrap(readURL.url)
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
    func testDispatcherToDriverLifecycle() throws {
        login("driver1")
        let start = app.buttons["toggle_shift"]
        XCTAssertEqual(start.label, "Start shift & share location", "Run against a fresh demo database")
        waitForLabelContaining(app.buttons["shift_settings"], "Off shift")
        assertRoutineDriverHome()
        let startAt = Int(Date().timeIntervalSince1970)
        tap(start)
        waitForLabelContaining(app.buttons["shift_settings"], "On shift")
        try waitForServerLocation(since: startAt)
        XCTAssertFalse(app.buttons["toggle_shift"].exists, "End shift belongs in shift settings")
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        assertSwitch(app.switches["background_location"], value: "0")
        tap(app.buttons["close_shift_settings"])
        switchRole()

        login("dispatcher")
        tap(app.buttons["create_delivery"])
        assertEmptyDeliveryForm()
        selectAddress("choose_pickup", query: "Pizzeria", expected: shopName)
        XCTAssertFalse(app.buttons["submit_delivery"].isEnabled)
        selectAddress("choose_dropoff", query: "Garibaldi", expected: "Via Garibaldi 8")
        waitUntilEnabled(app.buttons["submit_delivery"])
        XCTAssertTrue(app.buttons["choose_pickup"].label.contains("Via Roma 1"))
        XCTAssertTrue(app.buttons["choose_dropoff"].label.contains("Via Garibaldi 8"))
        captureScreen("02-new-delivery", showing: app.buttons["choose_pickup"])
        tap(app.buttons["submit_delivery"])
        waitForLabel(app.staticTexts["delivery_status"], "Needs driver")
        XCTAssertFalse(app.buttons["submit_delivery"].exists, "The created delivery must replace its form")
        XCTAssertFalse(app.buttons["suggest_drivers"].exists, "Suggestions must load without another action")
        XCTAssertTrue(app.buttons["done_delivery"].exists)
        XCTAssertTrue(app.buttons["assign_driver-1"].waitForExistence(timeout: 15))
        let created = try readDeliveriesFromServer()
        XCTAssertEqual(created.count, 1, "The happy path creates exactly one delivery")
        let delivery = try XCTUnwrap(created.first)
        XCTAssertEqual(delivery.shopName, shopName)
        XCTAssertEqual(delivery.status, "pending")
        assertFixtureAddresses(delivery)
        tap(app.buttons["assign_driver-1"])
        waitUntilAbsent(app.buttons["done_delivery"])
        let deliveryRow = app.buttons["delivery_\(delivery.id)"]
        waitForLabelContaining(deliveryRow, "Assigned")
        captureScreen("01-dispatcher-jobs", showing: deliveryRow)
        // Existing jobs remain inspectable, without a redundant suggestion step.
        tap(deliveryRow)
        waitForLabel(app.staticTexts["delivery_status"], "Assigned")
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
        backToDeliveries()
        switchRole()

        login("driver1")
        waitForLabelContaining(app.buttons["shift_settings"], "On shift")
        assertRoutineDriverHome()
        XCTAssertTrue(app.buttons["resume_location"].waitForExistence(timeout: 10), "Role switching must stop location sharing")
        let resumedAt = Int(Date().timeIntervalSince1970)
        tap(app.buttons["resume_location"])
        waitUntilAbsent(app.buttons["resume_location"])
        try waitForServerLocation(since: resumedAt)
        XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists, "Show only the next stop's completion action")
        XCTAssertFalse(element("route_map").exists, "The map should start collapsed")
        captureScreen("03-driver-route", showing: app.staticTexts["next_stop_title"])
        tap(app.buttons["route_details"])
        let firstStop = element("route_stop_0")
        reveal(firstStop)
        XCTAssertTrue(firstStop.exists)
        XCTAssertTrue(element("route_map").exists)
        tap(app.buttons["route_details"])
        waitUntilAbsent(element("route_map"))

        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        assertSwitch(app.switches["background_location"], value: "0")
        captureScreen("04-driver-shift", showing: app.staticTexts["location_sent"])
        // Sharing can be paused without ending the shift, then resumed on the home screen.
        setSwitch(app.switches["share_location"], to: false)
        assertSwitch(app.switches["background_location"], value: "0")
        tap(app.buttons["close_shift_settings"])
        waitForLabelContaining(app.buttons["shift_settings"], "On shift")
        tap(app.buttons["resume_location"])
        waitUntilAbsent(app.buttons["resume_location"])
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        tap(app.buttons["close_shift_settings"])
        assertRoutineDriverHome()

        tap(app.buttons["confirm_pickup"], timeout: 15)
        XCTAssertTrue(app.buttons["confirm_dropoff"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)
        try assertServerStatus(delivery.id, "picked_up")
        tap(app.buttons["confirm_dropoff"], timeout: 15)
        XCTAssertTrue(app.staticTexts["empty_route"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
        try assertServerStatus(delivery.id, "delivered")
        let completed = element("own_delivery_\(delivery.id)")
        XCTAssertFalse(completed.exists, "Completed deliveries should start collapsed")
        tap(app.buttons["delivery_history"])
        reveal(completed)
        XCTAssertTrue(completed.exists)
        XCTAssertTrue(completed.label.contains("Delivered"))
        tap(app.buttons["delivery_history"])
        waitUntilAbsent(completed)

        tap(app.buttons["shift_settings"])
        tap(app.buttons["toggle_shift"])
        waitUntilAbsent(app.buttons["close_shift_settings"])
        waitForLabelContaining(app.buttons["shift_settings"], "Off shift")
        XCTAssertTrue(app.buttons["toggle_shift"].exists)
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "0")
        assertSwitch(app.switches["background_location"], value: "0")
        XCTAssertFalse(app.switches["share_location"].isEnabled)
        tap(app.buttons["close_shift_settings"])
        let endedDriver = try readDriverFromServer()
        XCTAssertFalse(endedDriver.active)
        switchRole()

        login("dispatcher")
        XCTAssertFalse(app.buttons["delivery_\(delivery.id)"].exists, "Completed jobs should start collapsed")
        tap(app.buttons["completed_deliveries"])
        tap(app.buttons["delivery_\(delivery.id)"])
        waitForLabel(app.staticTexts["delivery_status"], "Delivered")
        XCTAssertFalse(app.buttons["suggest_drivers"].exists)
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
        XCTAssertFalse(app.buttons["change_driver"].exists)
        backToDeliveries()
        try verifyPendingDeliveryCanBeReopened()
    }

    func testAddressSearchCancellationAndStaleResults() {
        login("dispatcher")
        tap(app.buttons["create_delivery"])
        assertEmptyDeliveryForm()
        tap(app.buttons["choose_pickup"])
        let search = app.textFields["address_search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        replace(search, with: "Pizzeria")
        waitForLabelContaining(app.buttons["address_result_0"], shopName)
        // A short/empty query must remove previously valid results, even after debounce.
        replace(search, with: "xx")
        waitUntilAbsent(app.buttons["address_result_0"])
        replace(search, with: "Garibaldi")
        waitForLabelContaining(app.buttons["address_result_0"], "Via Garibaldi 8")
        XCTAssertFalse(app.buttons["address_result_0"].label.contains(shopName))
        replace(search, with: "")
        waitUntilAbsent(app.buttons["address_result_0"])
        tap(app.buttons["cancel_address"])
        assertEmptyDeliveryForm()

        selectAddress("choose_pickup", query: "Pizzeria", expected: shopName)
        let selectedPickup = app.buttons["choose_pickup"].label
        tap(app.buttons["choose_pickup"])
        replace(app.textFields["address_search"], with: "Garibaldi")
        waitForLabelContaining(app.buttons["address_result_0"], "Via Garibaldi 8")
        tap(app.buttons["cancel_address"])
        XCTAssertEqual(app.buttons["choose_pickup"].label, selectedPickup, "Cancel must preserve the selected address")
        XCTAssertFalse(app.buttons["submit_delivery"].isEnabled)

        tap(app.buttons["choose_dropoff"])
        replace(app.textFields["address_search"], with: "No matching address")
        XCTAssertTrue(app.staticTexts["address_empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["address_result_0"].exists)
        tap(app.buttons["cancel_address"])
        XCTAssertFalse(app.buttons["submit_delivery"].isEnabled)
        selectAddress("choose_dropoff", query: "Garibaldi", expected: "Via Garibaldi 8")
        waitUntilEnabled(app.buttons["submit_delivery"])
        let selectedDropoff = app.buttons["choose_dropoff"].label
        tap(app.buttons["choose_dropoff"])
        tap(app.buttons["cancel_address"])
        XCTAssertEqual(app.buttons["choose_dropoff"].label, selectedDropoff)
        XCTAssertTrue(app.buttons["submit_delivery"].isEnabled)
        tap(app.buttons["cancel_delivery"])
        waitUntilAbsent(app.buttons["cancel_delivery"])
        tap(app.buttons["create_delivery"])
        assertEmptyDeliveryForm()
        tap(app.buttons["cancel_delivery"])
    }

    func testCancelCreationAndRejectRemoteServer() {
        XCTAssertFalse(app.textFields["api_url"].exists, "Demo setup should not compete with role selection")
        login("dispatcher")
        for _ in 0..<2 {
            tap(app.buttons["create_delivery"])
            assertEmptyDeliveryForm()
            tap(app.buttons["choose_pickup"])
            tap(app.buttons["cancel_address"])
            tap(app.buttons["cancel_delivery"])
            waitUntilAbsent(app.buttons["cancel_delivery"])
            XCTAssertTrue(app.buttons["create_delivery"].isHittable)
        }
        switchRole()
        tap(app.buttons["demo_settings"])
        replace(app.textFields["api_url"], with: "http://example.com")
        tap(app.buttons["login_dispatcher"])
        XCTAssertTrue(app.alerts["Couldn’t complete that"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "loopback")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["login_dispatcher"].exists)
    }

    @MainActor
    private func verifyPendingDeliveryCanBeReopened() throws {
        let before = try readDeliveriesFromServer()
        let previousIDs = Set(before.map(\.id))
        tap(app.buttons["create_delivery"])
        assertEmptyDeliveryForm()
        selectAddress("choose_pickup", query: "Pizzeria", expected: shopName)
        selectAddress("choose_dropoff", query: "Garibaldi", expected: "Via Garibaldi 8")
        let submit = app.buttons["submit_delivery"]
        waitUntilEnabled(submit)
        // Repeated creation taps must not create two jobs while the sheet advances.
        submit.doubleTap()
        waitForLabel(app.staticTexts["delivery_status"], "Needs driver")
        XCTAssertTrue(element("no_suggestions").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["submit_delivery"].exists)
        XCTAssertFalse(app.buttons["cancel_delivery"].exists)
        let after = try readDeliveriesFromServer()
        XCTAssertEqual(after.count, before.count + 1)
        let pending = try XCTUnwrap(after.first { !previousIDs.contains($0.id) })
        XCTAssertEqual(pending.status, "pending")
        assertFixtureAddresses(pending)
        tap(app.buttons["done_delivery"])
        waitUntilAbsent(app.buttons["done_delivery"])
        for _ in 0..<2 {
            tap(app.buttons["delivery_\(pending.id)"])
            waitForLabel(app.staticTexts["delivery_status"], "Needs driver")
            XCTAssertTrue(element("no_suggestions").waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["submit_delivery"].exists)
            XCTAssertFalse(app.buttons["suggest_drivers"].exists)
            backToDeliveries()
        }
        let reopened = try readDeliveriesFromServer()
        XCTAssertEqual(Set(reopened.map(\.id)), Set(after.map(\.id)), "Reopening a created job must retain its ID")
    }

    private func assertEmptyDeliveryForm() {
        XCTAssertTrue(app.buttons["choose_pickup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose_pickup"].label.contains("Choose an address"))
        XCTAssertTrue(app.buttons["choose_dropoff"].label.contains("Choose an address"))
        XCTAssertFalse(app.buttons["submit_delivery"].isEnabled)
        XCTAssertEqual(app.textFields.count, 0, "Routine creation should use address selections, not raw text or coordinates")
        XCTAssertEqual(app.steppers.count, 0, "Capacity and load tuning should not be routine form controls")
        XCTAssertFalse(element("ready_at").exists, "Custom timing should start collapsed")
        XCTAssertFalse(element("deadline_at").exists)
    }

    private func assertRoutineDriverHome() {
        XCTAssertTrue(app.buttons["shift_settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["share_location"].exists)
        XCTAssertFalse(app.switches["background_location"].exists)
        XCTAssertEqual(app.textFields.count, 0, "Coordinates do not belong on the driver home screen")
        XCTAssertEqual(app.steppers.count, 0, "Capacity tuning belongs outside the routine driver flow")
    }

    private func selectAddress(_ button: String, query: String, expected: String) {
        tap(app.buttons[button])
        replace(app.textFields["address_search"], with: query)
        let result = app.buttons["address_result_0"]
        waitForLabelContaining(result, expected)
        tap(result)
        waitUntilAbsent(app.textFields["address_search"])
        XCTAssertTrue(app.buttons[button].label.contains(expected))
    }

    private struct ServerCoordinate: Decodable { let lat: Double; let lng: Double }
    private struct ServerDriver: Decodable {
        let active: Bool
        let location: ServerCoordinate?
        let locationUpdatedAt: Int?
    }
    private struct ServerDelivery: Decodable {
        let id: String
        let shopName: String
        let status: String
        let pickupAddress: String
        let pickup: ServerCoordinate
        let dropoffAddress: String
        let dropoff: ServerCoordinate
    }

    /// Keep UI tests synchronous: XCTest's stop-on-failure unwinds the current test,
    /// whereas throwing its assertion exception through an async task can cascade or crash.
    private final class ServerResponse: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<(Data, URLResponse), Error>?

        func store(_ value: Result<(Data, URLResponse), Error>) {
            lock.lock()
            defer { lock.unlock() }
            result = value
        }

        func load() -> Result<(Data, URLResponse), Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private func readServer<T: Decodable>(_ path: String, token: String) throws -> T {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let completed = XCTestExpectation(description: "Read \(path) from the real API")
        let responseBox = ServerResponse()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { responseBox.store(.failure(error)) }
            else if let data, let response { responseBox.store(.success((data, response))) }
            else {
                responseBox.store(.failure(NSError(domain: "DeliveryFlowUITests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The API returned no response for \(path)"])))
            }
            completed.fulfill()
        }
        task.resume()
        guard XCTWaiter.wait(for: [completed], timeout: 8) == .completed else {
            task.cancel()
            throw NSError(domain: "DeliveryFlowUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The API read timed out: \(path)"])
        }
        let result = try XCTUnwrap(responseBox.load())
        let (data, response) = try result.get()
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Server read failed: \(String(decoding: data, as: UTF8.self))")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func readDriverFromServer() throws -> ServerDriver {
        try readServer("v1/shift", token: "demo-driver-1")
    }

    private func readDeliveriesFromServer() throws -> [ServerDelivery] {
        try readServer("v1/deliveries", token: "demo-dispatcher")
    }

    private func assertServerStatus(_ id: String, _ status: String) throws {
        let deliveries = try readDeliveriesFromServer()
        XCTAssertEqual(deliveries.first { $0.id == id }?.status, status)
    }

    private func assertFixtureAddresses(_ delivery: ServerDelivery) {
        XCTAssertEqual(delivery.pickupAddress, "Via Roma 1, Pachino")
        XCTAssertEqual(delivery.pickup.lat, 36.7163, accuracy: 0.000001)
        XCTAssertEqual(delivery.pickup.lng, 15.0908, accuracy: 0.000001)
        XCTAssertEqual(delivery.dropoffAddress, "Via Garibaldi 8, Pachino")
        XCTAssertEqual(delivery.dropoff.lat, 36.721, accuracy: 0.000001)
        XCTAssertEqual(delivery.dropoff.lng, 15.1, accuracy: 0.000001)
    }

    private func waitForServerLocation(since timestamp: Int) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let driver = try readDriverFromServer()
            if let location = driver.location, let updated = driver.locationUpdatedAt, updated >= timestamp {
                XCTAssertTrue(driver.active)
                XCTAssertEqual(location.lat, 36.7163, accuracy: 0.000001)
                XCTAssertEqual(location.lng, 15.0908, accuracy: 0.000001)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("The app did not persist a fresh deterministic Pachino location to the real API after explicit location sharing")
    }

    /// Names are a stable export contract for GitHub Actions, including successful runs.
    private func captureScreen(_ name: String, showing element: XCUIElement) {
        reveal(element)
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        XCTAssertTrue(element.isHittable, "Screenshot anchor must be visible: \(name)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func login(_ role: String) {
        tap(app.buttons["login_\(role)"])
        let destination = role == "dispatcher" ? app.buttons["create_delivery"] : app.buttons["shift_settings"]
        XCTAssertTrue(destination.waitForExistence(timeout: 20), "Check the running Rust API and fresh database")
    }

    private func switchRole() {
        tap(app.buttons["switch_role"])
        XCTAssertTrue(app.buttons["login_dispatcher"].waitForExistence(timeout: 5))
    }

    private func backToDeliveries() {
        tap(app.navigationBars.buttons.element(boundBy: 0))
        waitUntilAbsent(app.staticTexts["delivery_status"])
        XCTAssertTrue(app.buttons["create_delivery"].waitForExistence(timeout: 5))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        if !element.exists { _ = element.waitForExistence(timeout: min(timeout, 3)) }
        reveal(element)
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: timeout))
        waitUntilEnabled(element, timeout: timeout)
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) {
        if element.exists && element.isHittable && element.isEnabled { return }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
    }

    private func waitUntilAbsent(_ element: XCUIElement) {
        if !element.exists { return }
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed)
    }

    private func assertSwitch(_ element: XCUIElement, value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertEqual(element.value as? String, value)
    }

    private func setSwitch(_ element: XCUIElement, to enabled: Bool) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        reveal(element)
        let target = enabled ? "1" : "0"
        if element.value as? String != target {
            // SwiftUI exposes both a label+control row and the native child switch.
            let nativeSwitch = element.switches.firstMatch
            if nativeSwitch.exists && nativeSwitch.isHittable { nativeSwitch.tap() }
            else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", target), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed,
                       "Switch did not reach \(target): \(element.debugDescription)")
    }

    private func reveal(_ element: XCUIElement) {
        // Checking existence first avoids XCTest's repeated lookup retries for missing IDs.
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
    }

    private func replace(_ field: XCUIElement, with value: String) {
        tap(field)
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        if !value.isEmpty { field.typeText(value) }
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) {
        if element.exists && element.label == label { return }
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed)
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ label: String) {
        if element.exists && element.label.contains(label) { return }
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed)
    }
}
