// The photo leg of the Reticulum proof (MESHSAT-1841): the test draws a plain card, saves it to
// Photos, picks it in the chat and sends it. It runs only on a library holding that one image, so
// the test can never send somebody's own picture.
import UIKit
import XCTest

extension ProvingTests {
    /// In an open LXMF chat: saves the image (MESHSAT_PHOTO_SAVE=0 reuses the one a run left), picks it,
    /// sends it. MESHSAT_PHOTO_CLEAN=1 then deletes it from Photos (it stays in Recently Deleted).
    @MainActor
    func lxmfSendPhoto(_ app: XCUIApplication) throws {
        if env["MESHSAT_PHOTO_SAVE"] != "0" { try saveTestImage() }
        app.activate()
        Thread.sleep(forTimeInterval: 2)
        let add = app.buttons["Add a photo"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the photo button")
        add.tap()
        let picture = try onlyPicture(in: app)
        picture.tap()
        let chip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "the pending photo")
        NSLog("MeshSatProve: lxmf pending %@", chip.label)
        try sendButton(app).tap()
        Thread.sleep(forTimeInterval: 30)
        NSLog("MeshSatProve: lxmf photo sent, delivered marks %d", app.images.matching(NSPredicate(format: "label == 'Delivered'")).count)
        if env["MESHSAT_PHOTO_CLEAN"] == "1" { deleteTestPhoto() }
    }

    /// Draws a plain card and saves it to Photos; iOS asks once for add-only access.
    @MainActor
    func saveTestImage() throws {
        let size = CGSize(width: 1200, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 150, y: 150, width: 500, height: 300))
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 8) {
            NSLog("MeshSatProve: lxmf photos access by '%@'", allow.label)
            allow.tap()
        }
        Thread.sleep(forTimeInterval: 4)
    }

    /// The single picture on offer, once the picker has loaded (it took over 4 s on 8 Nov 2026); fails,
    /// and picks nothing, when the library holds any other. The chat's own photos are labelled with their size.
    @MainActor
    func onlyPicture(in app: XCUIApplication) throws -> XCUIElement {
        let notChat = NSPredicate(format: "NOT (label MATCHES '^Photo, [0-9.,]+ [KM]?B$')")
        let labelled = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "label BEGINSWITH 'Photo,'"), notChat])
        func offered() -> (cells: [XCUIElement], others: [XCUIElement]) {
            let cells = app.images.matching(labelled).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            let scrolled = app.scrollViews.otherElements.images.matching(notChat)
            let others = scrolled.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            return (cells, others)
        }
        let deadline = Date().addingTimeInterval(40)
        var found = offered()
        while found.cells.isEmpty, found.others.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            found = offered()
        }
        Thread.sleep(forTimeInterval: 3)  // a library still filling would show more now
        found = offered()
        let pool = found.cells.isEmpty ? found.others : found.cells
        NSLog("MeshSatProve: lxmf picker offers %d (labelled %d, other %d)", pool.count, found.cells.count, found.others.count)
        if pool.isEmpty { logTree(app, "picker") }
        XCTAssertEqual(pool.count, 1, "the library must hold only the test image")
        return try XCTUnwrap(pool.first, "a picture in the picker")
    }

    /// Deletes the test image, only when Photos itself says the library is that one picture, then
    /// comes back to MeshSat.
    @MainActor
    func deleteTestPhoto() {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        defer { XCUIApplication().activate() }
        photos.activate()
        Thread.sleep(forTimeInterval: 5)
        let onlyOne = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'Library, 1 Photo'")).firstMatch
        guard onlyOne.waitForExistence(timeout: 10) else { return NSLog("MeshSatProve: lxmf photo left, library is not one photo") }
        let pool = (photos.images.allElementsBoundByIndex + photos.cells.allElementsBoundByIndex).filter {
            $0.exists && $0.isHittable && $0.frame.width > 60 && $0.frame.height > 60
        }
        NSLog("MeshSatProve: lxmf Photos offers %@", pool.map { "\($0.elementType.rawValue)'\($0.label)'" }.joined(separator: " | "))
        guard let cell = pool.first else { return NSLog("MeshSatProve: lxmf photo left, no cell") }
        cell.tap()
        Thread.sleep(forTimeInterval: 2)
        let named = NSPredicate(format: "label BEGINSWITH 'Delete' OR label BEGINSWITH 'Trash' OR identifier == 'trash'")
        let delete = photos.buttons.matching(named).firstMatch
        guard delete.waitForExistence(timeout: 5) else { return NSLog("MeshSatProve: lxmf no Delete button") }
        delete.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let confirm = photos.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).allElementsBoundByIndex.last
        if let confirm, confirm.exists { confirm.tap() }
        NSLog("MeshSatProve: lxmf test photo deleted")
        Thread.sleep(forTimeInterval: 2)
    }

    /// The element tree in pieces the system log keeps whole, with MESHSAT_PHOTO_TREE=1.
    @MainActor
    func logTree(_ app: XCUIApplication, _ tag: String) {
        guard env["MESHSAT_PHOTO_TREE"] == "1" else { return }
        var rest = Substring(app.debugDescription)
        var part = 0
        while !rest.isEmpty {
            NSLog("MeshSatProve: tree %@ %d %@", tag, part, String(rest.prefix(800)))
            rest = rest.dropFirst(800)
            part += 1
        }
    }
}
