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
            let confirmation = app.alerts["Start a new chat?"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
            let start = confirmation.buttons["Start new chat"]
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"), object: start)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            start.tap()
            XCTAssertTrue(confirmation.waitForNonExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["Chat history"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Download model"].exists)
        app.buttons["Chat history"].tap()
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
        app.buttons["Chat history"].tap()
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
        app.buttons["Chat history"].tap()
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

    @MainActor
    func testContextButtonExplainsUnavailableCountingAndCompaction() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        composer.tap()
        composer.typeText("Draft retained while viewing context")
        app.buttons["Context usage"].tap()
        XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Compact now"].exists)
        XCTAssertFalse(app.buttons["Compact now"].isEnabled)
        XCTAssertFalse(app.staticTexts["context-used"].exists)
        app.buttons["Done"].tap()
        XCTAssertEqual(composer.value as? String, "Draft retained while viewing context")
        XCTAssertFalse(app.staticTexts["answer"].exists)
    }

    @MainActor
    func testHistoryRestoresBothDraftsAfterRestart() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        let first = "First local chat \(UUID().uuidString.prefix(8))"
        let second = "Second local chat \(UUID().uuidString.prefix(8))"
        composer.tap()
        composer.typeText(first)
        app.buttons["Hide keyboard"].tap()
        app.buttons["New Chat"].tap()
        let confirmation = app.alerts["Start a new chat?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Start new chat"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND (value == %@ OR value == %@)", "", "Message"),
            object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 10), .completed)
        composer.tap()
        composer.typeText(second)
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons[first].waitForExistence(timeout: 5))
        app.buttons[first].tap()
        let firstRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", first), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [firstRestored], timeout: 10), .completed)
        // Navigation itself saved both drafts; terminate without a test-only persistence hook.
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let afterRestart = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", first), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [afterRestart], timeout: 10), .completed)
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons[second].waitForExistence(timeout: 5))
        app.buttons[second].tap()
        let secondRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", second), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [secondRestored], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["Send"].isEnabled)
    }

}
