import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheFiveTabs() throws {
        #if !targetEnvironment(simulator)
        // On the phone a launch kills the running app and its node link; the proving tests
        // attach instead. This one is the simulator's.
        throw XCTSkip("simulator only")
        #endif
        let app = XCUIApplication()
        app.launch()
        for name in ["Home", "Messages", "Map", "People", "Setup"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 10), "tab \(name)")
        }
        app.buttons["Setup"].tap()
        XCTAssertTrue(app.staticTexts["Setup"].waitForExistence(timeout: 5))
    }
}
