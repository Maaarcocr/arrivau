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
        enter(app.textFields["invite_input"], "arrivau://invite?token=\(token)&server=https://attacker.example")
        tap(app.buttons["open_invite"])
        XCTAssertTrue(app.alerts["Operazione non riuscita"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.textFields["invite_username"].exists)
        reveal(app.textFields["api_url"])
        XCTAssertEqual(app.textFields["api_url"].value as? String, "http://api.example.com")
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

    private func openInvite() {
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
