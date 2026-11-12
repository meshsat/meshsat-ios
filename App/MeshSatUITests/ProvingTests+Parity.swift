// The phone checks of the Android parity work of 7 Nov 2026 (827ebc5), run on the iPhone on
// 12 Nov 2026: Setup's satellite row beside the node's 9704 (MESHSAT-1826), Stop test from the SOS
// notification (1830), the TAK switches applied on Save (1831), the welcome page of a fresh install
// (1834) and the small screens of the housekeeping issue (1836). Each answers to MESHSAT_PROVE.
import XCTest

extension ProvingTests {
    /// Every element whose label contains one of these words, for the log.
    @MainActor
    func labels(_ app: XCUIApplication, containing words: [String]) -> [String] {
        let predicate = NSCompoundPredicate(
            orPredicateWithSubpredicates: words.map { NSPredicate(format: "label CONTAINS[c] %@", $0) })
        return app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.filter { $0.exists }.map(\.label)
    }

    /// Setup's Satellite row with the node's 9704 up (MESHSAT-1826): it names the 9704 and never says
    /// "No modem on this radio". The 9704 needs up to two minutes after the node link comes up.
    @MainActor
    func testSatelliteRow() throws {
        try gate("satrow")
        let app = attach()
        openTab(app, "Setup")
        let ready = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "9704")).firstMatch
        let named = ready.waitForExistence(timeout: Double(env["MESHSAT_WAIT"] ?? "150") ?? 150)
        let words = ["9704", "No modem on this radio", "Connect your node first", "Modem ready", "modem does not answer"]
        let lines = labels(app, containing: words)
        NSLog("MeshSatProve: satellite row lines %@", lines.joined(separator: " | "))
        XCTAssertTrue(named, "the row names the 9704")
        XCTAssertFalse(lines.contains { $0.contains("No modem on this radio") }, "no 'No modem on this radio' beside the 9704")
        Thread.sleep(forTimeInterval: 4)  // the row, for the screenshot
        tap(app, "Satellite")
        Thread.sleep(forTimeInterval: 6)  // the satellite page beside it
        NSLog("MeshSatProve: satellite page lines %@", labels(app, containing: ["9704", "Connected"]).joined(separator: " | "))
        openTab(app, "Setup")
    }

    /// The alarm test stopped from its notification (MESHSAT-1830). The Messages composer an
    /// emergency contact opens is cancelled, never sent: a proof texts nobody.
    @MainActor
    func testSosStopFromNotification() throws {
        try gate("sosstop")
        let app = attach()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        openTab(app, "Home")
        tap(app, "Test the alarm")
        tap(app, "Send the test")
        for _ in 0..<3 {
            // The composer is the system's: its Send and Cancel. Cancel only.
            guard app.buttons["Send"].firstMatch.waitForExistence(timeout: 8) else { break }
            Thread.sleep(forTimeInterval: 2)
            let cancel = app.buttons["Cancel"].firstMatch
            guard cancel.exists else { break }
            cancel.tap()
            NSLog("MeshSatProve: sosstop composer cancelled")
            Thread.sleep(forTimeInterval: 2)
        }
        let stopOnCard = app.buttons["Stop test"].firstMatch
        XCTAssertTrue(stopOnCard.waitForExistence(timeout: 20), "the test runs (Stop test on the card)")
        Thread.sleep(forTimeInterval: 4)  // the notification is posted with the routes' first state
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        // Notification Centre: a swipe down from the top left edge.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.003))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75)))
        Thread.sleep(forTimeInterval: 2)
        let cell = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Alarm test running")).firstMatch
        let found = cell.waitForExistence(timeout: 10)
        NSLog("MeshSatProve: sosstop notification %@", found ? cell.label : "not found")
        guard found else {
            NSLog("MeshSatProve: springboard %@", String(springboard.debugDescription.prefix(3000)))
            return XCTFail("the alarm test's notification in Notification Centre")
        }
        Thread.sleep(forTimeInterval: 2)  // the notification, for the screenshot
        cell.press(forDuration: 1.5)
        var stop = springboard.buttons["Stop test"].firstMatch
        if !stop.waitForExistence(timeout: 5) {
            // A stack of MeshSat notifications opens on a tap first.
            cell.tap()
            Thread.sleep(forTimeInterval: 1.5)
            cell.press(forDuration: 1.5)
            stop = springboard.buttons["Stop test"].firstMatch
        }
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop test on the notification")
        Thread.sleep(forTimeInterval: 2)  // the action, for the screenshot
        stop.tap()
        NSLog("MeshSatProve: sosstop action tapped")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app opens on the action")
        openTab(app, "Home")
        let gone = app.buttons["Stop test"].firstMatch.waitForNonExistence(timeout: 20)
        NSLog("MeshSatProve: sosstop test stopped=%@", gone ? "yes" : "no")
        XCTAssertTrue(gone, "the test is stopped (no Stop test on the card)")
        Thread.sleep(forTimeInterval: 8)  // the card after, for the screenshot
    }

    /// Setup > Ham radio, TAK and Reticulum > TAK: Enable TAK and MQTT Export to Hub set as
    /// MESHSAT_TAK (on/off) and Saved, with no restart (MESHSAT-1831: they apply on Save), then the
    /// phone held still for MESHSAT_HOLD seconds while the Hub counts the positions.
    @MainActor
    func testTakSwitches() throws {
        try gate("tak")
        let want = (env["MESHSAT_TAK"] ?? "on") == "on"
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Ham radio, TAK and Reticulum")
        let enable = try scrollToToggle(app, "Enable TAK")
        NSLog("MeshSatProve: tak before enable=%@", (enable.value as? String) ?? "?")
        if isOn(enable) != want { enable.tap() }
        let export = try scrollToToggle(app, "MQTT Export to Hub")
        NSLog("MeshSatProve: tak before export=%@", (export.value as? String) ?? "?")
        if isOn(export) != want { export.tap() }
        Thread.sleep(forTimeInterval: 1)
        // The TAK card's Save: the first one under the export switch.
        let save = try XCTUnwrap(
            app.buttons.matching(NSPredicate(format: "label == %@", "Save")).allElementsBoundByIndex
                .filter { $0.exists && $0.frame.minY > export.frame.minY }.min { $0.frame.minY < $1.frame.minY }, "the TAK Save")
        save.tap()
        let toast = app.staticTexts["TAK settings saved"].firstMatch.waitForExistence(timeout: 5)
        NSLog(
            "MeshSatProve: tak saved toast=%@ enable=%@ export=%@ at %@", toast ? "yes" : "no", (enable.value as? String) ?? "?",
            (export.value as? String) ?? "?", ISO8601DateFormatter().string(from: Date()))
        XCTAssertEqual(isOn(enable), want)
        XCTAssertEqual(isOn(export), want)
        Thread.sleep(forTimeInterval: Double(env["MESHSAT_HOLD"] ?? "10") ?? 10)
        openTab(app, "Setup")
    }

    /// The welcome page of a fresh install (MESHSAT-1834): it explains location and notifications,
    /// Continue lets iOS ask both (allowed here), and the next start shows no welcome.
    @MainActor
    func testWelcome() throws {
        try gate("welcome")
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.activate()
        let heading = app.staticTexts["What the app asks for, and why"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "the welcome page")
        let rows = ["Bluetooth", "Location", "Notifications"].map { "\($0)=\(app.staticTexts[$0].firstMatch.exists ? "yes" : "no")" }
        NSLog("MeshSatProve: welcome shown %@", rows.joined(separator: " "))
        Thread.sleep(forTimeInterval: 5)  // the page, for the screenshot
        tap(app, "Continue")
        // iOS's questions, in the order it shows them: location (while using) and notifications.
        var answered: [String] = []
        for _ in 0..<4 {
            let choices = ["Allow While Using App", "Allow"]
            guard let button = choices.lazy.map({ springboard.buttons[$0].firstMatch }).first(where: { $0.waitForExistence(timeout: 8) })
            else { break }
            Thread.sleep(forTimeInterval: 2)  // the question, for the screenshot
            answered.append(button.label)
            button.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        NSLog("MeshSatProve: welcome questions answered %@", answered.joined(separator: ", "))
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20), "the app after the welcome")
        app.terminate()
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 30), "the app again")
        let again = app.staticTexts["What the app asks for, and why"].firstMatch.exists
        NSLog("MeshSatProve: welcome on the second start=%@", again ? "yes" : "no")
        XCTAssertFalse(again, "no welcome on the second start")
        Thread.sleep(forTimeInterval: 5)
    }

    /// A public warning relayed by a kit, on screen (MESHSAT-1819): its full-screen card read out,
    /// then All warnings, the list it went into.
    @MainActor
    func testWarningScreen() throws {
        try gate("warnscreen")
        let app = XCUIApplication()
        app.activate()
        let all = app.buttons["All warnings"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 20), "a warning on screen")
        let card = labels(app, containing: ["WARNING", "UPDATE", "Relay of", "Heard"])
        NSLog("MeshSatProve: warnscreen card %@", card.joined(separator: " | "))
        Thread.sleep(forTimeInterval: 5)  // the full screen, for the screenshot
        all.tap()
        Thread.sleep(forTimeInterval: 4)
        let list = labels(app, containing: ["Wind", "WARNING", "UPDATE", "No warning"])
        NSLog("MeshSatProve: warnscreen list %@", list.joined(separator: " | "))
        app.swipeUp()
        Thread.sleep(forTimeInterval: 5)  // the list, for the screenshot
        openTab(app, "Home")
    }

    /// The screens of the housekeeping issue (MESHSAT-1836): no Auto-decrypt switch under
    /// Messaging, the Hub's connection test line, the Configuration card under Diagnostics.
    @MainActor
    func testParityHousekeeping() throws {
        try gate("housekeeping")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Messaging")
        Thread.sleep(forTimeInterval: 4)
        let decrypt = labels(app, containing: ["Auto-decrypt"])
        NSLog("MeshSatProve: housekeeping auto-decrypt %@", decrypt.isEmpty ? "absent" : decrypt.joined(separator: " | "))
        XCTAssertTrue(decrypt.isEmpty, "no Auto-decrypt switch")
        openTab(app, "Setup")
        tap(app, "Hub")
        tap(app, "Test the connection")
        Thread.sleep(forTimeInterval: 8)
        let hubLines = labels(app, containing: ["ms", "Failed", "Not connected"]).suffix(4)
        NSLog("MeshSatProve: housekeeping hub test %@", hubLines.joined(separator: " | "))
        openTab(app, "Setup")
        tap(app, "Advanced")
        tap(app, "Diagnostics")
        let card = try scrollToLabel(app, "Configuration")
        NSLog("MeshSatProve: housekeeping configuration card %@", card.exists ? "shown" : "absent")
        for b in ["Copy JSON", "Copy YAML", "Import from the clipboard"] {
            NSLog("MeshSatProve: housekeeping button %@ %@", b, app.buttons[b].firstMatch.exists ? "present" : "absent")
        }
        app.swipeUp()
        Thread.sleep(forTimeInterval: 5)  // the card, for the screenshot
        openTab(app, "Setup")
    }
}
