import XCTest

// The proving checklist, driven on the phone over USB (pymobiledevice3 developer dvt xcuitest
// with --env MESHSAT_PROVE=<name>): one test per row of the README's proven table that needs a
// tap. Each one attaches to the running app and never touches Bluetooth or the node itself.
final class ProvingTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func gate(_ name: String) throws {
        try XCTSkipUnless(env["MESHSAT_PROVE"] == name, "MESHSAT_PROVE=\(name) runs this")
    }

    @MainActor
    private func attach() -> XCUIApplication {
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20))
        return app
    }

    /// Selects a tab and pops its stack to the root: a tab keeps whatever sub-screen the last
    /// run left it on.
    @MainActor
    private func openTab(_ app: XCUIApplication, _ name: String) {
        app.buttons[name].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        var pops = 0
        while pops < 6 {
            let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).allElementsBoundByIndex.first {
                $0.exists && $0.isHittable
            }
            guard let back else { break }
            back.tap()
            pops += 1
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    /// The first on-screen, hittable element with this label: the hidden tab stacks keep their
    /// elements in the tree, so firstMatch alone can land on a Home lane while Setup is showing.
    @MainActor
    private func tap(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        var candidate: XCUIElement?
        while Date() < deadline, candidate == nil {
            let pool =
                app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ","))
                .allElementsBoundByIndex + app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            // Never the keyboard's own key of the same name: only elements above it.
            let keyboard = app.keyboards.firstMatch
            let keyboardTop = keyboard.exists ? keyboard.frame.minY : .greatestFiniteMagnitude
            candidate = pool.first { $0.exists && $0.isHittable && $0.frame.maxY <= keyboardTop }
            if candidate == nil {
                if let offscreen = pool.first(where: { $0.exists && $0.frame.minY > app.frame.height * 0.8 }) {
                    app.swipeUp()
                    _ = offscreen
                } else {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        guard let target = candidate else { return XCTFail("'\(label)' is not on screen") }
        target.tap()
    }

    /// A text to everyone on the mesh, from the New message dialog.
    @MainActor
    func testMeshText() throws {
        try gate("mesh")
        let app = attach()
        let text = env["MESHSAT_TEXT"] ?? "25-sep-2026 test from iPhone over the mesh"
        openTab(app, "Messages")
        tap(app, "New message")
        tap(app, "Everyone on the mesh")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer")
        field.tap()
        field.typeText(text)
        tap(app, "Send")
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "the bubble")
        openTab(app, "Home")  // and the keyboard goes with the tab
        Thread.sleep(forTimeInterval: 25)  // the mesh ACK, for the log
    }

    /// The passes screen, opened while the laptop has the phone's network at 100 percent loss.
    @MainActor
    func testPassesOffline() throws {
        try gate("passes")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Satellite")
        tap(app, "Satellite passes")
        XCTAssertTrue(app.staticTexts["Satellite passes"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 8)  // screenshots from the laptop
        app.swipeUp()
        Thread.sleep(forTimeInterval: 4)
    }

    /// A contact card pasted as text (MESHSAT_CARD), read, and added.
    @MainActor
    func testContactCardPaste() throws {
        try gate("card")
        let card = try XCTUnwrap(env["MESHSAT_CARD"], "MESHSAT_CARD")
        let app = attach()
        openTab(app, "People")
        tap(app, "Paste a card instead")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "paste field")
        field.tap()
        field.typeText(card)
        tap(app, "Read it")
        XCTAssertTrue(
            app.staticTexts["Check this fingerprint against the one on their screen. If it differs, the card is not theirs."]
                .waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 5)  // the fingerprint, for the screenshot
        tap(app, "Add")
        XCTAssertTrue(app.staticTexts["Ankh test card"].waitForExistence(timeout: 10), "the card in the list")
        Thread.sleep(forTimeInterval: 5)
    }

    /// The four Advanced sub-screens the tour could not reach, for the parity captures.
    @MainActor
    func testAdvancedScreens() throws {
        try gate("advanced")
        let app = attach()
        for row in ["Message queue", "Audit log", "Certificates and keys", "Encrypt or decrypt text"] {
            openTab(app, "Setup")
            tap(app, "Advanced")
            tap(app, row)
            Thread.sleep(forTimeInterval: 6)
            app.swipeUp()
            Thread.sleep(forTimeInterval: 4)
        }
        openTab(app, "Setup")
    }

    /// The alarm test from the Home SOS card: confirm, then send each text the composer opens.
    @MainActor
    func testAlarm() throws {
        try gate("alarm")
        let app = attach()
        openTab(app, "Home")
        tap(app, "Test the alarm")
        tap(app, "Send the test")
        // The Messages composer, one per emergency contact: its Send button is the system's.
        for _ in 0..<3 {
            let send = app.buttons["Send"].firstMatch
            guard send.waitForExistence(timeout: 15) else { break }
            Thread.sleep(forTimeInterval: 3)  // the screenshot of the composer
            send.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        Thread.sleep(forTimeInterval: 20)  // the routes report, for the screenshot and the log
        if app.buttons["Stop test"].firstMatch.waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 5)
            app.buttons["Stop test"].firstMatch.tap()
        }
    }
}
