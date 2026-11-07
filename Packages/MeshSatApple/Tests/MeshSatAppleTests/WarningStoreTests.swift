// Mirrors androidTest WarningRoomTest.kt (MESHSAT-1734, iOS MESHSAT-1819): the intake on the app's real
// database (GRDB schema v4, the warnings table): one alarm for the kit's two copies, a cancel that
// clears its event and is kept as the all-clear, the banner query, and the 30-day prune.
import Foundation
import MeshSatEngine
import XCTest

@testable import MeshSatStore

final class WarningStoreTests: XCTestCase {
    private let label = "Relay of KNMI via MeteoAlarm warning, issued 28 Oct 10:11 UTC via MeshSat, not an official NL-Alert"

    func testTheIntakeOnSQLite() async throws {
        let db = try AppDatabase.inMemory()
        let store = db.warnings
        let start: Int64 = 1_792_400_000_000
        let intake = WarningIntake(store: store, now: { start })
        let wind = "WARNING Wind Moderate until 10:11 UTC: Kans op windstoten\n\(label)"

        guard case .alarm(let w) = try await intake.onMesh(sender: "!4370c1d8", senderName: "tesseract", port: 11, raw: wind + "\u{07}")
        else { return XCTFail("no alarm") }
        XCTAssertGreaterThan(w.id, 0)
        let dup = try await intake.onMesh(sender: "!4370c1d8", senderName: "tesseract", port: 1, raw: wind)
        XCTAssertEqual(dup, .duplicate)
        let banner = try await store.unacknowledged()
        XCTAssertEqual(banner?.id, w.id)
        XCTAssertEqual(banner?.senderName, "tesseract")
        XCTAssertEqual(banner?.until, "10:11")

        let later = WarningIntake(store: store, now: { start + 60_000 })
        guard
            case .cleared(let cancel, let cleared) = try await later.onMesh(
                sender: "!1", senderName: "", port: 11, raw: "CANCELLED: Wind\n\(label)")
        else { return XCTFail("no cancel") }
        XCTAssertEqual(cleared.map(\.id), [w.id])
        XCTAssertEqual(cancel.acknowledgedAt, start + 60_000)
        let gone = try await store.byId(w.id)
        XCTAssertEqual(gone?.cancelledAt, start + 60_000)
        let none = try await store.unacknowledged()
        XCTAssertNil(none)
        let all = try await store.recent(limit: 10)
        XCTAssertEqual(all.map(\.kind), ["cancel", "alert"])

        let pruned = try await store.deleteOlderThan(start + 1)
        XCTAssertEqual(pruned, 1)
        let left = try await store.recent(limit: 10)
        XCTAssertEqual(left.map(\.id), [cancel.id])
    }
}
