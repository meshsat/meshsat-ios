// Mirrors WarningTextTest.kt and WarningIntakeTest.kt (MESHSAT-1734, iOS MESHSAT-1819). The vectors
// are the Bridge's own (`internal/warnings/relay_test.go`): what `MeshText` writes for an alert, an
// update, a cancel and a test, on port 11 with the BEL and as a plain text. The intake runs on an
// in-memory copy of the warnings table.
import Foundation
import MeshSatEngine
import XCTest

final class WarningTextTests: XCTestCase {
    private let label = "Relay of KNMI via MeteoAlarm warning, issued 28 Oct 10:11 UTC via MeshSat, not an official NL-Alert"
    private var alert: String { "WARNING Wind Moderate until 10:11 UTC: Kans op windstoten tot 90 km/u\n\(label)" }

    func testTheKitsAlertOnPort11ParsesBelDropped() throws {
        let p = try XCTUnwrap(WarningText.recognise(alert + "\u{07}", port: WarningText.portAlert))
        XCTAssertEqual(p.kind, .alert)
        XCTAssertFalse(p.test)
        XCTAssertEqual(p.event, "Wind")
        XCTAssertEqual(p.severity, "Moderate")
        XCTAssertEqual(p.until, "10:11")
        XCTAssertEqual(p.text, "Kans op windstoten tot 90 km/u")
        XCTAssertEqual(p.label, label)
        XCTAssertEqual(p.headline, "WARNING Wind Moderate until 10:11 UTC: Kans op windstoten tot 90 km/u")
    }

    func testTheSameWordsAsAPlainTextAreTheWarningNotAChat() throws {
        let p = try XCTUnwrap(WarningText.recognise(alert, port: WarningText.portText))
        XCTAssertEqual(p.event, "Wind")
        XCTAssertTrue(WarningText.isRelayedText(alert))
    }

    func testAChatThatStartsWithWarningButHasNoRelayLineStaysAChat() {
        XCTAssertNil(WarningText.recognise("WARNING Wind Severe: the tent is gone", port: WarningText.portText))
        XCTAssertNil(WarningText.recognise("WARNING Wind Severe: the tent is gone\nsee you at the car", port: WarningText.portText))
        XCTAssertFalse(WarningText.isRelayedText("warning, the tent is gone"))
        XCTAssertNil(WarningText.recognise("hello", port: WarningText.portText))
    }

    func testAnUpdateAndACancelParseToTheirKinds() throws {
        let u = try XCTUnwrap(WarningText.parse("UPDATE: WARNING Wind Severe until 12:00 UTC: Windstoten tot 110 km/u\n\(label)"))
        XCTAssertEqual(u.kind, .update)
        XCTAssertEqual(u.severity, "Severe")
        XCTAssertEqual(u.until, "12:00")
        let c = try XCTUnwrap(WarningText.parse("CANCELLED: Wind\n\(label)"))
        XCTAssertEqual(c.kind, .cancel)
        XCTAssertEqual(c.event, "Wind")
        XCTAssertEqual(c.severity, "")
        XCTAssertEqual(c.text, "")
        let ct = try XCTUnwrap(WarningText.parse("CANCELLED: Wind - Het waait niet meer\n\(label)"))
        XCTAssertEqual(ct.event, "Wind")
        XCTAssertEqual(ct.text, "Het waait niet meer")
    }

    func testATestWarningIsMarkedAsOne() throws {
        let testLine = "Relay of MeshSat test warning, issued 28 Oct 10:11 UTC via MeshSat, not an official NL-Alert"
        let t = try XCTUnwrap(WarningText.parse("TEST WARNING Wind Minor until 10:11 UTC: proef\n\(testLine)"))
        XCTAssertTrue(t.test)
        XCTAssertEqual(t.kind, .alert)
        XCTAssertEqual(t.event, "Wind")
        let tc = try XCTUnwrap(WarningText.parse("TEST CANCELLED: Wind\n\(label)"))
        XCTAssertTrue(tc.test)
        XCTAssertEqual(tc.kind, .cancel)
        XCTAssertEqual(WarningText.kindLabel(.alert, test: true), "TEST WARNING")
        XCTAssertEqual(WarningText.kindLabel(.cancel, test: false), "CANCELLED")
    }

    func testNoExpiryAndNoTextStillParseAndAOneWordEventWithASlash() throws {
        let p = try XCTUnwrap(WarningText.parse("WARNING Snow/ice Severe\n\(label)"))
        XCTAssertEqual(p.event, "Snow/ice")
        XCTAssertEqual(p.severity, "Severe")
        XCTAssertEqual(p.until, "")
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(WarningText.summary(event: p.event, severity: p.severity, until: p.until), "Snow/ice Severe")
        XCTAssertEqual(WarningText.summary(event: "Wind", severity: "Moderate", until: "10:11"), "Wind Moderate until 10:11 UTC")
    }

