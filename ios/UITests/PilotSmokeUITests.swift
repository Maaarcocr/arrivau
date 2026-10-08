import XCTest

/// Two short native checks for ordinary CI. Run against a fresh, disposable demo API.
/// Login, restaurant naming, shift, logout and next-stop actions use the real UI
/// and HTTP backend; fixture HTTP calls replace the longer delivery/readiness journey.
final class PilotSmokeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var apiURL: URL!
    private var session: URLSession!
    private let token = "demo-dual"
    private let driverID = "dual-1"
    private let shopName = "Smoke Test Pizzeria"
    private let pickupPlaceID = "arrivau-test-pachino-pickup"
    private let dropoffPlaceID = "arrivau-test-pachino-dropoff"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let configured = ProcessInfo.processInfo.environment["ARRIVAU_API_URL"] ?? "http://127.0.0.1:8080"
        var endpoint = try XCTUnwrap(URLComponents(string: configured))
        guard endpoint.scheme == "http",
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(endpoint.host ?? ""),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/" else {
            throw failure("Smoke fixture writes require an HTTP loopback origin and a fresh demo database")
        }
        // The CI demo server binds IPv4; avoid localhost's IPv6 fallback.
        if endpoint.host == "localhost" { endpoint.host = "127.0.0.1" }
        apiURL = try XCTUnwrap(endpoint.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, app?.state == .runningForeground { capture("pilot-smoke-failure") }
        app?.terminate()
        session?.invalidateAndCancel()
    }

    func testPilotLoginAndSeparateInviteEntry() {
        // The production-style form is isolated from saved sessions. No credentials
        // are entered and its invalid HTTP endpoint cannot be used for pilot login.
        launch("--pilot-uitesting", endpoint: "http://api.example.com")
        XCTAssertTrue(app.textFields["login_username"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["login_password"].exists)
        XCTAssertFalse(app.buttons["login_submit"].isEnabled)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["login_dual"].exists)
        XCTAssertFalse(app.buttons["login_dispatcher"].exists)
        XCTAssertFalse(app.buttons["login_driver1"].exists)
        XCTAssertFalse(element("role_picker").exists)
        XCTAssertFalse(app.textFields["api_url"].exists)
        XCTAssertFalse(app.textFields["invite_input"].exists)
        capture("ux-pilot-login", showing: app.buttons["show_invite_entry"])

        tap(app.buttons["show_invite_entry"])
        XCTAssertTrue(app.textFields["invite_input"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["open_invite"].isEnabled)
        XCTAssertFalse(app.textFields["invite_api_url"].exists)
        XCTAssertFalse(app.textFields["api_url"].exists)
        capture("ux-invite-entry", showing: app.textFields["invite_input"])
        tap(app.buttons["close_invite_entry"])
        waitUntilAbsent(app.textFields["invite_input"])
        XCTAssertTrue(app.textFields["login_username"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["show_invite_entry"].isHittable)
        XCTAssertFalse(app.buttons["login_submit"].isEnabled)
        XCTAssertFalse(app.textFields["api_url"].exists, "Cancelling an invite must retain ordinary configured-endpoint login")
    }

    func testDualAccountShiftLogoutAndNextStop() throws {
        let identity: Principal = try read("v1/me")
        XCTAssertEqual(identity.id, driverID)
        XCTAssertEqual(identity.teamId, "demo-review")
        XCTAssertEqual(Set(identity.roles), Set(["dispatcher", "driver"]))
        let initialDriver: Driver = try read("v1/shift")
        let initialDeliveries: [Delivery] = try read("v1/deliveries")
        XCTAssertEqual(initialDriver.id, driverID)
        XCTAssertFalse(initialDriver.active, "Run smoke tests against a fresh demo database")
        XCTAssertNil(initialDriver.location)
        XCTAssertTrue(initialDeliveries.isEmpty, "Run smoke tests separately from the full UI suite")

        launch("--uitesting", endpoint: apiURL.absoluteString)
        loginDualAccount()
        let restaurant = try createRestaurantPreservingName()
        selectRole("driver")
        waitForLabel(app.buttons["shift_settings"], containing: "Fuori turno")
        XCTAssertEqual(app.buttons["toggle_shift"].label, "Avvia turno e condividi posizione")
        let consent = app.staticTexts["shift_location_consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertTrue(consent.label.contains("anche a schermo bloccato"))
        XCTAssertTrue(consent.isHittable, "Consent must be visible before starting a shift")
        capture("ux-shift-consent", showing: app.buttons["toggle_shift"])

        let startedAt = Int(Date().timeIntervalSince1970)
        tap(app.buttons["toggle_shift"])
        waitForLabel(app.buttons["shift_settings"], containing: "In turno")
        try waitForLocation(since: startedAt)
        XCTAssertFalse(app.buttons["toggle_shift"].exists, "Ending a shift belongs in shift settings")
        tap(app.buttons["shift_settings"])
        assertSharing(foreground: "1", background: "1")
        capture("ux-new-shift", showing: app.switches["background_location"])
        tap(app.buttons["close_shift_settings"])
        waitUntilAbsent(app.buttons["close_shift_settings"])
        capture("ux-driver-waiting", showing: app.staticTexts["empty_route"])

        let delivery = try seedAssignedDelivery(restaurant: restaurant)
        selectRole("dispatcher")
        waitForLabel(app.buttons["delivery_\(delivery.id)"], containing: "Assegnata")
        XCTAssertTrue(element("account_location_sharing").exists,
                      "Same-account role changes must retain the explicit sharing consent")
        capture("dual-account-centrale", showing: app.buttons["role_dispatcher"])
        assertDispatcherDriverScreens(deliveryID: delivery.id, completed: false)
        selectRole("driver")
        waitForLabel(app.staticTexts["next_stop_title"], containing: shopName)
        XCTAssertTrue(app.buttons["confirm_pickup"].isHittable,
                      "The next-stop action must be visible without expanding the route")
        let overview = element("route_map")
        XCTAssertTrue(overview.exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "route_map").count, 1,
                       "The route map must expose one unambiguous overview container")
        XCTAssertGreaterThanOrEqual(overview.frame.height, 170,
                                    "Measure the overview container, not an inherited-ID icon")
        XCTAssertTrue(app.frame.contains(overview.frame), "The whole overview must be visible with the next action")
        XCTAssertTrue(element("route_map_test_mode").waitForExistence(timeout: 5),
                      "Google-source stops must use the deterministic Google overview branch")
        XCTAssertTrue(app.buttons["open_directions"].isEnabled,
                      "The seeded next stop must remain eligible for the Google navigation source")
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
        capture("dual-account-corriere", showing: app.staticTexts["next_stop_title"])

        tap(app.buttons["switch_role"])
        XCTAssertTrue(app.buttons["account_logout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["team_identity"].label.contains("Squadra revisione"))
        XCTAssertFalse(app.buttons["account_settings"].exists, "Public demo identities cannot delete accounts")
        capture("ux-account", showing: app.buttons["account_logout"])
        tap(app.buttons["account_logout"])
        XCTAssertTrue(activeLogoutAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(activeLogoutAlert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Il turno e le consegne restano attivi"
        )).firstMatch.exists)
        capture("ux-active-logout")
        tapLogoutAlertButton("Annulla")
        XCTAssertTrue(app.buttons["account_logout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["login_dual"].exists, "Cancel must leave the same account signed in")
        try assertActiveAssignment(delivery.id)
        tap(app.buttons["close_account"])
        waitUntilAbsent(app.buttons["account_logout"])
        XCTAssertTrue(element("account_location_sharing").exists,
                      "Cancelling logout must preserve the existing local sharing consent")
        tap(app.buttons["switch_role"])

        // Regression: exercise the real native alert action exactly once. Do not
        // gate this tap on nested-sheet hittability or fall back to coordinates.
        tap(app.buttons["account_logout"])
        tapLogoutAlertButton("Esci")
        XCTAssertTrue(app.buttons["login_dual"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("role_picker").exists)
        XCTAssertFalse(app.buttons["account_logout"].exists)
        try assertActiveAssignment(delivery.id)

        loginDualAccount()
        selectRole("driver")
        waitForLabel(app.buttons["shift_settings"], containing: "In turno")
        XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("account_location_sharing").exists,
                       "Login must never silently restore the previous location consent")
        tap(app.buttons["shift_settings"])
        assertSharing(foreground: "0", background: "0")
        tap(app.buttons["close_shift_settings"])
        waitUntilAbsent(app.buttons["close_shift_settings"])

        tap(app.buttons["confirm_pickup"])
        XCTAssertTrue(app.buttons["confirm_dropoff"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)
        try assertStatus(delivery.id, "picked_up", stops: ["dropoff"])
        tap(app.buttons["confirm_dropoff"])
        XCTAssertTrue(app.staticTexts["empty_route"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
        try assertStatus(delivery.id, "delivered", stops: [])
        selectRole("dispatcher")
        assertDispatcherDriverScreens(deliveryID: delivery.id, completed: true)
        tap(app.buttons["dispatcher_drivers"])
        tap(app.buttons["driver_\(driverID)"])
        tap(app.buttons["driver_deliveries"])
        tap(app.buttons["history_delivery_\(delivery.id)"])
        tap(app.buttons["delete_delivery"])
        tap(app.buttons.matching(identifier: "cancel_delete_delivery").firstMatch)
        XCTAssertTrue(app.buttons["delete_delivery"].waitForExistence(timeout: 5))
        try assertStatus(delivery.id, "delivered", stops: [])
        tap(app.buttons["delete_delivery"])
        tap(app.buttons.matching(identifier: "confirm_delete_delivery").firstMatch)
        XCTAssertTrue(element("dispatcher_driver_history").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["history_delivery_\(delivery.id)"].exists)
        let remaining: [Delivery] = try read("v1/deliveries")
        XCTAssertFalse(remaining.contains { $0.id == delivery.id })
        navigateBack(to: app.buttons["driver_deliveries"])
        navigateBack(to: app.buttons["driver_\(driverID)"])
        navigateBack(to: app.buttons["create_delivery"])
        selectRole("driver")
        tap(app.buttons["shift_settings"])
        tap(app.buttons["toggle_shift"])
        waitUntilAbsent(app.buttons["close_shift_settings"])
        waitForLabel(app.buttons["shift_settings"], containing: "Fuori turno")
        XCTAssertTrue(app.buttons["toggle_shift"].exists)
        let ended: Driver = try read("v1/shift")
        XCTAssertFalse(ended.active)
        let finalIdentity: Principal = try read("v1/me")
        XCTAssertEqual(finalIdentity, identity)
    }

    private func assertDispatcherDriverScreens(deliveryID: String, completed: Bool) {
        assertRole("dispatcher")
        tap(app.buttons["dispatcher_drivers"])
        tap(app.buttons["driver_\(driverID)"])
        XCTAssertTrue(app.buttons["driver_deliveries"].waitForExistence(timeout: 5))
        tap(app.buttons["driver_live_route"])
        let liveRoute = element("dispatcher_driver_live_route")
        XCTAssertTrue(liveRoute.waitForExistence(timeout: 5))
        if completed {
            XCTAssertTrue(element("driver_route_empty").waitForExistence(timeout: 10))
            XCTAssertFalse(element("dispatcher_route_stop_0").exists)
        } else {
            XCTAssertTrue(element("route_map").waitForExistence(timeout: 10))
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "route_map").count, 1)
            XCTAssertTrue(element("route_map_test_mode").waitForExistence(timeout: 5))
            let pickup = element("dispatcher_route_stop_0")
            reveal(pickup, in: liveRoute)
            waitForLabel(pickup, containing: "Ritiro")
            let dropoff = element("dispatcher_route_stop_1")
            reveal(dropoff, in: liveRoute)
            waitForLabel(dropoff, containing: "Consegna")
            XCTAssertFalse(element("driver_route_empty").exists)
        }
        navigateBack(to: app.buttons["driver_live_route"])
        tap(app.buttons["driver_deliveries"])
        let history = element("dispatcher_driver_history")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let section = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", completed ? "Completate" : "In corso"
        )).firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        let row = app.buttons["history_delivery_\(deliveryID)"]
        reveal(row, in: history)
        waitForLabel(row, containing: shopName)
        XCTAssertTrue(row.label.contains(completed ? "Consegnata" : "Assegnata"))
        if completed {
            // The completion date belongs to this delivery, not just the screen title.
            waitForLabel(element("history_completed_at_\(deliveryID)"), containing: "Consegnata il")
        }
        tap(row)
        waitForLabel(app.staticTexts["delivery_status"], containing: completed ? "Consegnata" : "Assegnata")
        navigateBack(to: history)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Back from details must retain the selected driver's history")
        navigateBack(to: app.buttons["driver_deliveries"])
        // Reopen the route after visiting history to catch stale destination state.
        tap(app.buttons["driver_live_route"])
        XCTAssertTrue(liveRoute.waitForExistence(timeout: 5))
        XCTAssertTrue(element(completed ? "driver_route_empty" : "dispatcher_route_stop_0")
            .waitForExistence(timeout: 10))
        navigateBack(to: app.buttons["driver_live_route"])
        navigateBack(to: app.buttons["driver_\(driverID)"])
        navigateBack(to: app.buttons["create_delivery"])
        assertRole("dispatcher")
    }

    private func navigateBack(to destination: XCUIElement) {
        tap(app.navigationBars.buttons["BackButton"])
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
    }

    private func reveal(_ target: XCUIElement, in scrollView: XCUIElement) {
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if target.exists && target.isHittable { return }
            scrollView.swipeUp()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Expected fixture row must be visible")
    }

    private func createRestaurantPreservingName() throws -> Restaurant {
        tap(app.buttons["create_delivery"])
        tap(app.buttons["choose_pickup"])
        tap(app.buttons["add_restaurant"])
        let name = app.textFields["restaurant_name"]
        tap(name)
        name.typeText("Nome iniziale")
        chooseRestaurantAddress(query: "Garibaldi", expected: "Via Garibaldi 8")
        XCTAssertEqual(name.value as? String, "Nome iniziale",
                       "Selecting the first address must preserve an already entered name")

        tap(name)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Nome iniziale".count) + shopName)
        chooseRestaurantAddress(query: "Pizzeria", expected: "Pizzeria Pachino Demo")
        XCTAssertEqual(name.value as? String, shopName,
                       "Changing address must preserve the latest manually edited name")
        let address = app.buttons["restaurant_address"].label
        XCTAssertTrue(address.contains("Via Roma 1, Pachino"))
        tap(app.buttons["restaurant_address"])
        tap(app.buttons["cancel_address"])
        waitUntilAbsent(app.textFields["address_search"])
        XCTAssertEqual(name.value as? String, shopName)
        XCTAssertEqual(app.buttons["restaurant_address"].label, address)

        tap(app.buttons["save_restaurant"])
        waitUntilAbsent(app.buttons["cancel_restaurant_picker"])
        waitForLabel(app.buttons["choose_pickup"], containing: shopName)
        let saved: [Restaurant] = try read("v1/restaurants")
        XCTAssertEqual(saved.count, 1)
        let restaurant = try XCTUnwrap(saved.first)
        XCTAssertEqual(restaurant.name, shopName)
        XCTAssertEqual(restaurant.address, "Via Roma 1, Pachino")
        XCTAssertEqual(restaurant.googlePlaceId, pickupPlaceID)
        tap(app.buttons["cancel_delivery"])

        // A fresh app session must load the same independent name/address from
        // the real API, not merely display the form's local state after saving.
        app.terminate()
        launch("--uitesting", endpoint: apiURL.absoluteString)
        loginDualAccount()
        tap(app.buttons["create_delivery"])
        tap(app.buttons["choose_pickup"])
        let row = app.buttons["restaurant_\(restaurant.id)"]
        waitForLabel(row, containing: shopName)
        XCTAssertTrue(row.label.contains(restaurant.address))
        XCTAssertEqual(app.buttons.matching(identifier: "restaurant_\(restaurant.id)").count, 1)
        tap(row)
        waitUntilAbsent(app.buttons["cancel_restaurant_picker"])
        waitForLabel(app.buttons["choose_pickup"], containing: shopName)
        tap(app.buttons["cancel_delivery"])
        return restaurant
    }

    private func chooseRestaurantAddress(query: String, expected: String) {
        tap(app.buttons["restaurant_address"])
        let search = app.textFields["address_search"]
        tap(search)
        search.typeText(query)
        let result = app.buttons["address_result_0"]
        waitForLabel(result, containing: expected)
        tap(result)
        waitUntilAbsent(search)
    }

    private func launch(_ mode: String, endpoint: String) {
        app.launchArguments = [mode, "-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
        app.launchEnvironment["ARRIVAU_API_URL"] = endpoint
        app.launch()
    }

    private func loginDualAccount() {
        tap(app.buttons["login_dual"])
        XCTAssertTrue(app.buttons["create_delivery"].waitForExistence(timeout: 20),
                      "The demo login must reach the real API-backed account")
        assertRole("dispatcher")
    }

    private func selectRole(_ role: String) {
        let button = app.buttons["role_\(role)"]
        tap(button)
        let destination = app.buttons[role == "driver" ? "shift_settings" : "create_delivery"]
        wait("Switch to \(role)") {
            button.exists && (button.value as? String) == "Selezionato" && destination.exists
        }
        assertRole(role)
    }

    private func assertRole(_ role: String) {
        XCTAssertTrue(element("role_picker").exists)
        XCTAssertEqual(app.buttons["role_\(role)"].value as? String, "Selezionato")
        let other = role == "driver" ? "dispatcher" : "driver"
        XCTAssertEqual(app.buttons["role_\(other)"].value as? String, "Non selezionato")
        XCTAssertFalse(app.staticTexts["team_identity"].exists, "Team details belong in Account")
        XCTAssertFalse(app.buttons["login_dual"].exists)
    }

    private var activeLogoutAlert: XCUIElement { app.alerts["Uscire con un turno attivo?"] }

    private func tapLogoutAlertButton(_ title: String) {
        XCTAssertTrue(activeLogoutAlert.waitForExistence(timeout: 5))
        // iOS exposes the SwiftUI alert action as nested button wrappers with
        // the same identifier. Select that one action, not an ambiguous label query.
        let identifier = title == "Esci" ? "confirm_logout" : "cancel_logout"
        let button = activeLogoutAlert.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(button.label, title)
        button.tap()
        wait("One native \(title) tap dismisses the logout alert") { !self.app.alerts.firstMatch.exists }
    }

    private func assertSharing(foreground: String, background: String) {
        XCTAssertTrue(app.switches["share_location"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["share_location"].value as? String, foreground)
        XCTAssertEqual(app.switches["background_location"].value as? String, background)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ element: XCUIElement) {
        wait("Control exists, is enabled and is hittable") {
            element.exists && element.isEnabled && element.isHittable
        }
        element.tap()
    }

    private func waitUntilAbsent(_ element: XCUIElement) {
        // Reading snapshot properties (including identifier) after dismissal
        // fails before XCTest can evaluate the disappearance condition.
        wait("Element disappears after dismissal") { !element.exists }
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String) {
        wait("Show \(text)") { element.exists && element.label.contains(text) }
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, until condition: @escaping () -> Bool) {
        if condition() { return }
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, description)
    }

    /// Stable screenshot names are the export contract, including successful runs.
    private func capture(_ name: String, showing anchor: XCUIElement? = nil) {
        if let anchor {
            XCTAssertTrue(anchor.waitForExistence(timeout: 10))
            XCTAssertTrue(anchor.isHittable, "Screenshot anchor must already be visible: \(name)")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Coordinate: Codable { let lat: Double; let lng: Double }
    private struct Principal: Decodable, Equatable { let id: String; let roles: [String]; let teamId: String }
    private struct Driver: Decodable {
        let id: String
        let active: Bool
        let location: Coordinate?
        let locationUpdatedAt: Int?
    }
    private struct Delivery: Decodable {
        let id: String
        let shopName: String
        let pickupAddress: String
        let status: String
        let driverId: String?
        let readinessState: String
        let readinessRevision: Int
        let pickupGooglePlaceId: String
        let dropoffGooglePlaceId: String
    }
    private struct NewDelivery: Encodable {
        let restaurantId: String
        let shopName: String
        let pickupAddress: String
        let pickupGooglePlaceId: String
        let dropoffAddress: String
        let dropoffGooglePlaceId: String
        let deadlineAt: Int
        let loadUnits = 1
        let maxRideSeconds = 1800
    }
    private struct Readiness: Encodable { let readyInMinutes = 0; let expectedRevision: Int }
    private struct Restaurant: Decodable {
        let id: String
        let name: String
        let address: String
        let googlePlaceId: String
    }
    private struct Route: Decodable {
        struct Stop: Decodable { let deliveryId: String; let kind: String; let googlePlaceId: String }
        let driverId: String
        let stops: [Stop]
    }

    private func seedAssignedDelivery(restaurant: Restaurant) throws -> Delivery {
        // Existing demo-only Place IDs match the UI address-search fixtures. The
        // API resolves them locally without Google calls (api/src/places.rs).
        // Omitting ready_at is the supported new-client contract: unknown until ready.
        let body = NewDelivery(restaurantId: restaurant.id, shopName: restaurant.name,
            pickupAddress: restaurant.address, pickupGooglePlaceId: pickupPlaceID,
            dropoffAddress: "Via Garibaldi 8, Pachino (fixture)", dropoffGooglePlaceId: dropoffPlaceID,
            deadlineAt: Int(Date().timeIntervalSince1970) + 3600)
        let created: Delivery = try post("v1/deliveries", body: body, expectedStatus: 201)
        XCTAssertEqual(created.status, "pending")
        XCTAssertEqual(created.readinessState, "unknown")
        XCTAssertEqual(created.shopName, shopName)
        XCTAssertEqual(created.pickupAddress, restaurant.address)
        XCTAssertEqual(created.pickupGooglePlaceId, pickupPlaceID)
        XCTAssertEqual(created.dropoffGooglePlaceId, dropoffPlaceID)
        let assigned: Delivery = try post("v1/deliveries/\(created.id)/readiness",
            body: Readiness(expectedRevision: created.readinessRevision))
        XCTAssertEqual(assigned.id, created.id)
        XCTAssertEqual(assigned.status, "assigned")
        XCTAssertEqual(assigned.driverId, driverID)
        try assertActiveAssignment(assigned.id)
        return assigned
    }

    private func assertActiveAssignment(_ id: String) throws {
        let driver: Driver = try read("v1/shift")
        XCTAssertEqual(driver.id, driverID)
        XCTAssertTrue(driver.active, "Logout and cancellation must preserve the server-side shift")
        try assertStatus(id, "assigned", stops: ["pickup", "dropoff"])
    }

    private func assertStatus(_ id: String, _ status: String, stops: [String]) throws {
        let deliveries: [Delivery] = try read("v1/deliveries")
        XCTAssertEqual(deliveries.count, 1)
        let delivery = try XCTUnwrap(deliveries.first { $0.id == id })
        XCTAssertEqual(delivery.status, status)
        XCTAssertEqual(delivery.driverId, driverID)
        let route: Route = try read("v1/route")
        XCTAssertEqual(route.driverId, driverID)
        XCTAssertEqual(route.stops.map(\.kind), stops)
        XCTAssertEqual(route.stops.map(\.deliveryId), Array(repeating: id, count: stops.count))
        XCTAssertEqual(route.stops.map(\.googlePlaceId), stops.map { $0 == "pickup" ? pickupPlaceID : dropoffPlaceID })
    }

    private func waitForLocation(since timestamp: Int) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let driver: Driver = try read("v1/shift")
            if let point = driver.location, let updated = driver.locationUpdatedAt, updated >= timestamp {
                XCTAssertTrue(driver.active)
                XCTAssertEqual(point.lat, 36.7163, accuracy: 0.000001)
                XCTAssertEqual(point.lng, 15.0908, accuracy: 0.000001)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("The explicit shift start did not persist its simulated location to the real API")
    }

    private func read<T: Decodable>(_ path: String) throws -> T {
        try request("GET", path: path)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, expectedStatus: Int = 200) throws -> T {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try request("POST", path: path, body: encoder.encode(body), expectedStatus: expectedStatus)
    }

    private func request<T: Decodable>(_ method: String, path: String, body: Data? = nil, expectedStatus: Int = 200) throws -> T {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        let completed = XCTestExpectation(description: "\(method) \(path) on the disposable demo API")
        let box = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error { box.store(.failure(error)) }
            else if let data, let response { box.store(.success((data, response))) }
            else { box.store(.failure(NSError(domain: "PilotSmokeUITests", code: 1))) }
            completed.fulfill()
        }
        task.resume()
        guard XCTWaiter.wait(for: [completed], timeout: 8) == .completed else {
            task.cancel()
            throw failure("Demo API request timed out: \(method) \(path)")
        }
        let result = try XCTUnwrap(box.load())
        let (data, response) = try result.get()
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == expectedStatus else {
            throw failure("\(method) \(path): expected HTTP \(expectedStatus), got \(status ?? 0)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Keep assertions synchronous; protect URLSession's completion result across threads.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<(Data, URLResponse), Error>?
        func store(_ value: Result<(Data, URLResponse), Error>) {
            lock.lock(); defer { lock.unlock() }
            result = value
        }
        func load() -> Result<(Data, URLResponse), Error>? {
            lock.lock(); defer { lock.unlock() }
            return result
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PilotSmokeUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
