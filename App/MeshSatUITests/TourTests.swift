import XCTest

// A walk through every screen, one at a time, with a pause on each so that screenshots can be
// taken from outside (pymobiledevice3 developer dvt screenshot on the laptop the phone is plugged
// into). It taps navigation only: never a send, an SOS, a delete or a toggle. Run it on the phone
// with `pymobiledevice3 developer dvt xcuitest net.meshsat.ios.uitests.xctrunner`.
final class TourTests: XCTestCase {
    private let dwell: TimeInterval = 5

    @MainActor
    func testTourEveryScreen() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The tour is for the phone; on the simulator it only costs seven minutes.")
        #endif
        // pymobiledevice3 runs the whole bundle: each phone test answers to MESHSAT_PROVE.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MESHSAT_PROVE"] == "tour", "MESHSAT_PROVE=tour runs the tour")
        let app = XCUIApplication()
        // activate() keeps a running app and its node link; launch() first kills it, and on a
        // phone the relaunch is refused while the kill's termination assertions are outstanding.
        app.activate()
        if !app.buttons["Home"].waitForExistence(timeout: 15) {
            app.terminate()
            Thread.sleep(forTimeInterval: 5)
            app.launch()
        }
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20))
        pause("home")
        scrollAndPause(app, "home-2")

        for tab in ["Messages", "Map", "People"] {
            app.buttons[tab].firstMatch.tap()
            pause(tab)
            scrollAndPause(app, "\(tab)-2")
        }

        app.buttons["Setup"].firstMatch.tap()
        pause("setup")
        let sections = [
            "Your MeshSat node", "Satellite", "Hub", "SMS", "Safety", "Messaging", "Maps",
            "Ham radio, TAK and Reticulum", "Mesh radio settings",
        ]
        for section in sections {
            open(app, section)
            pause(section)
            scrollAndPause(app, "\(section)-2")
            back(app)
        }

        open(app, "Advanced")
        pause("advanced")
        let advanced = [
            "Routing rules", "Links", "Message queue", "Mesh topology", "Audit log",
            "Certificates and keys", "Encrypt or decrypt text", "Diagnostics",
        ]
        for row in advanced {
            open(app, row)
            pause(row)
            scrollAndPause(app, "\(row)-2")
            back(app)
        }
        back(app)

        for row in ["About"] {
            open(app, row)
            pause(row)
            scrollAndPause(app, "\(row)-2")
            back(app)
        }

        app.buttons["Home"].firstMatch.tap()
        // The SOS screen itself is safe to look at: sending needs a hold on its own button.
        if openIfPresent(app, "SOS") {
            pause("sos")
            back(app)
        }
        pause("end")
    }

    // MARK: - helpers

    private func pause(_ name: String) {
        NSLog("MeshSatTour: %@", name)
        Thread.sleep(forTimeInterval: dwell)
    }

    @MainActor
    private func scrollAndPause(_ app: XCUIApplication, _ name: String) {
        app.swipeUp()
        NSLog("MeshSatTour: %@", name)
        Thread.sleep(forTimeInterval: 3)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        if button.exists { return button }
        return app.staticTexts[label].firstMatch
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ label: String) {
        let target = element(app, label)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "row \(label)")
        var tries = 0
        while !target.isHittable, tries < 4 {
            app.swipeUp()
            tries += 1
        }
        target.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    @discardableResult
    private func openIfPresent(_ app: XCUIApplication, _ label: String) -> Bool {
        let target = element(app, label)
        guard target.waitForExistence(timeout: 3), target.isHittable else { return false }
        target.tap()
        Thread.sleep(forTimeInterval: 1)
        return true
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let backButton = app.buttons["Back"].firstMatch
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        Thread.sleep(forTimeInterval: 1)
    }
}
