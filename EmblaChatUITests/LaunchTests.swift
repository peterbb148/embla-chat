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
                predicate: NSPredicate(format: "enabled == false"), object: app.buttons["New Chat"])
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        }
        return app
    }

    @MainActor
    func testModelControlsAreInSettings() throws {
        let app = try launchCleanChat()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Download model"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Download model"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Download model"].isEnabled)
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
        let cleared = NSPredicate(format: "value == %@ OR value == %@", "", "Message")
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

}
