import XCTest

/// Requires a real Rust API with a fresh empty demo database on localhost:8080.
/// Only sensor input and address search are deterministic; delivery and shift actions use HTTP.
final class DeliveryFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var apiURL: URL!
    private let shopName = "Pizzeria Pachino Demo"
    private let dualToken = "demo-dual"
    private let dualDriverID = "dual-1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
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
        captureScreen("00-login", showing: app.buttons["login_driver1"])
        login("driver1")
        let start = app.buttons["toggle_shift"]
        XCTAssertEqual(start.label, "Avvia turno e condividi posizione", "Run against a fresh demo database")
        waitForLabelContaining(app.buttons["shift_settings"], "Fuori turno")
        assertRoutineDriverHome()
        let startAt = Int(Date().timeIntervalSince1970)
        tap(start)
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        try waitForServerLocation(since: startAt)
        XCTAssertFalse(app.buttons["toggle_shift"].exists, "End shift belongs in shift settings")
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        assertSwitch(app.switches["background_location"], value: "1")
        captureScreen("ux-new-shift", showing: app.switches["background_location"])
        tap(app.buttons["close_shift_settings"])
        captureScreen("ux-driver-waiting", showing: app.staticTexts["empty_route"])
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
        // Expanding timing repeatedly must not change the selected addresses or submit state.
        for iteration in 0..<2 {
            tap(app.buttons["delivery_timing"])
            XCTAssertFalse(element("ready_at").exists, "Creation must never ask when food is ready")
            XCTAssertTrue(element("deadline_at").waitForExistence(timeout: 5))
            if iteration == 0 { captureScreen("07-delivery-timing", showing: element("deadline_at")) }
            tap(app.buttons["delivery_timing"])
            waitUntilAbsent(element("ready_at"))
            waitUntilAbsent(element("deadline_at"))
            XCTAssertTrue(app.buttons["submit_delivery"].isEnabled)
        }
        captureScreen("02-new-delivery", showing: app.buttons["choose_pickup"])
        tap(app.buttons["submit_delivery"])
        waitForLabel(app.staticTexts["delivery_status"], "Da assegnare")
        XCTAssertFalse(app.buttons["submit_delivery"].exists, "The created delivery must replace its form")
        waitForReadinessValue("Da definire")
        XCTAssertFalse(app.buttons["assign_driver-1"].exists, "Creating an order must not ask for a driver")
        XCTAssertFalse(element("no_suggestions").exists)
        let created = try readDeliveriesFromServer()
        XCTAssertEqual(created.count, 1, "The happy path creates exactly one delivery")
        let delivery = try XCTUnwrap(created.first)
        XCTAssertEqual(delivery.shopName, shopName)
        XCTAssertEqual(delivery.status, "pending")
        XCTAssertEqual(delivery.readinessState, "unknown")
        XCTAssertEqual(delivery.readinessRevision, 0)
        assertFixtureAddresses(delivery)
        // Cancelling the estimate sheet leaves the server and unknown state untouched.
        tap(app.buttons["estimate_readiness"])
        XCTAssertTrue(element("readiness_minutes").waitForExistence(timeout: 5))
        tap(app.buttons["cancel_readiness"])
        waitForReadinessValue("Da definire")
        XCTAssertEqual(try readDeliveriesFromServer().first?.readinessRevision, 0)
        tap(app.buttons["estimate_readiness"])
        tap(app.buttons["save_readiness"])
        waitForReadinessValue(prefix: "Prevista alle ", suffix: "(stima)")
        waitForAutomaticAssignmentValue("Assegnazione prevista quando pronta")
        let estimated = try XCTUnwrap(readDeliveriesFromServer().first)
        XCTAssertEqual(estimated.status, "pending")
        XCTAssertEqual(estimated.readinessState, "estimated")
        XCTAssertGreaterThan(estimated.readyAt, Int(Date().timeIntervalSince1970), "The real API must retain the future estimate")
        XCTAssertNil(estimated.driverId)
        // Ready now triggers server assignment. No driver-selection button is needed.
        let readyNow = app.buttons["ready_now"]
        reveal(readyNow)
        readyNow.doubleTap()
        // Reading the lower automatic-state section may have scrolled these
        // fields outside the lazy List viewport. Bring each exact field back.
        reveal(app.staticTexts["delivery_status"])
        waitForLabel(app.staticTexts["delivery_status"], "Assegnata")
        reveal(element("delivery_readiness"))
        waitForReadinessValue(prefix: "Pronta dalle ", suffix: "(confermata)")
        let assignedAutomatically = try XCTUnwrap(readDeliveriesFromServer().first)
        XCTAssertEqual(assignedAutomatically.driverId, "driver-1")
        XCTAssertEqual(assignedAutomatically.readinessRevision, 2)
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
        captureScreen("05-driver-assignment", showing: app.staticTexts["delivery_status"])
        tap(app.buttons["done_delivery"])
        waitUntilAbsent(app.buttons["done_delivery"])
        let deliveryRow = app.buttons["delivery_\(delivery.id)"]
        waitForLabelContaining(deliveryRow, "Assegnata")
        captureScreen("01-dispatcher-jobs", showing: deliveryRow)
        // Existing jobs remain inspectable, without a redundant suggestion step.
        tap(deliveryRow)
        waitForLabel(app.staticTexts["delivery_status"], "Assegnata")
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
        backToDeliveries()
        switchRole()

        login("driver1")
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        assertRoutineDriverHome()
        XCTAssertTrue(app.buttons["resume_location"].waitForExistence(timeout: 10), "Role switching must stop location sharing")
        let resumedAt = Int(Date().timeIntervalSince1970)
        tap(app.buttons["resume_location"])
        waitUntilAbsent(app.buttons["resume_location"])
        try waitForServerLocation(since: resumedAt)
        XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists, "Show only the next stop's completion action")
        let overview = element("route_map")
        XCTAssertTrue(overview.exists)
        XCTAssertGreaterThanOrEqual(overview.frame.height, 170)
        XCTAssertTrue(app.frame.contains(overview.frame), "The map must be visible without expanding the remaining stops")
        XCTAssertTrue(app.buttons["confirm_pickup"].isHittable, "The next action must remain within the initial driver viewport")
        captureScreen("03-driver-route", showing: app.staticTexts["next_stop_title"])
        tap(app.buttons["switch_role"])
        tap(app.buttons["account_logout"])
        XCTAssertTrue(app.alerts["Uscire con un turno attivo?"].waitForExistence(timeout: 5))
        tapModalButton(logoutAlert.buttons["Annulla"])
        XCTAssertTrue(app.buttons["account_logout"].exists)
        tap(app.buttons["close_account"])
        XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 5))
        try assertServerStatus(delivery.id, "assigned")
        // The deterministic navigation adapter exercises the app contract without Google billing/GPS.
        // Navigation arrival and closing must not mutate the real backend's delivery status.
        for attempt in 0..<2 {
            tap(app.buttons["open_directions"])
            XCTAssertTrue(app.staticTexts["navigation_test_mode"].waitForExistence(timeout: 10))
            waitForLabelContaining(app.staticTexts["navigation_status"], "Segui le indicazioni")
            tap(app.buttons["navigation_voice"])
            waitForLabelContaining(app.buttons["navigation_voice"], "Voce spenta")
            if attempt == 0 {
                tap(app.buttons["simulate_navigation_arrival"])
                waitForLabelContaining(app.staticTexts["navigation_status"], "Sei arrivato")
                try assertServerStatus(delivery.id, "assigned")
                tap(app.buttons["return_to_stop"])
            } else {
                tap(app.buttons["close_navigation"])
            }
            waitUntilAbsent(app.staticTexts["navigation_test_mode"])
            XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 10))
            try assertServerStatus(delivery.id, "assigned")
        }
        for _ in 0..<2 {
            tap(app.buttons["route_details"])
            let firstStop = element("route_stop_1")
            reveal(firstStop)
            XCTAssertTrue(firstStop.exists)
            tap(app.buttons["route_details"])
            waitUntilAbsent(firstStop)
            // The overview is an accessibility container, not a tappable control.
            // Return to it by geometry rather than scrolling for isHittable.
            for _ in 0..<8 {
                if overview.exists && overview.frame.height >= 170 && app.frame.contains(overview.frame) { break }
                app.swipeDown()
            }
            XCTAssertTrue(overview.exists, "Collapsing remaining stops must retain the main map")
            XCTAssertGreaterThanOrEqual(overview.frame.height, 170)
            XCTAssertTrue(app.frame.contains(overview.frame), "The overview must be visible again after collapsing stops")
        }

        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        assertSwitch(app.switches["background_location"], value: "0")
        captureScreen("04-driver-shift", showing: app.staticTexts["location_sent"])
        // Sharing can be paused without ending the shift, then resumed on the home screen.
        setSwitch(app.switches["share_location"], to: false)
        assertSwitch(app.switches["background_location"], value: "0")
        tap(app.buttons["close_shift_settings"])
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        tap(app.buttons["resume_location"])
        waitUntilAbsent(app.buttons["resume_location"])
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        tap(app.buttons["close_shift_settings"])
        assertRoutineDriverHome()

        // Returning from another app must preserve the current stop and foreground opt-in.
        let returnedAt = Int(Date().timeIntervalSince1970)
        interruptAndResume()
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
        XCTAssertFalse(app.buttons["resume_location"].exists)
        try waitForServerLocation(since: returnedAt)
        try assertServerStatus(delivery.id, "assigned")

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
        for _ in 0..<2 {
            tap(app.buttons["delivery_history"])
            reveal(completed)
            XCTAssertTrue(completed.exists)
            XCTAssertTrue(completed.label.contains("Consegnata"))
            tap(app.buttons["delivery_history"])
            waitUntilAbsent(completed)
        }

        tap(app.buttons["shift_settings"])
        tap(app.buttons["toggle_shift"])
        waitUntilAbsent(app.buttons["close_shift_settings"])
        waitForLabelContaining(app.buttons["shift_settings"], "Fuori turno")
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
        waitForLabel(app.staticTexts["delivery_status"], "Consegnata")
        XCTAssertFalse(app.buttons["suggest_drivers"].exists)
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
        XCTAssertFalse(app.buttons["change_driver"].exists)
        backToDeliveries()
        try verifyPendingDeliveryCanBeReopened()
    }

    @MainActor
    func testDualCapabilityAccountKeepsItsShiftAndRouteAcrossViewSwitches() throws {
        // This fixture has its own team so the existing single-role lifecycle can run
        // before or after this test without changing either test's delivery counts.
        let legacyDeliveries = try readDeliveriesFromServer()
        let legacyDrivers: [ServerDriver] = try readServer("v1/drivers", token: "demo-dispatcher")
        let identity: ServerPrincipal = try readServer("v1/me", token: dualToken)
        XCTAssertEqual(identity.id, dualDriverID)
        XCTAssertEqual(Set(identity.roles), Set(["dispatcher", "driver"]))
        XCTAssertEqual(identity.teamId, "demo-review")
        XCTAssertEqual(identity.teamName, "Squadra revisione")
        XCTAssertTrue(try readDeliveriesFromServer(token: dualToken).isEmpty, "Run against a fresh demo database")
        let initialDriver = try readDriverFromServer(token: dualToken)
        XCTAssertEqual(initialDriver.id, identity.id)
        XCTAssertFalse(initialDriver.active)
        XCTAssertNil(initialDriver.location)
        XCTAssertNil(initialDriver.locationUpdatedAt)

        // Authenticate once. Every change below uses the same account's view picker,
        // never the Debug account chooser or another account's credentials.
        login("dual")
        assertDualAccountView("Centrale")
        XCTAssertFalse(element("account_location_sharing").exists)
        XCTAssertFalse(app.buttons["stop_account_location"].exists)
        captureScreen("dual-account-centrale", showing: app.buttons["role_dispatcher"])
        selectAccountView("Corriere")
        waitForLabelContaining(app.buttons["shift_settings"], "Fuori turno")
        assertRoutineDriverHome()
        assertSharingSettings(foreground: "0", background: "0", enabled: false)
        interruptAndResume()
        assertDualAccountView("Corriere")
        for _ in 0..<2 {
            selectAccountView("Centrale")
            selectAccountView("Corriere")
            waitForLabelContaining(app.buttons["shift_settings"], "Fuori turno")
            XCTAssertEqual(try readDriverFromServer(token: dualToken), initialDriver,
                           "Choosing Corriere must not start a shift or share a location")
        }

        let startedAt = Int(Date().timeIntervalSince1970)
        tap(app.buttons["toggle_shift"])
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        try waitForServerLocation(since: startedAt, token: dualToken)
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: "1")
        assertSwitch(app.switches["background_location"], value: "1")
        // Opting back to foreground-only must remain stable until the driver changes it.
        setSwitch(app.switches["background_location"], to: false)
        assertSwitch(app.switches["background_location"], value: "0")
        setSwitch(app.switches["background_location"], to: true)
        tap(app.buttons["close_shift_settings"])
        interruptAndResume()
        assertSharingSettings(foreground: "1", background: "1")
        selectAccountView("Centrale")
        assertAccountSharingVisible()
        interruptAndResume()
        assertDualAccountView("Centrale")
        assertAccountSharingVisible()
        let retainedDriver = try readDriverFromServer(token: dualToken)
        XCTAssertEqual(retainedDriver.id, identity.id)
        XCTAssertTrue(retainedDriver.active, "Switching views must retain the same driver's active shift")
        selectAccountView("Corriere")
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        assertSharingSettings(foreground: "1", background: "1")
        XCTAssertFalse(app.buttons["resume_location"].exists,
                       "Same-account view changes preserve explicitly enabled location sharing")
        selectAccountView("Centrale")
        tap(app.buttons["stop_account_location"])
        waitUntilAbsent(app.buttons["stop_account_location"])
        waitUntilAbsent(element("account_location_sharing"))
        selectAccountView("Corriere")
        assertPausedDualDriver()
        // Refresh the explicit opt-in before assignment: a slow simulator must not
        // depend on the initial sample remaining within the server's freshness window.
        let assignmentLocationAt = Int(Date().timeIntervalSince1970)
        tap(app.buttons["resume_location"])
        waitUntilAbsent(app.buttons["resume_location"])
        try waitForServerLocation(since: assignmentLocationAt, token: dualToken)
        assertSharingSettings(foreground: "1", background: "0")
        selectAccountView("Centrale")
        assertAccountSharingVisible()

        // A dual-capability account may assign itself, but cannot see demo-team's
        // drivers or deliveries. Address selection and all writes use the real API.
        let teamDrivers: [ServerDriver] = try readServer("v1/drivers", token: dualToken)
        XCTAssertEqual(teamDrivers.map(\.id), [dualDriverID])
        tap(app.buttons["create_delivery"])
        assertEmptyDeliveryForm()
        selectAddress("choose_pickup", query: "Pizzeria", expected: shopName)
        selectAddress("choose_dropoff", query: "Garibaldi", expected: "Via Garibaldi 8")
        tap(app.buttons["submit_delivery"])
        waitForLabel(app.staticTexts["delivery_status"], "Da assegnare")
        waitForReadinessValue("Da definire")
        XCTAssertFalse(app.buttons["assign_\(dualDriverID)"].exists)
        let created = try readDeliveriesFromServer(token: dualToken)
        XCTAssertEqual(created.count, 1)
        let delivery = try XCTUnwrap(created.first)
        XCTAssertEqual(delivery.shopName, shopName)
        XCTAssertEqual(delivery.status, "pending")
        XCTAssertEqual(delivery.readinessState, "unknown")
        assertFixtureAddresses(delivery)
        tap(app.buttons["ready_now"])
        waitForLabel(app.staticTexts["delivery_status"], "Assegnata")
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
        XCTAssertFalse(app.buttons["assign_driver-2"].exists)
        tap(app.buttons["done_delivery"])
        waitUntilAbsent(app.buttons["done_delivery"])
        let deliveryRow = app.buttons["delivery_\(delivery.id)"]
        waitForLabelContaining(deliveryRow, "Assegnata")
        try assertServerStatus(delivery.id, "assigned", token: dualToken)
        let assigned = try XCTUnwrap(readDeliveriesFromServer(token: dualToken).first)
        XCTAssertEqual(assigned.driverId, identity.id, "Assignment must belong to the authenticated driver's own identity")
        try assertDualRoute(delivery.id, kinds: ["pickup", "dropoff"])
        tap(app.buttons["stop_account_location"])
        waitUntilAbsent(app.buttons["stop_account_location"])
        waitUntilAbsent(element("account_location_sharing"))
        let pausedDriver = try readDriverFromServer(token: dualToken)

        // The picker stays accessible from a pushed job. Changing views must reset
        // that navigation stack instead of resurfacing a stale detail on return.
        tap(deliveryRow)
        waitForLabel(app.staticTexts["delivery_status"], "Assegnata")
        selectAccountView("Corriere")
        waitUntilAbsent(app.staticTexts["delivery_status"])
        assertPausedDualDriver()
        XCTAssertTrue(app.buttons["confirm_pickup"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
        waitForLabelContaining(app.staticTexts["next_stop_title"], shopName)
        let pickupTitle = app.staticTexts["next_stop_title"].label
        captureScreen("dual-account-corriere", showing: app.staticTexts["next_stop_title"])
        for _ in 0..<2 {
            selectAccountView("Centrale")
            waitForLabelContaining(deliveryRow, "Assegnata")
            interruptAndResume()
            assertDualAccountView("Centrale")
            selectAccountView("Corriere")
            interruptAndResume()
            assertPausedDualDriver()
            waitForLabel(app.staticTexts["next_stop_title"], pickupTitle)
            XCTAssertTrue(app.buttons["confirm_pickup"].exists)
            XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
            try assertDualRoute(delivery.id, kinds: ["pickup", "dropoff"])
            XCTAssertEqual(try readDriverFromServer(token: dualToken), pausedDriver,
                           "Repeated switching and foregrounding must not silently restore either location opt-in")
        }

        // Completing work remains possible with sharing paused. A view switch must
        // not rewind the committed next stop or restore the old pickup action.
        tap(app.buttons["confirm_pickup"])
        XCTAssertTrue(app.buttons["confirm_dropoff"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)
        try assertServerStatus(delivery.id, "picked_up", token: dualToken)
        try assertDualRoute(delivery.id, kinds: ["dropoff"])
        selectAccountView("Centrale")
        waitForLabelContaining(deliveryRow, "In consegna")
        selectAccountView("Corriere")
        assertPausedDualDriver()
        XCTAssertTrue(app.buttons["confirm_dropoff"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)

        // Resuming is explicit and restores foreground sharing only, even though
        // background sharing had been enabled earlier in this same login.
        let resumedAt = Int(Date().timeIntervalSince1970)
        tap(app.buttons["resume_location"])
        waitUntilAbsent(app.buttons["resume_location"])
        try waitForServerLocation(since: resumedAt, token: dualToken)
        assertSharingSettings(foreground: "1", background: "0")
        let returnedAt = Int(Date().timeIntervalSince1970)
        interruptAndResume()
        XCTAssertTrue(app.buttons["confirm_dropoff"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)
        XCTAssertFalse(app.buttons["resume_location"].exists)
        try waitForServerLocation(since: returnedAt, token: dualToken)
        try assertDualRoute(delivery.id, kinds: ["dropoff"])
        selectAccountView("Centrale")
        assertAccountSharingVisible()
        let centraleReturnedAt = Int(Date().timeIntervalSince1970)
        interruptAndResume()
        assertAccountSharingVisible()
        try waitForServerLocation(since: centraleReturnedAt, token: dualToken)
        selectAccountView("Corriere")
        assertSharingSettings(foreground: "1", background: "0")
        XCTAssertFalse(app.buttons["resume_location"].exists)
        XCTAssertTrue(app.buttons["confirm_dropoff"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)

        tap(app.buttons["confirm_dropoff"])
        XCTAssertTrue(app.staticTexts["empty_route"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirm_pickup"].exists)
        XCTAssertFalse(app.buttons["confirm_dropoff"].exists)
        try assertServerStatus(delivery.id, "delivered", token: dualToken)
        try assertDualRoute(delivery.id, kinds: [])
        tap(app.buttons["shift_settings"])
        tap(app.buttons["toggle_shift"])
        waitUntilAbsent(app.buttons["close_shift_settings"])
        waitForLabelContaining(app.buttons["shift_settings"], "Fuori turno")
        assertSharingSettings(foreground: "0", background: "0", enabled: false)
        XCTAssertFalse(try readDriverFromServer(token: dualToken).active)
        let finalIdentity: ServerPrincipal = try readServer("v1/me", token: dualToken)
        XCTAssertEqual(finalIdentity, identity)
        XCTAssertEqual(try readDeliveriesFromServer(), legacyDeliveries,
                       "The review-team lifecycle must not add or change demo-team deliveries")
        let finalLegacyDrivers: [ServerDriver] = try readServer("v1/drivers", token: "demo-dispatcher")
        XCTAssertEqual(finalLegacyDrivers, legacyDrivers,
                       "Switching views must never start, stop or locate a legacy demo driver")

        switchRole()
        XCTAssertTrue(app.buttons["login_dual"].exists, "Logout still returns to the Debug account chooser")
        XCTAssertFalse(element("role_picker").exists)
    }

    func testSingleCapabilityAccountsHaveNoInSessionRolePicker() {
        for account in ["dispatcher", "driver1", "driver2"] {
            login(account)
            XCTAssertFalse(element("role_picker").exists, "Only multi-capability accounts may switch views")
            if account == "dispatcher" {
                XCTAssertFalse(app.buttons["shift_settings"].exists)
            } else {
                XCTAssertFalse(app.buttons["create_delivery"].exists)
            }
            for attempt in 0..<2 {
                tap(app.buttons["switch_role"])
                XCTAssertTrue(app.buttons["account_logout"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["account_settings"].exists, "Demo accounts are not eligible for deletion")
                if account == "dispatcher" && attempt == 0 {
                    captureScreen("ux-account", showing: app.buttons["account_logout"])
                    interruptAndResume()
                    XCTAssertTrue(app.buttons["account_logout"].exists)
                }
                tap(app.buttons["close_account"])
                waitUntilAbsent(app.buttons["account_logout"])
                XCTAssertFalse(app.buttons["login_dispatcher"].exists, "Opening or dismissing Account must never sign out")
            }
            switchRole()
        }
    }

    func testAddressSearchCancellationAndStaleResults() {
        login("dispatcher")
        tap(app.buttons["create_delivery"])
        assertEmptyDeliveryForm()
        tap(app.buttons["choose_pickup"])
        tap(app.buttons["add_restaurant"])
        tap(app.buttons["restaurant_address"])
        let search = app.textFields["address_search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        replace(search, with: "Pizzeria")
        waitForLabelContaining(app.buttons["address_result_0"], shopName)
        // Submit the search to dismiss the system keyboard, including its first-use tutorial.
        // System keyboard language belongs to the simulator, not the app localization.
        search.typeText("\n")
        waitUntilAbsent(app.keyboards.firstMatch)
        waitUntilAbsent(app.buttons["Continue"])
        waitUntilAbsent(app.buttons["Continua"])
        waitForLabelContaining(app.buttons["address_result_0"], shopName)
        captureScreen("06-address-search", showing: app.buttons["address_result_0"])
        // A short/empty query must remove previously valid results, even after debounce.
        replace(search, with: "xx")
        waitUntilAbsent(app.buttons["address_result_0"])
        replace(search, with: "Garibaldi")
        waitForLabelContaining(app.buttons["address_result_0"], "Via Garibaldi 8")
        XCTAssertFalse(app.buttons["address_result_0"].label.contains(shopName))
        replace(search, with: "")
        waitUntilAbsent(app.buttons["address_result_0"])
        tap(app.buttons["cancel_address"])
        tap(app.buttons["cancel_restaurant"])
        tap(app.buttons["cancel_restaurant_picker"])
        assertEmptyDeliveryForm()

        selectAddress("choose_pickup", query: "Pizzeria", expected: shopName)
        let selectedPickup = app.buttons["choose_pickup"].label
        tap(app.buttons["choose_pickup"])
        tap(app.buttons["add_restaurant"])
        tap(app.buttons["restaurant_address"])
        replace(app.textFields["address_search"], with: "Garibaldi")
        waitForLabelContaining(app.buttons["address_result_0"], "Via Garibaldi 8")
        tap(app.buttons["cancel_address"])
        tap(app.buttons["cancel_restaurant"])
        tap(app.buttons["cancel_restaurant_picker"])
        XCTAssertEqual(app.buttons["choose_pickup"].label, selectedPickup, "Cancel must preserve the selected address")
        XCTAssertFalse(app.buttons["submit_delivery"].isEnabled)

        tap(app.buttons["choose_dropoff"])
        replace(app.textFields["address_search"], with: "Indirizzo inesistente")
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
        interruptAndResume()
        XCTAssertTrue(app.buttons["cancel_delivery"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["choose_pickup"].label, selectedPickup)
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
            tap(app.buttons["cancel_restaurant_picker"])
            tap(app.buttons["cancel_delivery"])
            waitUntilAbsent(app.buttons["cancel_delivery"])
            XCTAssertTrue(app.buttons["create_delivery"].isHittable)
        }
        switchRole()
        tap(app.buttons["demo_settings"])
        replace(app.textFields["api_url"], with: "http://example.com")
        tap(app.buttons["login_dispatcher"])
        XCTAssertTrue(app.alerts["Operazione non riuscita"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "loopback")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["login_dispatcher"].exists)
    }

    func testPilotLoginHasNoRoleChooserAndRejectsHTTP() {
        app.terminate()
        app.launchArguments = ["--pilot-uitesting", "-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
        app.launchEnvironment["ARRIVAU_API_URL"] = "http://api.example.com"
        app.launch()
        XCTAssertTrue(app.textFields["login_username"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Fresh isolated pilot login must not be blocked by a restoration error")
        XCTAssertFalse(app.buttons["login_dispatcher"].exists)
        XCTAssertFalse(app.buttons["login_driver1"].exists)
        XCTAssertFalse(app.buttons["login_dual"].exists)
        XCTAssertFalse(element("role_picker").exists)
        XCTAssertFalse(app.textFields["api_url"].exists, "Release-style login uses the configured endpoint")
        XCTAssertFalse(app.textFields["invite_input"].exists, "Invite entry belongs in its own screen")
        XCTAssertTrue(app.buttons["show_invite_entry"].isHittable)
        captureScreen("ux-pilot-login", showing: app.buttons["show_invite_entry"])
        replace(app.textFields["login_username"], with: "pilot-test")
        let password = app.secureTextFields["login_password"]
        tap(password)
        password.typeText("test-only-password")
        tap(app.buttons["login_submit"])
        XCTAssertTrue(app.alerts["Operazione non riuscita"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HTTPS")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["create_delivery"].exists)
        XCTAssertFalse(app.buttons["shift_settings"].exists)
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
        waitForLabel(app.staticTexts["delivery_status"], "Da assegnare")
        waitForReadinessValue("Da definire")
        XCTAssertFalse(element("no_suggestions").exists)
        XCTAssertFalse(app.buttons["assign_driver-1"].exists)
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
            waitForLabel(app.staticTexts["delivery_status"], "Da assegnare")
            waitForReadinessValue("Da definire")
            XCTAssertFalse(element("no_suggestions").exists)
            XCTAssertFalse(app.buttons["assign_driver-1"].exists)
            XCTAssertFalse(app.buttons["submit_delivery"].exists)
            XCTAssertFalse(app.buttons["suggest_drivers"].exists)
            backToDeliveries()
        }
        let reopened = try readDeliveriesFromServer()
        XCTAssertEqual(Set(reopened.map(\.id)), Set(after.map(\.id)), "Reopening a created job must retain its ID")
        tap(app.buttons["delivery_\(pending.id)"])
        tap(app.buttons["ready_now"])
        waitForAutomaticAssignmentValue("In attesa di un corriere")
        let waitingReason = element("dispatch_waiting_reason")
        reveal(waitingReason)
        XCTAssertTrue(waitingReason.waitForExistence(timeout: 10))
        let waiting = try XCTUnwrap(readDeliveriesFromServer().first { $0.id == pending.id })
        XCTAssertEqual(waiting.status, "pending")
        XCTAssertEqual(waiting.readinessState, "ready")
        XCTAssertEqual(waiting.dispatchWaitingReason, "no_active_driver")
        backToDeliveries()
    }

    private func assertEmptyDeliveryForm() {
        XCTAssertTrue(app.buttons["choose_pickup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose_pickup"].label.contains("Scegli un indirizzo"))
        XCTAssertTrue(app.buttons["choose_dropoff"].label.contains("Scegli un indirizzo"))
        XCTAssertFalse(app.buttons["submit_delivery"].isEnabled)
        XCTAssertEqual(app.textFields.count, 0, "Routine creation should use address selections, not raw text or coordinates")
        XCTAssertEqual(app.steppers.count, 0, "Capacity and load tuning should not be routine form controls")
        XCTAssertEqual(app.buttons["submit_delivery"].label, "Crea consegna")
        XCTAssertFalse(element("ready_at").exists, "Creation must never ask when food is ready")
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
        if button == "choose_pickup" {
            selectRestaurant(query: query, expected: expected)
            return
        }
        tap(app.buttons[button])
        replace(app.textFields["address_search"], with: query)
        let result = app.buttons["address_result_0"]
        waitForLabelContaining(result, expected)
        tap(result)
        waitUntilAbsent(app.textFields["address_search"])
        XCTAssertTrue(app.buttons[button].label.contains(expected))
    }

    private func selectRestaurant(query: String, expected: String) {
        tap(app.buttons["choose_pickup"])
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "restaurant_", expected)).firstMatch
        if saved.waitForExistence(timeout: 3) {
            tap(saved)
        } else {
            tap(app.buttons["add_restaurant"])
            tap(app.buttons["restaurant_address"])
            replace(app.textFields["address_search"], with: query)
            waitForLabelContaining(app.buttons["address_result_0"], expected)
            tap(app.buttons["address_result_0"])
            waitUntilAbsent(app.textFields["address_search"])
            XCTAssertEqual(app.textFields["restaurant_name"].value as? String, expected)
            let save = app.buttons["save_restaurant"]
            reveal(save)
            save.doubleTap()
        }
        waitUntilAbsent(app.buttons["cancel_restaurant_picker"])
        XCTAssertTrue(app.buttons["choose_pickup"].label.contains(expected))
        // Reopening chooses the stored record rather than asking for the address again.
        tap(app.buttons["choose_pickup"])
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "restaurant_", expected)).count, 1)
        tap(saved)
        waitUntilAbsent(app.buttons["cancel_restaurant_picker"])
    }

    private struct ServerCoordinate: Decodable, Equatable { let lat: Double; let lng: Double }
    private struct ServerPrincipal: Decodable, Equatable {
        let id: String
        let roles: [String]
        let teamId: String
        let teamName: String
    }
    private struct ServerDriver: Decodable, Equatable {
        let id: String
        let active: Bool
        let location: ServerCoordinate?
        let locationUpdatedAt: Int?
    }
    private struct ServerDelivery: Decodable, Equatable {
        let id: String
        let shopName: String
        let status: String
        let driverId: String?
        let readinessState: String
        let readyAt: Int
        let readinessRevision: Int
        let dispatchWaitingReason: String?
        let pickupAddress: String
        let pickup: ServerCoordinate
        let dropoffAddress: String
        let dropoff: ServerCoordinate
    }
    private struct ServerRoute: Decodable {
        struct Stop: Decodable {
            let deliveryId: String
            let kind: String
        }
        let driverId: String
        let stops: [Stop]
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
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

    private func readDriverFromServer(token: String = "demo-driver-1") throws -> ServerDriver {
        try readServer("v1/shift", token: token)
    }

    private func readDeliveriesFromServer(token: String = "demo-dispatcher") throws -> [ServerDelivery] {
        try readServer("v1/deliveries", token: token)
    }

    private func assertServerStatus(_ id: String, _ status: String, token: String = "demo-dispatcher") throws {
        let deliveries = try readDeliveriesFromServer(token: token)
        XCTAssertEqual(deliveries.first { $0.id == id }?.status, status)
    }

    private func assertDualRoute(_ deliveryID: String, kinds: [String]) throws {
        let route: ServerRoute = try readServer("v1/route", token: dualToken)
        XCTAssertEqual(route.driverId, dualDriverID)
        XCTAssertEqual(route.stops.map(\.deliveryId), Array(repeating: deliveryID, count: kinds.count))
        XCTAssertEqual(route.stops.map(\.kind), kinds, "View changes must retain the committed order of remaining stops")
    }

    private func assertFixtureAddresses(_ delivery: ServerDelivery) {
        XCTAssertEqual(delivery.pickupAddress, "Via Roma 1, Pachino")
        XCTAssertEqual(delivery.pickup.lat, 36.7163, accuracy: 0.000001)
        XCTAssertEqual(delivery.pickup.lng, 15.0908, accuracy: 0.000001)
        XCTAssertEqual(delivery.dropoffAddress, "Via Garibaldi 8, Pachino")
        XCTAssertEqual(delivery.dropoff.lat, 36.721, accuracy: 0.000001)
        XCTAssertEqual(delivery.dropoff.lng, 15.1, accuracy: 0.000001)
    }

    private func waitForServerLocation(since timestamp: Int, token: String = "demo-driver-1") throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let driver = try readDriverFromServer(token: token)
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
        let destination = role == "dispatcher" || role == "dual" ? app.buttons["create_delivery"] : app.buttons["shift_settings"]
        let reachedDestination = destination.waitForExistence(timeout: 20)
        var diagnostic = "Check the running Rust API and fresh database"
        if !reachedDestination {
            let loginButton = app.buttons["login_\(role)"]
            let loginExists = loginButton.exists
            let enabled = loginExists && loginButton.isEnabled
            let hittable = loginExists && loginButton.isHittable
            let errorAlert = app.alerts["Operazione non riuscita"].exists
            diagnostic += "; app state=\(app.state.rawValue), login exists=\(loginExists), enabled=\(enabled), hittable=\(hittable)"
            diagnostic += ", loading=\(app.progressIndicators.firstMatch.exists), error alert=\(errorAlert)"
            print("ARRIVAU_UI_LOGIN_STATE \(diagnostic)")
            // This class launches only the isolated demo with public fixture identities.
            // Export this exact PNG, never a raw result bundle or accessibility hierarchy.
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "demo-login-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let healthStatus = diagnoseLoopbackAPI("health")
            let identityStatus = diagnoseLoopbackAPI("v1/me")
            diagnostic += "; health=\(healthStatus), demo identity=\(identityStatus)"
            print("ARRIVAU_UI_LOGIN_PROBES health=\(healthStatus), demo identity=\(identityStatus)")
        }
        XCTAssertTrue(reachedDestination, diagnostic)
        XCTAssertTrue(app.buttons["switch_role"].exists, "The profile control must open Account")
        XCTAssertFalse(app.buttons["account_settings"].exists, "Public demo accounts must never offer self-deletion")
    }

    /// Only status/error codes from the disposable loopback API; never bodies or headers.
    private func diagnoseLoopbackAPI(_ path: String) -> String {
        guard ["127.0.0.1", "localhost", "::1", "[::1]"].contains(apiURL.host ?? "") else { return "not-loopback" }
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        if path == "v1/me" { request.setValue("Bearer demo-dispatcher", forHTTPHeaderField: "Authorization") }
        let completed = XCTestExpectation(description: "Collect bounded loopback status")
        let responseBox = ServerResponse()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ProbeNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { _, response, error in
            if let error { responseBox.store(.failure(error)) }
            else if let response { responseBox.store(.success((Data(), response))) }
            completed.fulfill()
        }
        task.resume()
        guard XCTWaiter.wait(for: [completed], timeout: 4) == .completed else {
            task.cancel()
            return "probe-timeout"
        }
        switch responseBox.load() {
        case .some(.success(let (_, response))):
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        case .some(.failure(let error as URLError)): return "URL error \(error.code.rawValue)"
        case .some(.failure(_)): return "transport-error"
        case nil: return "no-response"
        }
    }

    private final class ProbeNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func roleButton(_ title: String) -> XCUIElement {
        app.buttons[title == "Centrale" ? "role_dispatcher" : "role_driver"]
    }

    private func assertDualAccountView(_ title: String) {
        XCTAssertTrue(element("role_picker").waitForExistence(timeout: 10))
        XCTAssertEqual(roleButton(title).value as? String, "Selezionato")
        XCTAssertEqual(roleButton(title == "Centrale" ? "Corriere" : "Centrale").value as? String, "Non selezionato")
        XCTAssertFalse(app.staticTexts["team_identity"].exists, "Team details belong in Account, not repeated above every screen")
        XCTAssertFalse(app.buttons["login_dual"].exists, "Changing views must not log out or ask for another account")
        XCTAssertFalse(app.buttons["login_dispatcher"].exists)
        XCTAssertFalse(app.buttons["login_driver1"].exists)
    }

    private func selectAccountView(_ title: String) {
        let control = element("role_picker")
        let target = roleButton(title)
        // Each explicit role button exposes its own enabled state and full hit area.
        waitUntilEnabled(target)
        print("Role switch to \(title): app state=\(app.state.rawValue), target enabled=\(target.isEnabled), value=\(String(describing: target.value)), frame=\(target.frame)")
        tap(target)
        let destination = title == "Centrale" ? app.buttons["create_delivery"] : app.buttons["shift_settings"]
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.exists && (target.value as? String) == "Selezionato" && destination.exists
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [arrived], timeout: 15)
        if outcome != .completed {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "ux-role-switch-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(outcome, .completed,
                       "Role switch to \(title) failed; target selected=\(target.exists && (target.value as? String) == "Selezionato"), destination=\(destination.exists), driver screen=\(element("driver_screen").exists), control exists=\(control.exists), app state=\(app.state.rawValue)")
        assertDualAccountView(title)
    }

    private func assertSharingSettings(foreground: String, background: String, enabled: Bool = true) {
        tap(app.buttons["shift_settings"])
        assertSwitch(app.switches["share_location"], value: foreground)
        assertSwitch(app.switches["background_location"], value: background)
        XCTAssertEqual(app.switches["share_location"].isEnabled, enabled)
        XCTAssertEqual(app.switches["background_location"].isEnabled, enabled && foreground == "1")
        tap(app.buttons["close_shift_settings"])
    }

    private func assertPausedDualDriver() {
        assertDualAccountView("Corriere")
        waitForLabelContaining(app.buttons["shift_settings"], "In turno")
        XCTAssertTrue(app.buttons["resume_location"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("account_location_sharing").exists)
        XCTAssertFalse(app.buttons["stop_account_location"].exists)
        assertSharingSettings(foreground: "0", background: "0")
        XCTAssertFalse(app.buttons["toggle_shift"].exists, "Changing views must retain the existing active shift")
    }

    private func assertAccountSharingVisible() {
        XCTAssertTrue(element("account_location_sharing").waitForExistence(timeout: 10),
                      "Explicitly enabled tracking must remain visible in either account view")
        XCTAssertTrue(app.buttons["stop_account_location"].exists)
        XCTAssertTrue(app.buttons["stop_account_location"].isEnabled)
    }

    private func interruptAndResume() {
        // CI has left Arrivau foreground after a Home-button event in this flow.
        // Explicitly activating another installed app is synchronous and models
        // the same real interruption without terminating Arrivau or changing settings.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        // State updates are asynchronous; require a real background transition
        // before resuming. Never treat the foreground state as a passing fallback.
        // Supplying a background XCUIElement as the expectation object makes
        // XCTest capture its accessibility hierarchy for diagnostics. Poll the
        // process state directly instead, without that unrelated snapshot work.
        let application = app!
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let state = application.state
            return state == .runningBackground || state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed,
                       "App switch did not reach a background state; Arrivau=\(app.state.rawValue), Settings=\(settings.state.rawValue)")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func switchRole() {
        tap(app.buttons["switch_role"])
        XCTAssertTrue(app.buttons["account_logout"].waitForExistence(timeout: 5))
        tap(app.buttons["account_logout"])
        if logoutAlert.buttons["Esci"].waitForExistence(timeout: 2) {
            tapModalButton(logoutAlert.buttons["Esci"], captureLogout: true)
        }
        XCTAssertTrue(app.buttons["login_dispatcher"].waitForExistence(timeout: 5))
    }

    private func backToDeliveries() {
        // Extra navigation-bar actions must not change which control goes back.
        tap(app.navigationBars.buttons["BackButton"])
        waitUntilAbsent(app.staticTexts["delivery_status"])
        XCTAssertTrue(app.buttons["create_delivery"].waitForExistence(timeout: 5))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var logoutAlert: XCUIElement {
        app.alerts.matching(NSPredicate(
            format: "label == %@ OR label == %@", "Uscire con un turno attivo?", "Uscire dall’account?"
        )).firstMatch
    }

    /// Native alerts have their own hit-testing surface above Account. Use XCTest’s
    /// direct alert tap, as in the HTTP-error tests; scrolling or pre-gating it with
    /// a nested-sheet hittability snapshot can prevent the actual action altogether.
    private func tapModalButton(_ button: XCUIElement, captureLogout: Bool = false) {
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        print("Logout alert button: enabled=\(button.isEnabled), hittable=\(button.isHittable), frame=\(button.frame)")
        if captureLogout {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "ux-active-logout"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        button.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.alerts.firstMatch.exists
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [dismissed], timeout: 10)
        if outcome != .completed {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "ux-logout-presentation"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(outcome, .completed, "One alert-button tap must dismiss the logout confirmation")
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        if !element.exists { _ = element.waitForExistence(timeout: min(timeout, 3)) }
        reveal(element)
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: timeout))
        waitUntilEnabled(element, timeout: timeout)
        XCTAssertTrue(element.isHittable)
        // SwiftUI List can report a disclosure button's bounds as the entire expanded
        // cell. Its center may be inside the interactive map. Tap the visible heading
        // instead, just as a user does, while retaining all expand/collapse assertions.
        let value = element.value as? String
        let heading = element.staticTexts.firstMatch
        if (value == "Espanso" || value == "Compresso") && heading.exists && heading.isHittable {
            heading.tap()
        } else {
            element.tap()
        }
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) {
        if element.exists && element.isHittable && element.isEnabled { return }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
    }

    private func waitUntilAbsent(_ element: XCUIElement) {
        if !element.exists { return }
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        let outcome = XCTWaiter.wait(for: [absent], timeout: 10)
        var details = "Element did not disappear"
        if outcome != .completed, element.identifier == "address_search" {
            let error = app.staticTexts["address_error"]
            let result = app.buttons["address_result_0"]
            details = "Address picker stayed open: busy=\(self.element("address_searching").exists), error=\(error.exists ? error.label : "none"), result exists=\(result.exists), result enabled=\(result.exists ? result.isEnabled : false)"
        }
        XCTAssertEqual(outcome, .completed, details)
    }

    private func assertSwitch(_ element: XCUIElement, value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertEqual(element.value as? String, value)
    }

    private func setSwitch(_ element: XCUIElement, to enabled: Bool) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        reveal(element)
        waitUntilEnabled(element)
        let target = enabled ? "1" : "0"
        if element.value as? String != target {
            // SwiftUI exposes both a label+control row and the native child switch.
            let nativeSwitch = element.switches.firstMatch
            if nativeSwitch.exists {
                waitUntilEnabled(nativeSwitch)
                nativeSwitch.tap()
            } else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", target), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed,
                       "Switch did not reach \(target): parent enabled=\(element.isEnabled), value=\(String(describing: element.value)), native exists=\(element.switches.firstMatch.exists), native enabled=\(element.switches.firstMatch.exists ? element.switches.firstMatch.isEnabled : false), native value=\(String(describing: element.switches.firstMatch.exists ? element.switches.firstMatch.value : nil)), sharing=\(String(describing: app.switches["share_location"].exists ? app.switches["share_location"].value : nil))")
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

    /// The automatic-assignment section can be outside List's realized viewport
    /// after saving an estimate. Reveal its semantic row before matching exact state.
    private func waitForAutomaticAssignmentValue(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let assignment = element("automatic_assignment_status")
        reveal(assignment)
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@ AND value == %@", "Assegnazione", value),
            object: assignment)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed,
                       assignmentDiagnostic(assignment), file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "automatic_assignment_status").count, 1,
                       "Automatic assignment must expose one semantic field", file: file, line: line)
    }

    private func assignmentDiagnostic(_ assignment: XCUIElement) -> String {
        guard assignment.exists else { return "Assignment field is unavailable" }
        return "Assignment label: \(assignment.label); value: \(String(describing: assignment.value))"
    }

    /// LabeledContent exposes readiness as one label/value pair, regardless of
    /// the OS-specific accessibility element type. Keep unknown-state matching exact.
    private func waitForReadinessValue(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let readiness = element("delivery_readiness")
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@ AND value == %@", "Disponibilità", value),
            object: readiness)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed,
                       readinessDiagnostic(readiness), file: file, line: line)
    }

    private func waitForReadinessValue(prefix: String, suffix: String, file: StaticString = #filePath, line: UInt = #line) {
        let readiness = element("delivery_readiness")
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@ AND value BEGINSWITH %@ AND value ENDSWITH %@",
                                   "Disponibilità", prefix, suffix),
            object: readiness)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed,
                       readinessDiagnostic(readiness), file: file, line: line)
    }

    private func readinessDiagnostic(_ readiness: XCUIElement) -> String {
        guard readiness.exists else { return "Readiness field is unavailable" }
        return "Readiness label: \(readiness.label); value: \(String(describing: readiness.value))"
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
