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

    // MARK: 0.3.0 (the Android catch-up of 7 Nov 2026)

    /// The notification prompt of the first start (MESHSAT-1823): Allow, on the springboard's alert.
    @MainActor
    func testNotificationPrompt() throws {
        try gate("notify")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.activate()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) {
            Thread.sleep(forTimeInterval: 3)  // the screenshot of the prompt
            allow.tap()
            NSLog("MeshSatProve: notifications allowed on the prompt")
        } else {
            NSLog("MeshSatProve: no notification prompt (answered before)")
        }
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20))
    }

    /// Setup > Safety > Warnings, the list of relayed public warnings (MESHSAT-1819).
    @MainActor
    func testWarningsList() throws {
        try gate("warnings")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Safety")
        tap(app, "Warnings")
        Thread.sleep(forTimeInterval: 6)
        NSLog("MeshSatProve: warnings list %@", app.staticTexts["No warning heard yet."].exists ? "empty" : "has rows")
        openTab(app, "Setup")
    }

    /// Setup > Field kits on your network: a kit added with its LAN address (MESHSAT_KIT_URL), saved
    /// and checked (MESHSAT-1820). The line under it is the proof: Reachable, or the token prompt.
    @MainActor
    func testFieldKit() throws {
        try gate("kit")
        let url = env["MESHSAT_KIT_URL"] ?? "192.168.181.210"
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Field kits on your network")
        // Start clean: the cards an earlier run left go first.
        var removed = 0
        while removed < 10, app.buttons["Remove"].firstMatch.exists, app.buttons["Remove"].firstMatch.isHittable {
            app.buttons["Remove"].firstMatch.tap()
            removed += 1
            Thread.sleep(forTimeInterval: 1)
        }
        tap(app, "Add a kit")
        Thread.sleep(forTimeInterval: 1)
        let fields = app.textFields.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        XCTAssertGreaterThanOrEqual(fields.count, 2, "the kit card's name and address fields")
        fields[0].tap()
        fields[0].typeText(env["MESHSAT_KIT_NAME"] ?? "tesseract")
        fields[1].tap()
        fields[1].typeText(url)
        tap(app, "Save")
        tap(app, "Check")
        // iOS asks once whether the app may reach devices on the local network; the first request
        // fails while it asks.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) {
            Thread.sleep(forTimeInterval: 2)  // the screenshot of the prompt
            allow.tap()
            NSLog("MeshSatProve: local network allowed on the prompt")
            Thread.sleep(forTimeInterval: 2)
            tap(app, "Check")
        }
        let lines = NSPredicate(
            format: "label BEGINSWITH 'Reachable' OR label BEGINSWITH 'Not reachable' OR label BEGINSWITH 'This kit asks'")
        let line = app.staticTexts.matching(lines).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the kit's line after Check")
        NSLog("MeshSatProve: kit check %@", line.label)
        Thread.sleep(forTimeInterval: 5)
        openTab(app, "Setup")
    }

    /// Setup > Help > Support: Send feedback with the debug.zip attached (MESHSAT-1810). It stops at
    /// Mail's composer (or the share sheet without a Mail account) and never presses Send: a mail
    /// from the owner's account goes only on the owner's own tap.
    @MainActor
    func testSupportMail() throws {
        try gate("support")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Support")
        Thread.sleep(forTimeInterval: 3)
        let field = app.textFields.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        field?.tap()
        field?.typeText(env["MESHSAT_SUPPORT_TEXT"] ?? "Test from MeshSat iOS 0.3.0 on the bench, please ignore.")
        tap(app, "Send feedback")
        let composer = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS[c] 'mail' OR identifier CONTAINS 'MeshSat iOS'")
        ).firstMatch
        let shared = app.otherElements["ActivityListView"].firstMatch
        let shown = composer.waitForExistence(timeout: 20) || shared.waitForExistence(timeout: 5)
        NSLog("MeshSatProve: support %@", composer.exists ? "Mail composer open" : (shared.exists ? "share sheet open" : "nothing shown"))
        XCTAssertTrue(shown, "Mail's composer or the share sheet")
        Thread.sleep(forTimeInterval: 8)  // the screenshots; the composer stays open for the owner
    }

    /// Setup > Your MeshSat node: scan, connect to the node named MESHSAT_NODE_NAME and answer iOS's
    /// pairing prompt with MESHSAT_PIN (the node logs its passkey at boot). Nothing is sent anywhere.
    @MainActor
    func testPairNode() throws {
        try gate("pair")
        let name = env["MESHSAT_NODE_NAME"] ?? "0001"
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Your MeshSat node")
        if app.buttons["Disconnect"].firstMatch.exists {
            app.buttons["Disconnect"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let cont = app.buttons["Continue"].firstMatch
        if cont.exists, cont.isHittable { cont.tap() }
        tap(app, "Scan for Meshtastic devices")
        let found = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 30), "\(name) in the scan")
        Thread.sleep(forTimeInterval: 2)
        found.tap()
        if let pin = env["MESHSAT_PIN"], !pin.isEmpty {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let field =
                springboard.textFields.firstMatch.exists ? springboard.textFields.firstMatch : springboard.secureTextFields.firstMatch
            if field.waitForExistence(timeout: 30) {
                Thread.sleep(forTimeInterval: 2)
                field.tap()
                field.typeText(pin)
                let pair = springboard.buttons["Pair"].firstMatch
                if pair.waitForExistence(timeout: 5) { pair.tap() }
                NSLog("MeshSatProve: pairing code entered")
            } else {
                NSLog("MeshSatProve: no pairing prompt (bonded already)")
            }
        }
        XCTAssertTrue(app.buttons["Disconnect"].firstMatch.waitForExistence(timeout: 90), "connected to the node")
        Thread.sleep(forTimeInterval: 20)  // the node's Service Changed reconnect after a fresh bond
    }

    /// Night mode (MESHSAT-1827): switch it on from the Home header, walk the tabs and one sub-screen
    /// for the screenshots, switch it off again. MESHSAT_NIGHT_KEEP=1 leaves it on.
    @MainActor
    func testNightMode() throws {
        try gate("night")
        let app = attach()
        openTab(app, "Home")
        let toggle = app.buttons["Night mode"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the night mode button")
        toggle.tap()
        Thread.sleep(forTimeInterval: 4)
        for tab in ["Home", "Messages", "Map", "People", "Setup"] {
            openTab(app, tab)
            Thread.sleep(forTimeInterval: 4)
        }
        tap(app, "Satellite")
        Thread.sleep(forTimeInterval: 4)
        openTab(app, "Home")
        if env["MESHSAT_NIGHT_KEEP"] != "1" {
            app.buttons["Night mode"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        NSLog("MeshSatProve: night mode walked")
    }

    /// Reticulum/LXMF against a stock Python RNS node on the LAN (MESHSAT-1735, the twin of Android's 13 Oct
    /// proof). Unless MESHSAT_RNS_SETUP=0, the RNS TCP client is pointed at MESHSAT_RNS_HOST:MESHSAT_RNS_PORT
    /// and the app restarted (the gateway reads it at start). Then: the phone's LXMF address in the log,
    /// Announce now, a text to MESHSAT_LXMF_DEST by MESHSAT_LXMF_METHOD (Direct) that must reach the mark
    /// MESHSAT_LXMF_MARK (Delivered; "At the propagation node" for Propagated), and, with MESHSAT_LXMF_EXPECT
    /// set, up to three minutes for that text from the far end; MESHSAT_LXMF_SYNC=1 presses Sync now first.
    @MainActor
    func testLxmf() throws {
        try gate("lxmf")
        let dest = try XCTUnwrap(env["MESHSAT_LXMF_DEST"], "MESHSAT_LXMF_DEST").lowercased()
        let method = env["MESHSAT_LXMF_METHOD"] ?? "Direct"
        let mark = env["MESHSAT_LXMF_MARK"] ?? (method == "Propagated" ? "At the propagation node" : "Delivered")
        let text = env["MESHSAT_TEXT"] ?? "iPhone to \(dest.prefix(8)) by Reticulum, \(method)"
        var app = attach()
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        if env["MESHSAT_RNS_SETUP"] != "0" {
            openTab(app, "Setup")
            tap(app, "Ham radio, TAK and Reticulum")
            let hostField = try fieldNear(app, label: "Host")
            replaceText(app, hostField, with: env["MESHSAT_RNS_HOST"] ?? "192.168.181.111")
            let portField = try fieldNear(app, label: "Port", below: hostField)
            replaceText(app, portField, with: env["MESHSAT_RNS_PORT"] ?? "4242")
            app.swipeDown()  // the keyboard away
            let enable = try scrollToToggle(app, "Enable RNS TCP")
            if !isOn(enable) { enable.tap() }
            // The card has several Save buttons: the one right under the TLS switch.
            let tls = try scrollToToggle(app, "TLS")
            let save = try XCTUnwrap(
                app.buttons.matching(NSPredicate(format: "label == %@", "Save")).allElementsBoundByIndex
                    .filter { $0.exists && $0.frame.minY > tls.frame.minY }.min { $0.frame.minY < $1.frame.minY }, "the TCP Save")
            save.tap()
            NSLog("MeshSatProve: lxmf tcp client saved, restarting the app")
            Thread.sleep(forTimeInterval: 2)
            app.terminate()
            Thread.sleep(forTimeInterval: 3)
            app = attach()
            Thread.sleep(forTimeInterval: 12)  // the TCP connect and the first announces
        }
        openTab(app, "Setup")
        tap(app, "Ham radio, TAK and Reticulum")
        let hexes = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9a-f]+$")).allElementsBoundByIndex
        let address = hexes.first { $0.exists && $0.label.count == 32 }?.label ?? "?"
        NSLog("MeshSatProve: lxmf address %@", address)
        tap(app, "Announce now")
        Thread.sleep(forTimeInterval: 3)
        if let chip = env["MESHSAT_LXMF_PN"], !chip.isEmpty {
            tap(app, chip)
            Thread.sleep(forTimeInterval: 2)
        }
        if env["MESHSAT_LXMF_SYNC"] == "1" {
            tap(app, "Sync now")
            Thread.sleep(forTimeInterval: 10)
        }
        openTab(app, "Messages")
        tap(app, "Reticulum")
        tap(app, "New message")
        let field = try fieldNear(app, label: "Or a Reticulum (LXMF) address, 32 hex")
        field.tap()
        field.typeText(dest)
        tap(app, "Message this address")
        Thread.sleep(forTimeInterval: 1)
        tap(app, method)
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer")
        composer.tap()
        composer.typeText(text)
        try sendButton(app).tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "the bubble")
        let marked = app.images[mark].firstMatch.waitForExistence(timeout: 120)
        NSLog("MeshSatProve: lxmf %@ to %@ mark '%@'=%@", method, dest, mark, marked ? "yes" : "no")
        XCTAssertTrue(marked, mark)
        if let expect = env["MESHSAT_LXMF_EXPECT"], !expect.isEmpty {
            let got = app.staticTexts[expect].waitForExistence(timeout: 180)
            NSLog("MeshSatProve: lxmf inbound '%@' shown=%@", expect, got ? "yes" : "no")
            XCTAssertTrue(got, "the far end's text")
        }
        Thread.sleep(forTimeInterval: 5)
    }

    /// The text field nearest a label drawn over it (the MSOutlinedTextField pattern), scrolled on screen.
    @MainActor
    private func fieldNear(_ app: XCUIApplication, label: String, below: XCUIElement? = nil) throws -> XCUIElement {
        let text = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        var tries = 0
        var anchor: XCUIElement?
        while anchor == nil, tries < 8 {
            anchor = text.first { $0.exists && $0.isHittable && (below == nil || $0.frame.minY >= below!.frame.minY - 1) }
            if anchor == nil {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.8)
                tries += 1
            }
        }
        let a = try XCTUnwrap(anchor, "the label '\(label)'")
        let fields = app.textFields.allElementsBoundByIndex.filter { $0.exists }
        return try XCTUnwrap(fields.min { abs($0.frame.midY - a.frame.midY) < abs($1.frame.midY - a.frame.midY) }, "the field '\(label)'")
    }

    /// Types over whatever a field holds.
    @MainActor
    private func replaceText(_ app: XCUIApplication, _ field: XCUIElement, with value: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.2)
            let all = app.menuItems["Select All"]
            if all.waitForExistence(timeout: 3) { all.tap() }
        }
        field.typeText(value)
    }

    /// A switch by its label, scrolled on screen (a toggle-trait control; older runners saw a button).
    @MainActor
    private func scrollToToggle(_ app: XCUIApplication, _ name: String) throws -> XCUIElement {
        func toggle() -> XCUIElement { app.switches[name].exists ? app.switches[name].firstMatch : app.buttons[name].firstMatch }
        var tries = 0
        while !(toggle().exists && toggle().isHittable), tries < 8 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            tries += 1
        }
        XCTAssertTrue(toggle().waitForExistence(timeout: 5), "the switch '\(name)'")
        return toggle()
    }

    private func isOn(_ toggle: XCUIElement) -> Bool { ["On", "1"].contains(toggle.value as? String ?? "") }

    /// The app's enabled Send button, never the keyboard's key of the same name.
    @MainActor
    private func sendButton(_ app: XCUIApplication) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        var found: XCUIElement?
        while Date() < deadline, found == nil {
            let keyboard = app.keyboards.firstMatch
            let keys = keyboard.exists ? keyboard.frame : .null
            found = app.buttons.matching(NSPredicate(format: "label == %@", "Send")).allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.isEnabled && !keys.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            if found == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        return try XCTUnwrap(found, "an enabled Send button")
    }
}