    func testAFirstLineCutByTheKitStillGivesTheEventAndTheSeverity() throws {
        let p = try XCTUnwrap(WarningText.parse("WARNING Wind Severe until 10:1\n\(label)"))
        XCTAssertEqual(p.event, "Wind")
        XCTAssertEqual(p.severity, "Severe")
        XCTAssertEqual(p.until, "")
        let q = try XCTUnwrap(WarningText.parse("WARNING Wind Severe until 10:11 UTC: Windstoten tot 1\n\(label)"))
        XCTAssertEqual(q.text, "Windstoten tot 1")
    }

    func testAnUnknownSeverityIsNotTakenForOne() throws {
        let p = try XCTUnwrap(WarningText.parse("WARNING Wind Huge until 10:11 UTC: x\n\(label)"))
        XCTAssertEqual(p.event, "Wind")
        XCTAssertEqual(p.severity, "")
        // Without a severity the expiry still reads.
        XCTAssertEqual(try XCTUnwrap(WarningText.parse("WARNING Wind until 10:11 UTC\n\(label)")).until, "10:11")
    }

    func testAnAlertOfAnotherShapeOnPort11IsStillAnAlertKeptWhole() throws {
        let p = try XCTUnwrap(WarningText.recognise("Shelter now\u{07}", port: WarningText.portAlert))
        XCTAssertEqual(p.event, "Alert")
        XCTAssertEqual(p.text, "Shelter now")
        XCTAssertEqual(p.label, "")
        XCTAssertNil(WarningText.recognise("\u{07}", port: WarningText.portAlert))
        XCTAssertNil(WarningText.recognise(alert, port: 3))
    }

    func testTheDedupKeyFoldsWhitespaceAndTheBelSoBothCopiesAreOne() {
        XCTAssertEqual(WarningText.dedupKey(alert), WarningText.dedupKey(alert + "\u{07}"))
        XCTAssertEqual(WarningText.dedupKey(alert), WarningText.dedupKey(alert.replacingOccurrences(of: "\n", with: "  \n ")))
        XCTAssertNotEqual(WarningText.dedupKey(alert), WarningText.dedupKey(alert.replacingOccurrences(of: "Moderate", with: "Severe")))
    }
}

final class WarningIntakeTests: XCTestCase {
    /// The store as a list: what the GRDB store does for the same queries.
    final class MemoryStore: WarningStore, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var rows: [WarningRecord] = []
        private var nextId: Int64 = 1

        private func locked<T>(_ f: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return f()
        }

