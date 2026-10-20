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

    /// Settings > Advanced > Node log (MESHSAT-1374): switch the node's log on, wait for the node to
    /// restart and reconnect, and hold the screen while lines stream in for the screenshots.
    @MainActor
    func testNodeLog() throws {
        try gate("nodelog")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Advanced")
        tap(app, "Node log")
        XCTAssertTrue(app.staticTexts["Stream the node's log"].waitForExistence(timeout: 10), "the switch's row")
        Thread.sleep(forTimeInterval: 4)  // the screen before the switch, for the screenshot
        let toggle = app.buttons["Stream the node's log"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the switch")
        if toggle.value as? String != "On" {
            toggle.tap()
            // A security set_config makes the node restart once; the link comes back by itself.
            Thread.sleep(forTimeInterval: 45)
        }
        // Lines arrive as the node logs; give it a minute and keep the screen for the captures.
        var lines = 0
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 5)
            let stamped = NSPredicate(format: "label MATCHES '^[0-9]{2}:[0-9]{2}:[0-9]{2}.*'")
            lines = app.staticTexts.matching(stamped).count
            if lines >= 5 { break }
        }
        NSLog("MeshSatProve: node log lines on screen: %d", lines)
        XCTAssertGreaterThan(lines, 0, "at least one line from the node")
        tap(app, "Pause")
        Thread.sleep(forTimeInterval: 5)
        tap(app, "Resume")
        Thread.sleep(forTimeInterval: 10)
        openTab(app, "Setup")
    }

    /// Setup > Satellite: the Node health card from STATS (MESHSAT-1378), scrolled into view.
    @MainActor
    func testNodeHealth() throws {
        try gate("health")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Satellite")
        Thread.sleep(forTimeInterval: 4)
        let card = app.staticTexts["Node health"].firstMatch
        var tries = 0
        while !card.exists || !card.isHittable, tries < 4 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            tries += 1
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the Node health card (a node with STATS)")
        let rows = ["Modem", "Signal", "Sessions since boot", "Last session", "Node uptime"]
        for row in rows { NSLog("MeshSatProve: row %@ %@", row, app.staticTexts[row].firstMatch.exists ? "present" : "absent") }
        XCTAssertTrue(app.staticTexts["Modem"].firstMatch.waitForExistence(timeout: 15), "the Modem row (STATS answered)")
        Thread.sleep(forTimeInterval: 15)  // two STATS re-reads, for the screenshots
        openTab(app, "Setup")
    }

    /// Setup > Hub > Connection details: "Messages through the Hub" on (hub_msg, MESHSAT-1584), then
    /// the app started again, since the gateway reads the switch when it starts.
    @MainActor
    func testHubMsgSwitch() throws {
        try gate("hubswitch")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Hub")
        tap(app, "Connection details")
        // A toggle-trait control is a switch to XCUITest; older runners saw it as a button.
        let name = "Messages through the Hub"
        var tries = 0
        func toggle() -> XCUIElement { app.switches[name].exists ? app.switches[name].firstMatch : app.buttons[name].firstMatch }
        while !(toggle().exists && toggle().isHittable), tries < 6 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            tries += 1
        }
        XCTAssertTrue(toggle().waitForExistence(timeout: 10), "the switch")
        func isOn() -> Bool { ["On", "1"].contains(toggle().value as? String ?? "") }
        Thread.sleep(forTimeInterval: 3)  // the screen before, for the screenshot
        if !isOn() { toggle().tap() }
        Thread.sleep(forTimeInterval: 3)
        NSLog("MeshSatProve: hub_msg switch %@", (toggle().value as? String) ?? "?")
        XCTAssertTrue(isOn(), "the switch is on")
        app.terminate()
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 30), "the app again")
        Thread.sleep(forTimeInterval: 15)  // the Hub connect, for the log
    }

    /// A text to another MeshSat app or kit through the Hub (MESHSAT_HUB_PEER = its bridge id), and
    /// the two checks once that app has it.
    @MainActor
    func testHubMsgSend() throws {
        try gate("hubmsg")
        let peer = try XCTUnwrap(env["MESHSAT_HUB_PEER"], "MESHSAT_HUB_PEER")
        let text = env["MESHSAT_TEXT"] ?? "iPhone to \(peer) through the Hub"
        let app = attach()
        // A dialog an earlier run left open sits over the tab: close it first.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        openTab(app, "Messages")
        tap(app, "New message")
        // The field's label is drawn over it, not its name: take the field nearest the label, even
        // half under the dialog's scroll edge (a tap scrolls it into view).
        let label = app.staticTexts["Or a MeshSat app's Hub bridge id"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10), "the bridge id field's label")
        let fields = app.textFields.allElementsBoundByIndex.filter { $0.exists }
        let idField = try XCTUnwrap(
            fields.min { abs($0.frame.midY - label.frame.midY) < abs($1.frame.midY - label.frame.midY) }, "the bridge id field")
        idField.tap()
        idField.typeText(peer)
        XCTAssertEqual(idField.value as? String, peer, "the bridge id as typed")
        tap(app, "Message through the Hub")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer")
        field.tap()
        field.typeText(text)
        // The Send button is enabled once the text has reached the view's state, not at once. The
        // keyboard's own Send key matches the label too, and on this multi-line field it does not
        // send: take the app's button, the one outside the keyboard.
        let deadline = Date().addingTimeInterval(10)
        var sendButton: XCUIElement?
        while Date() < deadline, sendButton == nil {
            let keyboard = app.keyboards.firstMatch
            let keys = keyboard.exists ? keyboard.frame : .null
            sendButton = app.buttons.matching(NSPredicate(format: "label == %@", "Send")).allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.isEnabled && !keys.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            if sendButton == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        try XCTUnwrap(sendButton, "an enabled Send button").tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "the bubble")
        let delivered = app.images["Delivered"].firstMatch
        let ok = delivered.waitForExistence(timeout: 90)
        NSLog("MeshSatProve: hub_msg to %@ delivered=%@", peer, ok ? "yes" : "no")
        XCTAssertTrue(ok, "two checks")
        Thread.sleep(forTimeInterval: 20)  // an answer from the far end, for the screenshots
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

    /// A real SOS from the Home card, held for 3 seconds. It refuses to hold the button unless the
    /// card says the SOS goes by the Hub and nowhere else: a proof must never text a person, or put
    /// an SOS on the mesh or a satellite. The Hub pages its on-call chain once.
    @MainActor
    func testSosStart() throws {
        try gate("sos-start")
        let app = attach()
        openTab(app, "Home")
        let hubOnly = app.staticTexts["Sends your position by the Hub, and keeps trying until you cancel."].firstMatch
        var swipes = 0
        while !(hubOnly.exists && hubOnly.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
            Thread.sleep(forTimeInterval: 0.8)
        }
        guard hubOnly.exists else { return XCTFail("the SOS card does not say the Hub only: not holding the button") }
        let hold = app.buttons["Hold 3 seconds for SOS"].firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        hold.press(forDuration: 3.6)
        let on = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "SOS is on")).firstMatch
        let started = on.waitForExistence(timeout: 10)
        NSLog("MeshSatProve: sos started=%@", started ? "yes" : "no")
        XCTAssertTrue(started, "SOS is on")
        Thread.sleep(forTimeInterval: 15)  // the Hub's ack, for the screenshot and the log
    }

    /// Cancels the SOS from the Home card and its confirmation.
    @MainActor
    func testSosCancel() throws {
        try gate("sos-cancel")
        let app = attach()
        openTab(app, "Home")
        tap(app, "Cancel SOS")
        XCTAssertTrue(app.staticTexts["Cancel the SOS?"].firstMatch.waitForExistence(timeout: 5), "the confirmation")
        // The dialog's button is drawn over the card's, so it is the last hittable one.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel SOS")).allElementsBoundByIndex.last {
            $0.exists && $0.isHittable
        }
        guard let confirm else { return XCTFail("no Cancel SOS in the confirmation") }
        confirm.tap()
        let off = app.staticTexts["Cancel the SOS?"].firstMatch.waitForNonExistence(timeout: 5)
        NSLog("MeshSatProve: sos cancel confirmed=%@", off ? "yes" : "no")
        XCTAssertTrue(off)
        Thread.sleep(forTimeInterval: 15)  // the Hub's ack, for the screenshot and the log
    }
}
