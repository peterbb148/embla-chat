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
            XCTAssertFalse(app.alerts["Start a new chat?"].exists)
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
    func testNewChatStartsImmediatelyFromToolbarAndSidebar() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Draft message")
        app.buttons["Hide keyboard"].tap()
        app.buttons["New Chat"].tap()
        XCTAssertFalse(app.alerts["Start a new chat?"].exists)
        let cleared = NSPredicate(
            format: "enabled == true AND (value == %@ OR value == %@)", "", "Message")
        expectation(for: cleared, evaluatedWith: composer)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["New Chat"].isEnabled)
        XCTAssertFalse(app.staticTexts["answer"].exists)
        composer.tap()
        composer.typeText("Sidebar draft")
        app.buttons["Chat history"].tap()
        app.buttons["sidebar-new-chat"].tap()
        XCTAssertFalse(app.alerts["Start a new chat?"].exists)
        expectation(for: cleared, evaluatedWith: composer)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["New Chat"].isEnabled)
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
            predicate: NSPredicate(format: "value == %@", "Local draft survives restart"),
            object: composer)
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
        XCTAssertFalse(app.alerts["Start a new chat?"].exists)
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "enabled == true AND (value == %@ OR value == %@)", "", "Message"),
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

    @MainActor
    func testProjectsPersistAssignmentAndSeparateDrafts() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        let name = "Project \(UUID().uuidString.prefix(8))"
        let first = "First project draft \(UUID().uuidString.prefix(8))"
        let second = "Second project draft \(UUID().uuidString.prefix(8))"
        composer.tap()
        composer.typeText(first)
        app.buttons["Chat history"].tap()
        app.buttons["New project"].tap()
        let field = app.textFields["project-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons[first].waitForExistence(timeout: 5))
        app.buttons[first].press(forDuration: 1)
        app.buttons["Move to project"].tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.buttons[name].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        app.buttons["Chat history"].tap()
        app.buttons[name].tap()
        let newChat = app.buttons["New chat in project"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "enabled == true AND (value == %@ OR value == %@)", "", "Message"),
            object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 10), .completed)
        composer.tap()
        composer.typeText(second)
        app.buttons["Chat history"].tap()
        app.buttons[name].tap()
        XCTAssertTrue(app.buttons[first].waitForExistence(timeout: 5))
        app.buttons[first].tap()
        let original = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", first), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [original], timeout: 10), .completed)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", first), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    }

    @MainActor
    func testQuickActionsFillOnlyAndProtectExistingDrafts() throws {
        let app = try launchCleanChat()
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        let email = app.buttons["action-draft-email"]
        let translate = app.buttons["action-translate"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        let emailText = "Help me draft an email. Ask who it is for and what I want to say."
        let filled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", emailText), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["user-message"].exists)
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        let cards = XCTAttachment(screenshot: app.screenshot())
        cards.name = "Quick-action cards and filled composer"
        cards.lifetime = .keepAlways
        add(cards)
        translate.tap()
        let replacement = app.alerts["Replace draft?"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        let consent = XCTAttachment(screenshot: app.screenshot())
        consent.name = "Quick-action draft replacement confirmation"
        consent.lifetime = .keepAlways
        add(consent)
        replacement.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, emailText)
        translate.tap()
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.buttons["Replace draft"].tap()
        let translation = "Help me translate some text. Ask for the text and target language."
        let replaced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", translation), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["user-message"].exists)
        app.buttons["Chat history"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Manage quick actions"].tap()
        XCTAssertTrue(app.staticTexts["actions-source"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["actions-source"].label.contains("On My iPhone"))
        XCTAssertTrue(app.buttons["Reload actions"].isEnabled)
        XCTAssertFalse(app.staticTexts["actions-error"].exists)
    }

    @MainActor
    func testSkillsAndMCPManagementAreInSettings() throws {
        let app = try launchCleanChat()
        XCTAssertFalse(app.buttons["Choose skill"].exists)
        app.buttons["Chat history"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Manage skills"].tap()
        XCTAssertTrue(app.buttons["Reload skills"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["selected-skill"].exists)
        XCTAssertEqual(app.staticTexts["selected-skill"].label, "None")
        app.buttons["Reload skills"].tap()
        app.navigationBars["Skills"].buttons["Settings"].tap()
        app.buttons["MCP Servers"].tap()
        app.buttons["Browse registry"].tap()
        XCTAssertTrue(app.navigationBars["Server registry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["registry-source"].exists)
        app.navigationBars["Server registry"].buttons["MCP Servers"].tap()
        reveal(app.buttons["Add MCP server"], in: app)
        app.buttons["Add MCP server"].tap()
        let name = app.textFields["mcp-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" UI fixture " + UUID().uuidString.prefix(8))
        XCTAssertEqual(
            app.textFields["mcp-endpoint"].value as? String, "https://example.invalid/mcp")
        app.buttons["Save server"].tap()
        let connect = app.buttons["Connect and discover tools"]
        reveal(connect, in: app)
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["get_current_time"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MCP registration uses a synthetic invalid endpoint without credentials"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        reveal(app.buttons["Delete server…"], in: app)
        app.buttons["Delete server…"].tap()
        let confirmation = app.alerts["Delete this MCP server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete"].tap()
    }

}
