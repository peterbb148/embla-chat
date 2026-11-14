import XCTest

/// Verifies model setup is accessible without downloading weights or running inference.
final class LaunchTests: XCTestCase {
    @MainActor
    func testModelSetupLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Download model"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["model-status"].exists)
    }
}
