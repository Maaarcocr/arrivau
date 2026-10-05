import XCTest

/// Native pilot form checks. The invalid HTTP origin guarantees no credentials leave the app.
/// Real signup/restore races are covered separately with URLProtocol in InviteTests.
final class InviteFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private let token = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--pilot-uitesting", "-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
        app.launchEnvironment["ARRIVAU_API_URL"] = "http://api.example.com"
        app.launch()
        XCTAssertTrue(app.textFields["login_username"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws { app.terminate() }

    func testPastedInviteRejectsServerOverrideWithoutOpeningSignup() {
        tap(app.buttons["show_invite_entry"])
        enter(app.textFields["invite_input"], "arrivau://invite?token=\(token)&server=https://attacker.example")
        tap(app.buttons["open_invite"])
        XCTAssertTrue(app.alerts["Operazione non riuscita"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.textFields["invite_username"].exists)
        XCTAssertTrue(app.textFields["invite_input"].exists)
        XCTAssertFalse(app.textFields["api_url"].exists)
        XCTAssertFalse(app.textFields["invite_api_url"].exists)
        tap(app.buttons["close_invite_entry"])
        // The rejected link must not replace the build endpoint: HTTP still fails locally.
        enter(app.textFields["login_username"], "pilot-test")
        enter(app.secureTextFields["login_password"], "test-only-password")
        tap(app.buttons["login_submit"])
        XCTAssertTrue(app.alerts["Operazione non riuscita"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HTTPS")).firstMatch.exists)
    }

    func testInviteCancelReopenAndHTTPSValidation() {
        openInvite()
        XCTAssertFalse(app.buttons["invite_submit"].isEnabled)
        XCTAssertFalse(app.buttons["login_dispatcher"].exists)
        enter(app.textFields["invite_username"], "corriere.test")
        enter(app.secureTextFields["invite_password"], "test-only-password")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.textFields["invite_username"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["invite_username"].value as? String, "corriere.test")
        tap(app.buttons["invite_submit"])
        let error = app.staticTexts["invite_error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("HTTPS"))
        XCTAssertFalse(app.buttons["shift_settings"].exists)
        XCTAssertFalse(app.buttons["invite_submit"].isEnabled, "Password is cleared after submission")
        tap(app.buttons["cancel_invite"])
        XCTAssertTrue(app.textFields["login_username"].waitForExistence(timeout: 5))
        openInvite()
        XCTAssertFalse(app.buttons["invite_submit"].isEnabled)
        XCTAssertNotEqual(app.textFields["invite_username"].value as? String, "corriere.test")
        XCTAssertFalse(app.staticTexts["invite_error"].exists)
        tap(app.buttons["cancel_invite"])
    }

    func testInviteEntryCanBeCancelledAndReopenedWithoutChangingLogin() {
        enter(app.textFields["login_username"], "corriere.test")
        for attempt in 0..<2 {
            tap(app.buttons["show_invite_entry"])
            XCTAssertTrue(app.textFields["invite_input"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["open_invite"].isEnabled)
            XCTAssertFalse(app.textFields["invite_api_url"].exists)
            if attempt == 0 {
                XCTAssertTrue(app.textFields["invite_input"].isHittable)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "ux-invite-entry"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            enter(app.textFields["invite_input"], "not-an-invite")
            tap(app.buttons["close_invite_entry"])
            XCTAssertTrue(app.textFields["login_username"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["login_username"].value as? String, "corriere.test")
            XCTAssertFalse(app.textFields["invite_input"].exists)
        }
    }

    private func openInvite() {
        tap(app.buttons["show_invite_entry"])
        enter(app.textFields["invite_input"], "arrivau://invite?token=\(token)")
        tap(app.buttons["open_invite"])
        XCTAssertTrue(app.textFields["invite_username"].waitForExistence(timeout: 5))
    }

    private func enter(_ field: XCUIElement, _ text: String) {
        tap(field)
        field.typeText(text)
    }

    private func tap(_ element: XCUIElement) {
        reveal(element)
        XCTAssertTrue(element.exists && element.isHittable && element.isEnabled)
        element.tap()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
    }
}
