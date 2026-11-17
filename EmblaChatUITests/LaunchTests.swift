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
    func testPrivacyIndicatorCoversSheetsAndDoesNotBlockKeyboardOrNavigation() throws {
        try verifyPrivacyIndicator(dark: false)
    }

    @MainActor
    func testPrivacyIndicatorInDarkAppearance() throws {
        try verifyPrivacyIndicator(dark: true)
    }

    @MainActor
    private func verifyPrivacyIndicator(dark: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--network-policy-fixture"]
        if dark { app.launchArguments.append("--network-dark-appearance") }
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let status = app.staticTexts["connectivity-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Privacy mode — network paused")
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let keyboard = XCTAttachment(screenshot: app.screenshot())
        keyboard.name = "Privacy border with keyboard"
        keyboard.lifetime = .keepAlways
        add(keyboard)
        app.buttons["Hide keyboard"].tap()
        app.buttons["Chat history"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "Privacy border above Settings"
        sheet.lifetime = .keepAlways
        add(sheet)
        app.buttons["Done"].tap()
        app.buttons["Context usage"].tap()
        XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 5))
        let context = XCTAttachment(screenshot: app.screenshot())
        context.name = "Privacy border above Context"
        context.lifetime = .keepAlways
        add(context)
        app.buttons["Done"].tap()
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["test-connectivity"].tap()
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 10), .completed)
        app.buttons["test-connectivity"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Privacy mode — network paused")
        app.buttons["Hide keyboard"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        XCTAssertTrue(status.exists && app.buttons["Chat history"].isHittable)
        let screen = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(screen.image.size.width, screen.image.size.height)
        let landscape = XCTAttachment(screenshot: screen)
        landscape.name = "Privacy border in landscape"
        landscape.lifetime = .keepAlways
        add(landscape)

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
        let disclosure = app.alerts.staticTexts.containing(
            NSPredicate(
                format: "label CONTAINS %@", "Keys are readable by anyone with folder access"))
        XCTAssertTrue(disclosure.firstMatch.exists)
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
        XCTAssertFalse(app.descendants(matching: .any)["compaction-summary-count"].exists)
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
        let bubbles = [email, translate, app.buttons["action-summarize"]]
        for bubble in bubbles {
            XCTAssertTrue(bubble.isHittable)
            XCTAssertGreaterThanOrEqual(bubble.frame.minX, 0)
            XCTAssertLessThanOrEqual(bubble.frame.maxX, app.frame.width)
        }
        XCTAssertGreaterThan(bubbles.last!.frame.minY, email.frame.minY)
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

    /// Requires the explicitly seeded local archive described in docs/quick-actions.md.
    /// It exercises presentation only; the saved assistant text identifies itself as a fixture.
    @MainActor
    func testQuickActionCloudFromExplicitFixture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let toggle = app.buttons["quick-actions-toggle"]
        guard toggle.waitForExistence(timeout: 5), app.buttons["New Chat"].exists else {
            throw XCTSkip("Seed the explicit quick-action UI fixture before selecting this test.")
        }
        let marker = "Saved UI fixture — not a model response."
        guard app.staticTexts[marker].exists else {
            throw XCTSkip("The current chat is not the explicit synthetic UI fixture.")
        }
        let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertEqual(composer.value as? String, "Fixture draft to protect")
        toggle.tap()
        let email = app.buttons["action-draft-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        let replacement = app.alerts["Replace draft?"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, "Fixture draft to protect")
        email.tap()
        replacement.buttons["Replace draft"].tap()
        let emailText = "Help me draft an email. Ask who it is for and what I want to say."
        expectation(for: NSPredicate(format: "value == %@", emailText), evaluatedWith: composer)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(email.exists)
        app.buttons["Hide keyboard"].tap()
        XCTAssertTrue(app.staticTexts[marker].exists, "The selected action must retain the chat")
        toggle.tap()
        let immediate = app.buttons["action-instant-fixture"]
        XCTAssertTrue(immediate.waitForExistence(timeout: 5))
        immediate.tap()
        let failure = app.staticTexts["quick-action-error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.label.contains("Download and verify"))
        XCTAssertEqual(composer.value as? String, emailText)
        XCTAssertEqual(app.staticTexts.matching(identifier: "user-message").count, 1)
        app.buttons["New Chat"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Hide keyboard"].tap()
        expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(toggle.exists)
        let ids =
            ["draft-email", "translate", "summarize"]
            + (0..<6).map { "fixture-\($0)" } + ["instant-fixture"]
        var rows = Set<Int>()
        for id in ids {
            let bubble = app.buttons["action-\(id)"]
            XCTAssertTrue(bubble.waitForExistence(timeout: 5))
            XCTAssertTrue(bubble.isHittable, "All ten actions must be visible without scrolling")
            XCTAssertGreaterThanOrEqual(bubble.frame.minX, 0)
            XCTAssertLessThanOrEqual(bubble.frame.maxX, app.frame.width)
            XCTAssertLessThanOrEqual(bubble.frame.maxY, composer.frame.minY)
            rows.insert(Int(bubble.frame.minY))
        }
        XCTAssertGreaterThan(rows.count, 1)
        let cloud = XCTAttachment(screenshot: app.screenshot())
        cloud.name = "Ten configured action bubbles wrap above the composer"
        cloud.lifetime = .keepAlways
        add(cloud)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
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
        reveal(app.buttons["MCP Servers"], in: app)
        app.buttons["MCP Servers"].tap()
        app.buttons["Browse registry"].tap()
        XCTAssertTrue(app.navigationBars["Server registry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["registry-source"].exists)
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("ab")
        XCTAssertTrue(app.staticTexts["registry-search-hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Retry"].exists)
        app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Close", "Cancel"])
        ).firstMatch.tap()
        app.navigationBars["Server registry"].buttons["MCP Servers"].tap()
        reveal(app.buttons["Add MCP server"], in: app)
        app.buttons["Add MCP server"].tap()
        let name = app.textFields["mcp-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let fixtureName = " UI fixture " + UUID().uuidString.prefix(8)
        name.typeText(fixtureName)
        XCTAssertEqual(
            app.textFields["mcp-endpoint"].value as? String, "https://example.invalid/mcp")
        app.buttons["Save server"].tap()
        let reload = app.buttons["Reload saved settings"]
        XCTAssertTrue(reload.waitForExistence(timeout: 5))
        reload.tap()
        for _ in 0..<4 {
            if name.exists && name.isHittable { break }
            app.swipeDown()
        }
        let refreshed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ AND enabled == true", fixtureName),
            object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 10), .completed)
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

extension LaunchTests {
    /// Explicit physical-device selection only: real app, model and a separate synthetic chat.
    @MainActor
    func testPhysicalPhoneCompactionWithRegisteredToolsAfterRestart() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Actual-model compaction is exercised only on a connected physical phone.")
        #else
            let app = XCUIApplication()
            app.launch()
            let composer = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 30))
            app.buttons["Chat history"].tap()
            let newChat = app.buttons["sidebar-new-chat"]
            let navigable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: newChat)
            XCTAssertEqual(XCTWaiter.wait(for: [navigable], timeout: 45), .completed)
            newChat.tap()
            let cleared = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "enabled == true AND (value == %@ OR value == %@)", "", "Message"),
                object: composer)
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 30), .completed)
            XCTAssertFalse(app.staticTexts["user-message"].exists)

            func waitForReply() {
                let finished = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true"), object: app.buttons["Send"])
                XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 180), .completed)
                // Send returns during the non-cancellable save.
                // New Chat stays disabled until the operation settles.
                let saved = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: app.buttons["New Chat"])
                XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 45), .completed)
                XCTAssertFalse(app.staticTexts["chat-error"].exists)
            }
            func openContext(recover: Bool) throws -> Int {
                app.buttons["Context usage"].tap()
                XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 10))
                if recover && app.buttons["Retry count"].waitForExistence(timeout: 3) {
                    app.buttons["Retry count"].tap()
                }
                let row = app.descendants(matching: .any)
                    .matching(identifier: "context-used").firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 45))
                let toolsRow = app.descendants(matching: .any)
                    .matching(identifier: "context-enabled-tools").firstMatch
                XCTAssertTrue(toolsRow.exists, "Enabled MCP tools must be part of this regression")
                let toolText =
                    ([toolsRow.label, toolsRow.value as? String ?? ""]
                    + toolsRow.staticTexts.allElementsBoundByIndex.map(\.label)).joined(
                        separator: " ")
                let number = try NSRegularExpression(pattern: "([0-9]+)")
                let toolCount = try XCTUnwrap(
                    number.firstMatch(
                        in: toolText, range: NSRange(toolText.startIndex..., in: toolText)))
                let enabled = try XCTUnwrap(
                    Int(
                        (toolText as NSString).substring(
                            with: toolCount.range(at: 1))))
                XCTAssertGreaterThan(
                    enabled, 0, "Configure and enable an MCP server before this test")
                let parts =
                    [row.label, row.value as? String ?? ""]
                    + row.staticTexts.allElementsBoundByIndex.map(\.label)
                let text = parts.joined(separator: " ")
                let regex = try NSRegularExpression(pattern: "([0-9]+) tokens")
                let match = try XCTUnwrap(
                    regex.firstMatch(
                        in: text, range: NSRange(text.startIndex..., in: text)))
                return try XCTUnwrap(Int((text as NSString).substring(with: match.range(at: 1))))
            }
            _ = try openContext(recover: true)
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 45))
            let prompts = [
                "Compaction diagnostic test. Remember: the project codename is BLUE PENGUIN. "
                    + "Numeric test padding is not a fact: "
                    + String(repeating: "0 1 2 3 4 5 6 7 8 9 ", count: 10)
                    + "Reply only Noted.",
                "Diagnostic note two. Keep the earlier project fact. Reply only Noted.",
                "Diagnostic note three. Reply only Noted.",
                "Diagnostic note four. Reply only Noted.",
            ]
            for prompt in prompts {
                composer.tap(); composer.typeText(prompt)
                app.buttons["Send"].tap()
                waitForReply()
            }
            let before = try openContext(recover: false)
            XCTAssertTrue(app.buttons["Compact now"].isEnabled)
            app.buttons["Compact now"].tap()
            waitForReply()
            let after = try openContext(recover: false)
            XCTAssertLessThan(after, before)
            XCTAssertTrue(app.descendants(matching: .any)["compaction-summary-count"].exists)
            let compacted = XCTAttachment(screenshot: app.screenshot())
            compacted.name =
                "Physical model compaction reduced context from \(before) to \(after) tokens"
            compacted.lifetime = .keepAlways
            add(compacted)
            app.buttons["Done"].tap()
            app.terminate(); app.launch()
            XCTAssertTrue(composer.waitForExistence(timeout: 30))
            _ = try openContext(recover: false)
            XCTAssertFalse(app.buttons["Retry count"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["compaction-summary-count"].exists)
            app.buttons["Done"].tap()
            waitForReply()
            composer.tap()
            composer.typeText("What is the project codename? Reply only with the codename.")
            app.buttons["Send"].tap()
            waitForReply()
            let recalled = app.descendants(matching: .any).matching(identifier: "answer").matching(
                NSPredicate(format: "label CONTAINS[c] %@", "BLUE PENGUIN")
            ).firstMatch
            XCTAssertTrue(recalled.waitForExistence(timeout: 10))
            let reply = XCTAttachment(screenshot: app.screenshot())
            reply.name = "Physical model recalled the saved summary after process restart"
            reply.lifetime = .keepAlways
            add(reply)
        #endif
    }
}