        func insert(_ w: WarningRecord) async throws -> Int64 {
            locked {
                var r = w
                r.id = nextId
                nextId += 1
                rows.append(r)
                return r.id
            }
        }
        func countRecent(key: String, since: Int64) async throws -> Int {
            locked { rows.filter { $0.dedupKey == key && $0.receivedAt >= since }.count }
        }
        func standingOf(event: String, test: Bool) async throws -> [WarningRecord] {
            locked {
                rows.filter { !$0.isCancel && $0.event == event && $0.test == test && $0.cancelledAt == 0 && $0.replacedAt == 0 }
                    .sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
            }
        }
        func markReplaced(_ ids: [Int64], at: Int64) async throws { update(ids) { $0.replacedAt = at } }
        func markCancelled(_ ids: [Int64], at: Int64) async throws { update(ids) { $0.cancelledAt = at } }
        func acknowledge(_ id: Int64, at: Int64) async throws { update([id]) { if $0.acknowledgedAt == 0 { $0.acknowledgedAt = at } } }
        func byId(_ id: Int64) async throws -> WarningRecord? { locked { rows.first { $0.id == id } } }
        func recent(limit: Int) async throws -> [WarningRecord] {
            locked { Array(rows.sorted { ($0.receivedAt, $0.id) > ($1.receivedAt, $1.id) }.prefix(limit)) }
        }
        func unacknowledged() async throws -> WarningRecord? {
            locked { rows.filter { $0.standing && $0.acknowledgedAt == 0 }.max { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) } }
        }
        func deleteOlderThan(_ before: Int64) async throws -> Int {
            locked {
                let n = rows.filter { $0.receivedAt < before }.count
                rows.removeAll { $0.receivedAt < before }
                return n
            }
        }
        var count: Int { locked { rows.count } }
        private func update(_ ids: [Int64], _ f: (inout WarningRecord) -> Void) {
            locked {
                for i in rows.indices where ids.contains(rows[i].id) { f(&rows[i]) }
            }
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Int64 = 1_000_000
        var now: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return t
        }
        func advance(_ ms: Int64) {
            lock.lock()
            t += ms
            lock.unlock()
        }
    }

    private let label = "Relay of KNMI via MeteoAlarm warning, issued 28 Oct 10:11 UTC via MeshSat, not an official NL-Alert"
    private let testLabel = "Relay of MeshSat test warning, issued 28 Oct 10:11 UTC via MeshSat, not an official NL-Alert"
    private var wind: String { "WARNING Wind Moderate until 10:11 UTC: Kans op windstoten tot 90 km/u\n\(label)" }
    private var windUpdate: String { "UPDATE: WARNING Wind Severe until 12:00 UTC: Windstoten tot 110 km/u\n\(label)" }
    private var rain: String { "WARNING Rain Severe until 14:00 UTC: Veel regen\n\(label)" }
    private var cancelWind: String { "CANCELLED: Wind\n\(label)" }

    private let store = MemoryStore()
    private let clock = Clock()
    private var intake: WarningIntake { WarningIntake(store: store, now: { [clock] in clock.now }) }

    private struct NotThatOutcome: Error {}

    private func alarmed(sender: String, senderName: String, port: Int, raw: String, line: UInt = #line) async throws -> WarningRecord {
        let o = try await intake.onMesh(sender: sender, senderName: senderName, port: port, raw: raw)
        guard case .alarm(let w) = o else {
            XCTFail("expected an alarm, got \(o)", line: line)
            throw NotThatOutcome()
        }
        return w
    }

    private func clearedBy(
        sender: String, senderName: String, port: Int, raw: String, line: UInt = #line
    ) async throws -> (WarningRecord, [WarningRecord]) {
        let o = try await intake.onMesh(sender: sender, senderName: senderName, port: port, raw: raw)
        guard case .cleared(let c, let list) = o else {
            XCTFail("expected a cancel, got \(o)", line: line)
            throw NotThatOutcome()
        }
        return (c, list)
    }

    func testTheKitsPort11CopyAlarmsAndItsTextCopyIsTheSameWarning() async throws {
        let w = try await alarmed(sender: "!4370c1d8", senderName: "tesseract", port: 11, raw: wind + "\u{07}")
        XCTAssertEqual(w.event, "Wind")
        XCTAssertEqual(w.severity, "Moderate")
        XCTAssertEqual(w.until, "10:11")
        XCTAssertEqual(w.port, 11)
        XCTAssertEqual(w.sender, "!4370c1d8")
        XCTAssertEqual(w.senderName, "tesseract")
        XCTAssertEqual(w.kind, WarningRecord.kindAlert)
        XCTAssertTrue(w.standing)
        clock.advance(2_000)
        let text = try await intake.onMesh(sender: "!4370c1d8", senderName: "tesseract", port: 1, raw: wind)
        XCTAssertEqual(text, .duplicate)
        // The other kit in range relays the same digest: still the same warning.
        let other = try await intake.onMesh(sender: "!de11f199", senderName: "parallax", port: 11, raw: wind + "\u{07}")
        XCTAssertEqual(other, .duplicate)
        XCTAssertEqual(store.count, 1)
        // After the window the same words are heard as new.
        clock.advance(WarningIntake.dedupMs)
        _ = try await alarmed(sender: "!4370c1d8", senderName: "tesseract", port: 11, raw: wind)
        XCTAssertEqual(store.count, 2)
    }

    func testAnOrdinaryTextIsNotAWarning() async throws {
        let a = try await intake.onMesh(sender: "!4370c1d8", senderName: "", port: 1, raw: "WARNING Wind Severe: the tent is gone")
        XCTAssertEqual(a, .notAWarning)
        let b = try await intake.onMesh(sender: "!4370c1d8", senderName: "", port: 1, raw: "hello")
        XCTAssertEqual(b, .notAWarning)
        XCTAssertEqual(store.count, 0)
    }

    func testAnUpdateReplacesTheStandingWarningOfItsEventAndLeavesAnotherEventAlone() async throws {
        let first = try await alarmed(sender: "!1", senderName: "", port: 11, raw: wind)
        clock.advance(1_000)
        let other = try await alarmed(sender: "!1", senderName: "", port: 11, raw: rain)
        clock.advance(1_000)
        let second = try await alarmed(sender: "!1", senderName: "", port: 11, raw: windUpdate)
        XCTAssertEqual(second.kind, WarningRecord.kindUpdate)
        let firstNow = try await store.byId(first.id)
        XCTAssertEqual(firstNow?.replacedAt, clock.now)
        let otherNow = try await store.byId(other.id)
        XCTAssertEqual(otherNow?.replacedAt, 0)
        let windStanding = try await store.standingOf(event: "Wind", test: false).map(\.id)
        XCTAssertEqual(windStanding, [second.id])
        let rainStanding = try await store.standingOf(event: "Rain", test: false).map(\.id)
        XCTAssertEqual(rainStanding, [other.id])
    }

    func testACancelClearsTheStandingWarningsOfItsEventAndIsKeptAsTheAllClear() async throws {
        let w = try await alarmed(sender: "!1", senderName: "", port: 11, raw: wind)
        let r = try await alarmed(sender: "!1", senderName: "", port: 11, raw: rain)
        clock.advance(5_000)
        let (cancel, list) = try await clearedBy(sender: "!1", senderName: "", port: 11, raw: cancelWind)
        XCTAssertEqual(list.map(\.id), [w.id])
        XCTAssertEqual(cancel.kind, WarningRecord.kindCancel)
        let wNow = try await store.byId(w.id)
        XCTAssertEqual(wNow?.cancelledAt, clock.now)
        let rNow = try await store.byId(r.id)
        XCTAssertEqual(rNow?.cancelledAt, 0)
        let windStanding = try await store.standingOf(event: "Wind", test: false)
        XCTAssertTrue(windStanding.isEmpty)
        // The cancel never asks to be dismissed, and the rain warning is what the banner shows.
        XCTAssertEqual(cancel.acknowledgedAt, clock.now)
        let banner = try await store.unacknowledged()
        XCTAssertEqual(banner?.id, r.id)
        // A cancel with nothing standing is still an all-clear, clearing nothing.
        clock.advance(5_000)
        let (again, none) = try await clearedBy(sender: "!1", senderName: "", port: 11, raw: "CANCELLED: Wind - Voorbij\n\(label)")
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(again.text, "Voorbij")
    }

    func testATestWarningStandsApartAndATestCancelClearsTestsOnly() async throws {
        let real = try await alarmed(sender: "!1", senderName: "", port: 11, raw: wind)
        clock.advance(1_000)
        let test = try await alarmed(
            sender: "!1", senderName: "", port: 11, raw: "TEST WARNING Wind Minor until 10:11 UTC: proef\n\(testLabel)")
        XCTAssertTrue(test.test)
        // The test did not replace the real warning.
        let realAfterTest = try await store.byId(real.id)
        XCTAssertEqual(realAfterTest?.replacedAt, 0)
        clock.advance(1_000)
        let (_, list) = try await clearedBy(sender: "!1", senderName: "", port: 11, raw: "TEST CANCELLED: Wind\n\(testLabel)")
        XCTAssertEqual(list.map(\.id), [test.id])
        let realAfterCancel = try await store.byId(real.id)
        XCTAssertEqual(realAfterCancel?.cancelledAt, 0)
    }

    func testTheWordsOfANotificationAndTheList() async throws {
        let w = try await alarmed(sender: "!4370c1d8", senderName: "tesseract", port: 11, raw: wind)
        XCTAssertEqual(WarningWords.title(w), "WARNING Wind Moderate until 10:11 UTC")
        XCTAssertEqual(WarningWords.relayLine(w), "Relay of tesseract (!4370c1d8)")
        XCTAssertEqual(WarningWords.body(w), "Kans op windstoten tot 90 km/u\n\(label)\nRelay of tesseract (!4370c1d8)")
        XCTAssertTrue(WarningWords.isAlarm(w))
        XCTAssertEqual(WarningWords.notificationId(event: "Wind", test: false), "meshsat.warning.wind")
        XCTAssertNotEqual(WarningWords.notificationId(event: "Wind", test: true), WarningWords.notificationId(event: "Wind", test: false))
        XCTAssertEqual(WarningWords.state(w) { _ in "t" }, "Standing")
        XCTAssertEqual(WarningWords.heard(w) { _ in "10:00" }, "Relay of tesseract (!4370c1d8), alert, heard 10:00")
        clock.advance(1_000)
        let (cancel, _) = try await clearedBy(sender: "!1", senderName: "", port: 1, raw: cancelWind)
        XCTAssertEqual(WarningWords.title(cancel), "CANCELLED Wind")
        XCTAssertEqual(WarningWords.relayLine(cancel), "Relay of !1")
        XCTAssertFalse(WarningWords.isAlarm(cancel))
        XCTAssertEqual(WarningWords.state(cancel) { _ in "t" }, "All-clear")
        let gone = try await store.byId(w.id)
        XCTAssertEqual(try WarningWords.state(XCTUnwrap(gone)) { _ in "now" }, "Cancelled now")
    }

    func testDismissingMarksTheWarningAcknowledgedAndItStillStands() async throws {
        let w = try await alarmed(sender: "!1", senderName: "", port: 11, raw: wind)
        clock.advance(1_000)
        try await intake.acknowledge(w.id)
        let fetched = try await store.byId(w.id)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.acknowledgedAt, clock.now)
        XCTAssertTrue(row.standing)
        let banner = try await store.unacknowledged()
        XCTAssertNil(banner)
    }
}
