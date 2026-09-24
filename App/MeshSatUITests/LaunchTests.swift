import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheFiveTabs() throws {
        let app = XCUIApplication()
        app.launch()
        for name in ["Home", "Messages", "Map", "People", "Setup"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 10), "tab \(name)")
        }
        app.buttons["Setup"].tap()
        XCTAssertTrue(app.staticTexts["Setup"].waitForExistence(timeout: 5))
    }
}
