import XCTest

// The App Review demo of 6 Oct 2026 (MESHSAT-1331, guideline 2.1): Apple wants a video of a
// physical iPhone and the MeshSat node pairing and working together. Driven over USB like the
// tour (pymobiledevice3 developer dvt xcuitest ... --env MESHSAT_PROVE=review) while the laptop's
// webcam films the desk and a frame loop records the screen. Steps, each logged as
// "MeshSatReview: <step>" so the frames can be labelled: forget the node in Settings (so the PIN
// prompt shows), launch the app, scan, pair with the node's PIN (MESHSAT_PIN), then the
// workflow with the node: Home, the node's own page, Satellite with the node's health, a text
// to the mesh and the answer, Map, People, the node's live log, the alarm test, back Home.
final class ReviewTourTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var dwell: TimeInterval { TimeInterval(env["MESHSAT_DWELL"] ?? "") ?? 4 }
    /// The node's Bluetooth name as iOS Settings shows it (the T-Beam Supreme node: FLNR_074c).
    private var nodeName: String { env["MESHSAT_NODE_NAME"] ?? "FLNR" }

    @MainActor
    func testReviewDemo() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The demo is for the phone with the node.")
        #endif
        try XCTSkipUnless(env["MESHSAT_PROVE"] == "review", "MESHSAT_PROVE=review runs the demo")
        wakeAndUnlock()
        let app = XCUIApplication()
        if env["MESHSAT_PREP_ONLY"] == "1" {
            prepare(app)
            return
        }
        if env["MESHSAT_FORGET"] != "0" { prepare(app) }
        step("launch")
        app.launch()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 30))
        pause("home-unpaired")

        app.buttons["Setup"].firstMatch.tap()
        tap(app, "Your MeshSat node")
        pause("node-page")
        pairWithNode(app)
        pause("node-connected")
        scrollAndPause(app, "node-connected-2")
        back(app)

        tap(app, "Satellite")
        pause("satellite")
        scrollAndPause(app, "satellite-2")
        back(app)

        app.buttons["Home"].firstMatch.tap()
        // Not scrolled: the bottom of Home carries the phone's own coordinates (the tester's home).
        pause("home-paired")

        sendMeshText(app)
        let replyWait = TimeInterval(env["MESHSAT_REPLY_WAIT"] ?? "") ?? 45
        step("mesh-reply-wait")
        Thread.sleep(forTimeInterval: replyWait)

        for tab in ["Map", "People"] {
            app.buttons[tab].firstMatch.tap()
            pause(tab)
        }

        app.buttons["Setup"].firstMatch.tap()
        tap(app, "Advanced")
        tap(app, "Node log")
        pause("node-log")
        Thread.sleep(forTimeInterval: 10)
        back(app)
        back(app)

        if env["MESHSAT_ALARM"] != "0" { alarmTest(app) }

        app.buttons["Home"].firstMatch.tap()
        pause("end")
    }

    // MARK: - the pairing

    /// Before the take: the app must start unpaired AND iOS must have no bond, so the scan, the
    /// tap and the PIN prompt all happen on camera. Disconnect in the app forgets the saved node
    /// (only offered while connected: a wedged "Connecting" link, as after an app upgrade with the
    /// link alive, is cleared by forgetting the node in Settings first and pairing again), then
    /// the app is quit and the bond is forgotten in Settings.
    @MainActor
    private func prepare(_ app: XCUIApplication) {
        step("prepare")
        app.activate()
        if !app.buttons["Home"].waitForExistence(timeout: 20) {
            app.launch()
            _ = app.buttons["Home"].waitForExistence(timeout: 30)
        }
        openTab(app, "Setup")
        tap(app, "Your MeshSat node")
        if !app.buttons["Disconnect"].firstMatch.waitForExistence(timeout: 8) {
            forgetInSettings()
            app.activate()
            _ = app.buttons["Home"].waitForExistence(timeout: 20)
            pairWithNode(app, required: false)
        }
        let disconnect = app.buttons["Disconnect"].firstMatch
        if disconnect.waitForExistence(timeout: 5), disconnect.isHittable {
            step("disconnect")
            disconnect.tap()
            Thread.sleep(forTimeInterval: 2)
        } else {
            NSLog("MeshSatReview: no Disconnect button; the saved node stays")
        }
        back(app)
        openTab(app, "Home")
        app.terminate()
        Thread.sleep(forTimeInterval: 5)
        forgetInSettings()
    }

    /// Settings > Bluetooth > (i) next to the node > Forget This Device, so iOS asks for the PIN
    /// again. Best effort: when a label is not found the demo goes on with the bond in place.
    @MainActor
    private func forgetInSettings() {
        step("settings-forget")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let bluetooth = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Bluetooth'")).firstMatch
        guard bluetooth.waitForExistence(timeout: 15) else { return NSLog("MeshSatReview: no Bluetooth row") }
        bluetooth.tap()
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", nodeName)).firstMatch
        guard row.waitForExistence(timeout: 15) else { return NSLog("MeshSatReview: node not in Bluetooth list") }
        let info = settings.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'More Info' OR label CONTAINS[c] 'Info' OR label CONTAINS[c] %@", nodeName)
        )
        .allElementsBoundByIndex.first {
            $0.exists && $0.isHittable && $0.frame.minY >= row.frame.minY - 20 && $0.frame.maxY <= row.frame.maxY + 20
        }
        guard let info else { return NSLog("MeshSatReview: no info button") }
        info.tap()
        let forget = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Forget'")).firstMatch
        guard forget.waitForExistence(timeout: 10) else { return NSLog("MeshSatReview: no Forget") }
        forget.tap()
        let confirm = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Forget'")).allElementsBoundByIndex.last {
            $0.exists && $0.isHittable
        }
        if let confirm, confirm.waitForExistence(timeout: 5) { confirm.tap() }
        Thread.sleep(forTimeInterval: 2)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
    }

    /// Scan, tap the node, answer iOS's pairing prompt with the PIN, wait for Connected. With
    /// `required` false (the preparation) a missing scan list is not a failure: the app may be
    /// reconnecting to its saved node by itself, and only the prompt and the wait matter.
    @MainActor
    private func pairWithNode(_ app: XCUIApplication, required: Bool = true) {
        step("scan")
        tap(app, "Continue", timeout: 3, required: false)
        tap(app, "Scan for Meshtastic devices", timeout: required ? 10 : 3, required: false)
        let found = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", nodeName)).firstMatch
        let anyDevice = app.staticTexts["Found devices:"].firstMatch
        if !found.waitForExistence(timeout: 20), required {
            XCTAssertTrue(anyDevice.waitForExistence(timeout: 10), "a device found")
        }
        Thread.sleep(forTimeInterval: 2)
        if found.exists {
            step("tap-node")
            found.tap()
        } else if anyDevice.exists {
            step("tap-node")
            let rows = app.buttons.allElementsBoundByIndex.filter { $0.frame.minY > anyDevice.frame.maxY && $0.isHittable }
            rows.first?.tap()
        }
        answerPairingPrompt()
        let connected = app.staticTexts["Connected"].firstMatch
        let isConnected = connected.waitForExistence(timeout: 60)
        if required { XCTAssertTrue(isConnected, "connected to the node") }
        step(isConnected ? "connected" : "not-connected")
    }

    /// iOS's "Bluetooth Pairing Request" belongs to SpringBoard: a text field for the code and a
    /// Pair button. On a phone that still holds the bond there is no prompt and nothing to do.
    @MainActor
    private func answerPairingPrompt() {
        guard let pin = env["MESHSAT_PIN"], !pin.isEmpty else { return }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let field = springboard.textFields.firstMatch.exists ? springboard.textFields.firstMatch : springboard.secureTextFields.firstMatch
        guard field.waitForExistence(timeout: 25) else { return NSLog("MeshSatReview: no pairing prompt") }
        step("pairing-prompt")
        Thread.sleep(forTimeInterval: 2)
        field.tap()
        field.typeText(pin)
        Thread.sleep(forTimeInterval: 1)
        let pair = springboard.buttons["Pair"].firstMatch
        if pair.waitForExistence(timeout: 5) { pair.tap() }
    }

    // MARK: - the workflow

    @MainActor
    private func sendMeshText(_ app: XCUIApplication) {
        step("mesh-text")
        let text = env["MESHSAT_TEXT"] ?? "Hello from the iPhone over the mesh"
        openTab(app, "Messages")
        tap(app, "New message")
        tap(app, "Everyone on the mesh")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer")
        field.tap()
        field.typeText(text)
        tap(app, "Send")
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "the bubble")
    }

    /// Setup > Safety's alarm test: the SOS flow without contacting anyone. A Messages composer
    /// per text contact is cancelled, never sent.
    @MainActor
    private func alarmTest(_ app: XCUIApplication) {
        step("alarm-test")
        openTab(app, "Home")
        tap(app, "Test the alarm")
        tap(app, "Send the test")
        for _ in 0..<3 {
            let cancel = app.buttons["Cancel"].firstMatch
            guard cancel.waitForExistence(timeout: 12) else { break }
            Thread.sleep(forTimeInterval: 2)
            cancel.tap()
            let delete = app.buttons["Delete Draft"].firstMatch
            if delete.waitForExistence(timeout: 4) { delete.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
        Thread.sleep(forTimeInterval: 15)
        if app.buttons["Stop test"].firstMatch.waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 4)
            app.buttons["Stop test"].firstMatch.tap()
        }
    }

    // MARK: - helpers (as in TourTests and ProvingTests; rows are tapped through tap(), which takes
    // only on-screen, hittable elements: the hidden tab stacks keep theirs in the tree, and in take
    // two of the demo a tap on Home's hidden "Satellite" lane landed on the SMS row of Setup)

    private func step(_ name: String) { NSLog("MeshSatReview: %@", name) }

    private func pause(_ name: String) {
        step(name)
        Thread.sleep(forTimeInterval: dwell)
    }

    @MainActor
    private func scrollAndPause(_ app: XCUIApplication, _ name: String) {
        app.swipeUp()
        step(name)
        Thread.sleep(forTimeInterval: 3)
    }

    @MainActor
    private func wakeAndUnlock() {
        let device = XCUIDevice.shared
        device.press(.home)
        Thread.sleep(forTimeInterval: 1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        bottom.press(forDuration: 0.1, thenDragTo: middle)
        Thread.sleep(forTimeInterval: 1)
        device.press(.home)
        Thread.sleep(forTimeInterval: 1)
    }

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

    /// The first on-screen, hittable element for this label. A Setup row (NavRow) is a Button
    /// whose accessibility label is its icon, title and detail joined, so buttons are matched by
    /// CONTAINS and ranked exact, prefix, contains; the hidden tab stacks keep their elements in
    /// the tree, which is why only hittable ones count (take two: Home's hidden "Satellite" lane
    /// took the tap meant for Setup's row). When nothing hittable carries the label, the text
    /// itself is taken, scrolled into view if needed (a row's inner text is not always hittable).
    @MainActor
    private func tap(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 10, required: Bool = true) {
        let deadline = Date().addingTimeInterval(timeout)
        var candidate: XCUIElement?
        while Date() < deadline, candidate == nil {
            let buttons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).allElementsBoundByIndex
            let texts = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            let keyboard = app.keyboards.firstMatch
            let keyboardTop = keyboard.exists ? keyboard.frame.minY : .greatestFiniteMagnitude
            let visible = (buttons + texts).filter { $0.exists && $0.isHittable && $0.frame.maxY <= keyboardTop }
            let rank: (XCUIElement) -> Int = { e in
                let l = e.label
                if l == label { return 0 }
                if l.hasPrefix(label) { return 1 }
                return 2
            }
            candidate = visible.min { rank($0) < rank($1) }
            if candidate == nil {
                if (buttons + texts).contains(where: { $0.exists && $0.frame.minY > app.frame.height * 0.8 }) {
                    app.swipeUp()
                } else {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        if candidate == nil {
            // The text of a row that is on screen but not reported hittable.
            let text = app.staticTexts[label].firstMatch
            if text.exists, text.frame.minY >= 0, text.frame.maxY <= app.frame.height {
                var tries = 0
                while !text.isHittable, tries < 3 {
                    app.swipeUp()
                    tries += 1
                }
                candidate = text
            }
        }
        guard let target = candidate else {
            if required { XCTFail("'\(label)' is not on screen") }
            return
        }
        target.tap()
    }
}
