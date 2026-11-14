import XCTest

/// Checks the real minimal UI without downloading weights or substituting model output.
final class LaunchTests: XCTestCase {
    @MainActor
    func testModelSetupLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Download model"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Download model"].isEnabled)
        XCTAssertTrue(app.staticTexts["model-status"].exists)
    }

    @MainActor
    func testRunRequiresAVerifiedModel() throws {
        let app = XCUIApplication()
        app.launch()
        let prompt = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText("What is the capital of Denmark?")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["Run"].isEnabled)
        XCTAssertFalse(app.buttons["Stop"].isEnabled)
        XCTAssertFalse(app.staticTexts["answer"].exists)
    }

    @MainActor
    func testNewChatRequiresConfirmation() throws {
        let app = XCUIApplication()
        app.launch()
        let prompt = app.descendants(matching: .any).matching(identifier: "prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText("Draft prompt")
        app.buttons["Done"].tap()
        app.buttons["New Chat"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertEqual(prompt.value as? String, "Draft prompt")
        app.buttons["New Chat"].tap()
        app.buttons["Start new chat"].tap()
        let cleared = NSPredicate(format: "value == %@ OR value == %@", "", "Prompt")
        expectation(for: cleared, evaluatedWith: prompt)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["New Chat"].isEnabled)
        XCTAssertFalse(app.staticTexts["answer"].exists)
    }
}
