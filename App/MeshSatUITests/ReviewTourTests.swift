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
    private var nodeName: String { env["MESHSAT_NODE_NAME"] ?? "MeshSat" }

    @MainActor
    func testReviewDemo() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The demo is for the phone with the node.")
        #endif
        try XCTSkipUnless(env["MESHSAT_PROVE"] == "review", "MESHSAT_PROVE=review runs the demo")
        wakeAndUnlock()
        let app = XCUIApplication()
        if env["MESHSAT_FORGET"] != "0" {
            unpairInApp(app)
            forgetInSettings()
        }
        step("launch")
        app.launch()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 30))
        pause("home-unpaired")

        app.buttons["Setup"].firstMatch.tap()
        open(app, "Your MeshSat node")
        pause("node-page")
        pairWithNode(app)
        pause("node-connected")
        scrollAndPause(app, "node-connected-2")
        back(app)

        open(app, "Satellite")
        pause("satellite")
        scrollAndPause(app, "satellite-2")
        back(app)

        app.buttons["Home"].firstMatch.tap()
        pause("home-paired")
        scrollAndPause(app, "home-paired-2")

        sendMeshText(app)
        let replyWait = TimeInterval(env["MESHSAT_REPLY_WAIT"] ?? "") ?? 45
        step("mesh-reply-wait")
        Thread.sleep(forTimeInterval: replyWait)

        for tab in ["Map", "People"] {
            app.buttons[tab].firstMatch.tap()
            pause(tab)
        }

        app.buttons["Setup"].firstMatch.tap()
        open(app, "Advanced")
        open(app, "Node log")
        pause("node-log")
        Thread.sleep(forTimeInterval: 10)
        back(app)
        back(app)

        if env["MESHSAT_ALARM"] != "0" { alarmTest(app) }

        app.buttons["Home"].firstMatch.tap()
        pause("end")
    }

    // MARK: - the pairing

    /// Disconnect in the app forgets the saved node, so the fresh launch starts unpaired.
    @MainActor
    private func unpairInApp(_ app: XCUIApplication) {
        app.activate()
        guard app.buttons["Home"].waitForExistence(timeout: 15) else { return }
        openTab(app, "Setup")
        open(app, "Your MeshSat node")
        let disconnect = app.buttons["Disconnect"].firstMatch
        if disconnect.waitForExistence(timeout: 5) {
            step("disconnect")
            disconnect.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        back(app)
        openTab(app, "Home")
        app.terminate()
        Thread.sleep(forTimeInterval: 5)
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
        let info = settings.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'More Info' OR label CONTAINS[c] %@", nodeName))
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

    /// Scan, tap the node, answer iOS's pairing prompt with the PIN, wait for Connected.
    @MainActor
    private func pairWithNode(_ app: XCUIApplication) {
        step("scan")
        tap(app, "Continue", timeout: 3, required: false)
        tap(app, "Scan for Meshtastic devices", timeout: 10, required: false)
        let found = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", nodeName)).firstMatch
        let anyDevice = app.staticTexts["Found devices:"].firstMatch
        if !found.waitForExistence(timeout: 20) {
            XCTAssertTrue(anyDevice.waitForExistence(timeout: 10), "a device found")
        }
        Thread.sleep(forTimeInterval: 2)
        step("tap-node")
        if found.exists {
            found.tap()
        } else {
            // the first device row under "Found devices:"
            let rows = app.buttons.allElementsBoundByIndex.filter { $0.frame.minY > anyDevice.frame.maxY && $0.isHittable }
            rows.first?.tap()
        }
        answerPairingPrompt()
        let connected = app.staticTexts["Connected"].firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 60), "connected to the node")
        step("connected")
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

    // MARK: - helpers (as in TourTests and ProvingTests)

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
    private func back(_ app: XCUIApplication) {
        let backButton = app.buttons["Back"].firstMatch
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// The first on-screen, hittable element with this label (hidden tab stacks keep theirs).
    @MainActor
    private func tap(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 10, required: Bool = true) {
        let deadline = Date().addingTimeInterval(timeout)
        var candidate: XCUIElement?
        while Date() < deadline, candidate == nil {
            let pool =
                app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ","))
                .allElementsBoundByIndex + app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            let keyboard = app.keyboards.firstMatch
            let keyboardTop = keyboard.exists ? keyboard.frame.minY : .greatestFiniteMagnitude
            candidate = pool.first { $0.exists && $0.isHittable && $0.frame.maxY <= keyboardTop }
            if candidate == nil {
                if pool.contains(where: { $0.exists && $0.frame.minY > app.frame.height * 0.8 }) {
                    app.swipeUp()
                } else {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        guard let target = candidate else {
            if required { XCTFail("'\(label)' is not on screen") }
            return
        }
        target.tap()
    }
}
