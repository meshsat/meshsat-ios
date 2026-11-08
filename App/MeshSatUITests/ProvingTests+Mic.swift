// A press on the voice-note microphone records only while the finger is down (MESHSAT-1846).
import XCTest

extension ProvingTests {
    /// In the chat with MESHSAT_LXMF_DEST: short presses leave no recording, a held one makes a note.
    /// Nothing is sent; the app is quit at the end, which drops the note and always ends a recording.
    @MainActor
    func testMicShortPress() throws {
        try gate("mic")
        let dest = try XCTUnwrap(env["MESHSAT_LXMF_DEST"]?.lowercased(), "MESHSAT_LXMF_DEST")
        let app = attach()
        defer { app.terminate() }
        openTab(app, "Messages")
        tap(app, "Reticulum")
        tap(app, "New message")
        let field = try fieldNear(app, label: "Or a Reticulum (LXMF) address, 32 hex")
        field.tap()
        field.typeText(dest)
        tap(app, "Message this address")
        Thread.sleep(forTimeInterval: 2)
        let name = "Hold to record a voice note"
        func mic() -> XCUIElement { app.otherElements[name].exists ? app.otherElements[name].firstMatch : app.buttons[name].firstMatch }
        func recording() -> Bool { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Recording,'")).firstMatch.exists }
        XCTAssertTrue(mic().waitForExistence(timeout: 10), "the microphone")
        for seconds in [0.05, 0.1, 0.2, 0.4, 0.8] {
            mic().press(forDuration: seconds)
            Thread.sleep(forTimeInterval: 2.5)
            NSLog("MeshSatProve: mic press %.2f s, still recording=%@", seconds, recording() ? "yes" : "no")
            XCTAssertFalse(recording(), "still recording after a \(seconds) s press")
        }
        mic().press(forDuration: 3.5)
        Thread.sleep(forTimeInterval: 1)
        let chip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Voice note,'")).firstMatch
        NSLog("MeshSatProve: mic held 3.5 s, still recording=%@, pending=%@", recording() ? "yes" : "no", chip.exists ? chip.label : "none")
        XCTAssertFalse(recording(), "still recording after the finger lifted")
        XCTAssertTrue(chip.exists, "the held note")
    }
}
