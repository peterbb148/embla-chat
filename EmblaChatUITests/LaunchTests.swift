import XCTest

/// Verifies that the real app launches; this does not exercise model inference.
final class LaunchTests: XCTestCase {
    @MainActor
    func testScaffoldLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts[
            "Model setup and local chat are coming in the next milestone."
        ].waitForExistence(timeout: 10))
    }
}
