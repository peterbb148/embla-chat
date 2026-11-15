import XCTest

/// Exercises the production chat UI without model downloads or substitute responses.
final class LaunchTests: XCTestCase {
    /// Every UI test starts through the real reset flow; persistence survives app launches now.
    @MainActor
    private func launchCleanChat() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        if app.buttons["New Chat"].isEnabled {
            app.buttons["New Chat"].tap()
            app.buttons["Start new chat"].tap()
            let cleared = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "enabled == true AND (value == %@ OR value == %@)", "", "Message"),
                object: composer)
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
            XCTAssertFalse(app.buttons["New Chat"].isEnabled)
        }
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    @MainActor
    func testModelControlsAreInSettings() throws {
        let app = try launchCleanChat()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Download model"].exists)
        app.buttons["Settings"].tap()
        reveal(app.buttons["Download model"], in: app)
        XCTAssertTrue(app.buttons["Download model"].exists)
        XCTAssertTrue(app.buttons["Download model"].isEnabled)
        reveal(app.staticTexts["model-status"], in: app)
        XCTAssertTrue(app.staticTexts["model-status"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Send"].exists)
        XCTAssertFalse(app.buttons["Download model"].exists)
    }

    @MainActor
    func testComposerFocusAndSendRequiresVerifiedModel() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertTrue(app.buttons["Hide keyboard"].exists)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertLessThanOrEqual(
            app.buttons["Send"].frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        composer.typeText("What is the capital of Denmark?")
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertFalse(app.staticTexts["answer"].exists)
    }

    @MainActor
    func testNewChatRequiresConfirmation() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Draft message")
        app.buttons["Hide keyboard"].tap()
        app.buttons["New Chat"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, "Draft message")
        app.buttons["New Chat"].tap()
        app.buttons["Start new chat"].tap()
        let cleared = NSPredicate(
            format: "enabled == true AND (value == %@ OR value == %@)", "", "Message")
        expectation(for: cleared, evaluatedWith: composer)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["New Chat"].isEnabled)
        XCTAssertFalse(app.staticTexts["answer"].exists)
    }

    @MainActor
    func testDraftSurvivesProcessRestartWithLocalOnlySaving() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        composer.tap()
        composer.typeText("Local draft survives restart")
        app.buttons["Settings"].tap()
        let storage = app.staticTexts["chat-storage-status"]
        XCTAssertTrue(storage.waitForExistence(timeout: 10))
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Saved on this device."), object: storage)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Local draft survives restart"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    }


    @MainActor
    func testICloudStartsOffAndCancellingConsentKeepsItOff() throws {
        let app = try launchCleanChat()
        app.buttons["Settings"].tap()
        let toggle = app.switches["icloud-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["Enable iCloud Drive?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(app.staticTexts["icloud-status"].label, "iCloud is off.")
    }

}
