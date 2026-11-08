// The background gateway proof of ProvingTests (MESHSAT-1506), also the walk of App Review's screen recording of
// persistent background location: the keep-running switch on, location allowed Always (iOS's question, or iOS
// Settings when the question was used up), the app sent to the background for MESHSAT_BG_SECONDS while the laptop
// plays a route on the phone (pymobiledevice3 developer dvt simulate-location play), then the Map, where the
// phone's track drawn while the app was off screen shows.
import XCTest

extension ProvingTests {
    @MainActor
    func testBackgroundGateway() throws {
        try gate("background")
        let app = attach()
        openTab(app, "Setup")
        tap(app, "Advanced")
        tap(app, "Diagnostics")
        let name = "Keep the gateway running in the background"
        let toggle = try scrollToToggle(app, name)
        Thread.sleep(forTimeInterval: 3)  // the switch before, for the recording
        if !isOn(toggle) { toggle.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let upgrade = springboard.buttons["Change to Always Allow"]
        if upgrade.waitForExistence(timeout: 5) {
            upgrade.tap()
            NSLog("MeshSatProve: background location upgraded to Always by iOS's question")
        }
        Thread.sleep(forTimeInterval: 2)
        let openSettings = app.buttons["Open Settings"].firstMatch
        if openSettings.exists {
            openSettings.tap()
            try allowLocationAlwaysInSettings()
            app.activate()
            Thread.sleep(forTimeInterval: 3)
        }
        XCTAssertFalse(app.buttons["Open Settings"].firstMatch.exists, "location is allowed Always")
        NSLog("MeshSatProve: background switch %@", (toggle.value as? String) ?? "?")
        Thread.sleep(forTimeInterval: 3)

        let seconds = Double(env["MESHSAT_BG_SECONDS"] ?? "") ?? 90
        NSLog("MeshSatProve: background for %.0f s", seconds)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: seconds)
        app.activate()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20), "the app again")
        openTab(app, "Map")
        Thread.sleep(forTimeInterval: 10)  // the track, for the recording
        NSLog("MeshSatProve: background walk done")
    }

    /// iOS Settings opened on MeshSat's page: Location, then Always.
    @MainActor
    private func allowLocationAlwaysInSettings() throws {
        let prefs = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(prefs.wait(for: .runningForeground, timeout: 10), "iOS Settings")
        let location = prefs.staticTexts["Location"].firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 10), "Location in MeshSat's settings")
        location.tap()
        let always = prefs.staticTexts["Always"].firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 10), "Always")
        always.tap()
        Thread.sleep(forTimeInterval: 2)
        NSLog("MeshSatProve: background location set to Always in iOS Settings")
    }
}
