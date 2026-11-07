// The Reticulum/LXMF proofs of ProvingTests (MESHSAT-1735), apart for the class-length rule: the
// TCP client pointed at a stock Python node, LXMF text both ways, and the voice note and photo legs.
import XCTest

extension ProvingTests {
    /// Reticulum/LXMF against a stock Python RNS node on the LAN (MESHSAT-1735, the twin of Android's 13 Oct
    /// proof). Unless MESHSAT_RNS_SETUP=0, the RNS TCP client is pointed at MESHSAT_RNS_HOST:MESHSAT_RNS_PORT
    /// and the app restarted (the gateway reads it at start). Then: the phone's LXMF address in the log,
    /// Announce now, a text to MESHSAT_LXMF_DEST by MESHSAT_LXMF_METHOD (Direct) that must reach the mark
    /// MESHSAT_LXMF_MARK (Delivered; "At the propagation node" for Propagated), and, with MESHSAT_LXMF_EXPECT
    /// set, up to three minutes for that text from the far end; MESHSAT_LXMF_SYNC=1 presses Sync now first.
    @MainActor
    func testLxmf() throws {
        try gate("lxmf")
        // Without a destination the run only points the TCP client somewhere (also how the owner's
        // rns.meshsat.net:443 with TLS is put back after a proof).
        let dest = env["MESHSAT_LXMF_DEST"]?.lowercased() ?? ""
        let method = env["MESHSAT_LXMF_METHOD"] ?? "Direct"
        let mark = env["MESHSAT_LXMF_MARK"] ?? (method == "Propagated" ? "At the propagation node" : "Delivered")
        let text = env["MESHSAT_TEXT"] ?? "iPhone to \(dest.prefix(8)) by Reticulum, \(method)"
        var app = attach()
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        if env["MESHSAT_RNS_SETUP"] != "0" {
            openTab(app, "Setup")
            tap(app, "Ham radio, TAK and Reticulum")
            // Host and Port share one row under the "Reticulum over TCP" heading (the APRS cards above
            // have Port fields of their own): both fields are taken from that row before any typing.
            // The row is looked up again before each field: typing scrolls the card under the keyboard.
            func tcpRow() throws -> [XCUIElement] {
                let hostLabel = try scrollToLabel(app, "Host")
                let row = app.textFields.allElementsBoundByIndex
                    .filter { $0.exists && abs($0.frame.midY - hostLabel.frame.midY) < 30 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(row.count, 2, "the Host and Port fields")
                return row
            }
            let before = try tcpRow()
            NSLog(
                "MeshSatProve: lxmf tcp before host=%@ port=%@", (before.first?.value as? String) ?? "",
                (before.last?.value as? String) ?? "")
            replaceText(app, try XCTUnwrap(before.first, "the Host field"), with: env["MESHSAT_RNS_HOST"] ?? "192.168.181.111")
            Thread.sleep(forTimeInterval: 1)
            replaceText(app, try XCTUnwrap(try tcpRow().last, "the Port field"), with: env["MESHSAT_RNS_PORT"] ?? "4242")
            app.swipeDown()  // the keyboard away
            let enable = try scrollToToggle(app, "Enable RNS TCP")
            if !isOn(enable) { enable.tap() }
            // The card has several Save buttons: the one right under the TLS switch.
            let tls = try scrollToToggle(app, "TLS")
            NSLog("MeshSatProve: lxmf tcp before tls=%@", (tls.value as? String) ?? "")
            let wantTls = env["MESHSAT_RNS_TLS"] == "1"
            if isOn(tls) != wantTls { tls.tap() }
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
        if dest.isEmpty {
            NSLog("MeshSatProve: lxmf tcp client set, nothing to send")
            return
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
        if env["MESHSAT_LXMF_ATTACH"] == "1" { try lxmfAttachments(app) }
        Thread.sleep(forTimeInterval: 5)
    }

    /// The voice note and photo legs (MESHSAT-1735): the far end's note and photo show and the note
    /// plays; then a 3 s note recorded here goes out and must reach Delivered.
    @MainActor
    func lxmfAttachments(_ app: XCUIApplication) throws {
        let play = app.buttons["Play the voice note"].firstMatch
        let gotNote = play.waitForExistence(timeout: 180)
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        NSLog("MeshSatProve: lxmf inbound note=%@ photo=%@", gotNote ? "yes" : "no", photo.exists ? "yes" : "no")
        XCTAssertTrue(gotNote, "the far end's voice note")
        XCTAssertTrue(photo.exists, "the far end's photo")
        play.tap()
        Thread.sleep(forTimeInterval: 1)
        NSLog("MeshSatProve: lxmf note playing=%@", app.buttons["Stop"].firstMatch.exists ? "yes" : "no")
        Thread.sleep(forTimeInterval: 3)
        // A note from here: hold the microphone 3 s. iOS asks for the microphone (and speech) the first time.
        let mic =
            app.otherElements["Hold to record a voice note"].exists
            ? app.otherElements["Hold to record a voice note"].firstMatch : app.buttons["Hold to record a voice note"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "the microphone")
        mic.press(forDuration: 0.5)
        for name in ["Allow", "OK"] {
            let b = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons[name]
            if b.waitForExistence(timeout: 4) {
                b.tap()
                NSLog("MeshSatProve: permission %@ tapped", name)
            }
        }
        mic.press(forDuration: 3.5)
        let chip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Voice note,'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the pending note")
        NSLog("MeshSatProve: lxmf pending %@", chip.label)
        try sendButton(app).tap()
        let delivered = app.images.matching(NSPredicate(format: "label == 'Delivered'")).count
        Thread.sleep(forTimeInterval: 30)
        let after = app.images.matching(NSPredicate(format: "label == 'Delivered'")).count
        NSLog("MeshSatProve: lxmf note delivered marks before=%d after=%d", delivered, after)
    }

    /// A static text by its exact label, scrolled on screen.
    @MainActor
    func scrollToLabel(_ app: XCUIApplication, _ label: String) throws -> XCUIElement {
        let text = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        var tries = 0
        var anchor: XCUIElement?
        while anchor == nil, tries < 8 {
            anchor = text.first { $0.exists && $0.isHittable }
            if anchor == nil {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.8)
                tries += 1
            }
        }
        return try XCTUnwrap(anchor, "the label '\(label)'")
    }

    /// The text field nearest a label drawn over it (the MSOutlinedTextField pattern), scrolled on screen.
    @MainActor
    func fieldNear(_ app: XCUIApplication, label: String) throws -> XCUIElement {
        let a = try scrollToLabel(app, label)
        let fields = app.textFields.allElementsBoundByIndex.filter { $0.exists }
        return try XCTUnwrap(fields.min { abs($0.frame.midY - a.frame.midY) < abs($1.frame.midY - a.frame.midY) }, "the field '\(label)'")
    }

    /// Types over whatever a field holds: the cursor goes to the end (a tap at the right edge), the
    /// old text is deleted key by key, then the value is typed. (A long press selected one word
    /// only: "reticulum.meshsat.net" became "reticulum.192.168.181.111.net" on 7 Nov 2026.)
    @MainActor
    func replaceText(_ app: XCUIApplication, _ field: XCUIElement, with value: String) {
        // Until the field has the keyboard: a tap during the keyboard's slide lands nowhere.
        var tries = 0
        repeat {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.8)
            tries += 1
        } while (field.value(forKey: "hasKeyboardFocus") as? Bool) != true && tries < 4
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(value)
    }

    /// A switch by its label, scrolled on screen (a toggle-trait control; older runners saw a button).
    @MainActor
    func scrollToToggle(_ app: XCUIApplication, _ name: String) throws -> XCUIElement {
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

    func isOn(_ toggle: XCUIElement) -> Bool { ["On", "1"].contains(toggle.value as? String ?? "") }

    /// The app's enabled Send button, never the keyboard's key of the same name.
    @MainActor
    func sendButton(_ app: XCUIApplication) throws -> XCUIElement {
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
