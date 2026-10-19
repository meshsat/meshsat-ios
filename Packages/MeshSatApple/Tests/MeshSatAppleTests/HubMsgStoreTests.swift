// Mirrors androidTest HubMsgRoomTest.kt: the Hub app route's GRDB store (schema v2) on the app's
// real database: the release's 17 inbox cases (C3) on SQLite; an event kept and the chat row's
// status in one transaction (a failing status write leaves no event); obligations named by event,
// ended only by their event or a completion (A15), and the listings' cursors and bound (A12,
// HM-R7); a v1 database upgraded to v2 with its messages. [MESHSAT-1584]
import CryptoKit
import Foundation
import GRDB
import MeshSatEngine
import MeshSatHub
import XCTest

@testable import MeshSatStore

final class HubMsgStoreTests: XCTestCase {
    private let now: Int64 = 1_792_400_000_000

    private func outgoing(_ store: GRDBHubMsgStore, _ i: Int64 = 0, created: Int64? = nil) async throws -> HubOp {
        let t = (created ?? now) + i
        let opId = HubMsgIds.newV7(t)
        let mid = HubMsgIds.newV7(t)
        let sub = HubSubmission.create(
            opId: opId, mid: mid, to: "bridge:kit-b", body: "text \(i)", midExpiresAt: t + 3_600_000, expiresAt: t + 3_600_000)
        var op = HubOp(
            opId: opId, mid: mid, recipient: "bridge:kit-b", messageId: 0, expiresAt: t + 3_600_000, createdAt: t, submission: sub.toJson())
        op.messageId = try await store.createOutgoing(op, sender: "bridge:phone-a", text: "text \(i)")
        return op
    }

    private func event(_ op: HubOp, _ cls: String, _ kind: String, _ authority: String, _ reason: String = "") -> HubEvent {
        HubEvent(
            source: "status_topic", opId: op.opId, mid: op.mid, recipient: op.recipient, eventId: HubMsgIds.newV7(now), rev: 1, cls: cls,
            kind: kind, reason: reason, authority: authority)
    }

    private func status(_ db: AppDatabase, _ op: HubOp) throws -> String {
        try db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT forwardedTo FROM messages WHERE id = ?", arguments: [op.messageId]) ?? ""
        }
    }

    private func sql(_ db: AppDatabase, _ q: String) throws { try db.writer.write { d in try d.execute(sql: q) } }

    private func count(_ db: AppDatabase, _ q: String) throws -> Int { try db.writer.read { d in try Int.fetchOne(d, sql: q) ?? 0 } }

    private static func hexBytes(_ s: String) -> [UInt8] {
        let c = Array(s.utf8)
        return stride(from: 0, to: c.count, by: 2).map { UInt8(String(decoding: c[$0..<$0 + 2], as: UTF8.self), radix: 16) ?? 0 }
    }

    private static func int64(_ any: Any?) -> Int64 { (any as? NSNumber)?.int64Value ?? 0 }

    func testTheReleaseInboxCasesHoldOnSqlite() async throws {
        let db = try AppDatabase.inMemory()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "inbox_cases", withExtension: "json", subdirectory: "Fixtures/hemb-ng"))
        let raw = try Data(contentsOf: url)
        // The copy is the release's file (fixtures-v1.1, SHA256SUMS).
        XCTAssertEqual(
            "d51e5344d45f5fc2f1911b3713a1170cdb5883fffe1ff4b106b9d8f91e169792",
            SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
        XCTAssertEqual(17, cases.count)
        for c in cases {
            try sql(db, "DELETE FROM hub_inbox")
            for (i, s) in (c["steps"] as? [[String: Any]] ?? []).enumerated() {
                let sub = s["submission"] as? [String: Any] ?? [:]
                let d = HubDelivery(
                    opId: sub["op_id"] as? String ?? "", mid: sub["mid"] as? String ?? "", from: sub["origin"] as? String ?? "",
                    to: sub["recipient"] as? String ?? "", contentType: sub["content_type"] as? String ?? "",
                    midExpiresAt: Self.int64(sub["mid_expires_at"]), expiresAt: Self.int64(sub["expires_at"]),
                    contentSha256: sub["content_sha256"] as? String ?? "",
                    body: String(decoding: Self.hexBytes(sub["body_hex"] as? String ?? ""), as: UTF8.self))
                var got = try await db.hubMsg.commitDelivery(
                    d, nowMs: Self.int64(s["now"]), clockEstablished: s["clock_established"] as? Bool ?? false,
                    capacity: Int(Self.int64(c["capacity"])))
                got.messageId = 0
                let e = s["expect"] as? [String: Any] ?? [:]
                let want = HubMsgInbox.Answer(
                    result: e["result"] as? String ?? "", reason: e["reason"] as? String ?? "",
                    storedNow: e["stored_now"] as? Bool ?? false,
                    withinSkew: e["accepted_within_skew"] as? Bool ?? false, unjudged: e["expiry_unjudged"] as? Bool ?? false)
                XCTAssertEqual(want, got, "\(c["case"] as? String ?? "") step \(i + 1)")
            }
        }
    }

    func testAnEventAndItsChatRowAreOneTransaction() async throws {
        let db = try AppDatabase.inMemory()
        let store = db.hubMsg
        let op = try await outgoing(store)
        XCTAssertEqual(HubMsgStatus.queued, try status(db, op))
        try await store.markPublished(op.opId, atMs: now)
        XCTAssertEqual(HubMsgStatus.accepted, try status(db, op))
        let fwd = event(op, "forwarded", "hub_forwarded", "hub")
        try sql(db, "CREATE TRIGGER test_fail BEFORE UPDATE OF forwardedTo ON messages BEGIN SELECT RAISE(ABORT, 'test'); END")
        var failed = false
        do { _ = try await store.keepEvent(fwd, valid: true, atMs: now) } catch { failed = true }
        try sql(db, "DROP TRIGGER test_fail")
        XCTAssertTrue(failed, "the status write failure did not reach the caller")
        let keptAfterFailure = try await store.eventKept(fwd.eventId)
        XCTAssertFalse(keptAfterFailure, "an event kept without the chat row taking it in")
        let first = try await store.keepEvent(fwd, valid: true, atMs: now)
        XCTAssertTrue(first.added)
        XCTAssertEqual(HubMsgStatus.forwarded, try status(db, op))
        let again = try await store.keepEvent(fwd, valid: true, atMs: now)
        XCTAssertFalse(again.added)
        _ = try await store.keepEvent(event(op, "completed", "recipient_app_stored", "recipient"), valid: true, atMs: now)
        XCTAssertEqual(HubMsgStatus.delivered, try status(db, op))
    }

    func testAnObligationEndsOnlyWithItsEventOrACompletion() async throws {
        let db = try AppDatabase.inMemory()
        let store = db.hubMsg
        let op = try await outgoing(store)
        try await store.markPublished(op.opId, atMs: now)
        let expiry = event(op, "expired", "hub_expired", "hub", "expired")
        _ = try await store.keepEvent(expiry, valid: true, atMs: now)
        let completion = event(op, "completed", "recipient_app_stored", "recipient")
        try await store.wantReplay(op.opId, eventId: completion.eventId, atMs: now)
        try await store.wantReplay("not-ours", eventId: "x", atMs: now)
        let missing = try await store.missing(op.opId)
        XCTAssertEqual([completion.eventId], missing)
        XCTAssertEqual(0, try count(db, "SELECT COUNT(*) FROM hub_op_missing WHERE op_id = 'not-ours'"))
        _ = try await store.keepEvent(expiry, valid: true, atMs: now)  // a copy of the older terminal
        let resolved = try await store.resolveKeptMissing()
        XCTAssertEqual(0, resolved)
        let owed = try await store.owed(nowMs: now, withinMs: 3_600_000, after: HubOpCursor(), limit: 10)
        XCTAssertEqual(1, owed.count)
        let walk = try await store.toReconcile(nowMs: now, withinMs: 3_600_000, after: HubOpCursor(), limit: 10)
        XCTAssertEqual(1, walk.count)
        XCTAssertEqual(HubMsgStatus.expired, try status(db, op))
        _ = try await store.keepEvent(completion, valid: true, atMs: now)
        let after = try await store.missing(op.opId)
        XCTAssertTrue(after.isEmpty)
        let kept = try await store.op(op.opId)
        XCTAssertEqual(0, kept?.replayAt)
        XCTAssertEqual(HubMsgStatus.delivered, try status(db, op))
        let walkAfter = try await store.toReconcile(nowMs: now, withinMs: 3_600_000, after: HubOpCursor(), limit: 10)
        XCTAssertTrue(walkAfter.isEmpty)
    }

    func testTheBoundGivesUpOnlyWhatIsReallyMissing() async throws {
        let db = try AppDatabase.inMemory()
        let store = db.hubMsg
        let named = try await outgoing(store, 0)
        let nothing = try await outgoing(store, 1)
        let stale = try await outgoing(store, 2)
        let expiredOnly = try await outgoing(store, 3)
        try await store.wantReplay(named.opId, eventId: HubMsgIds.newV7(now), atMs: now)
        let e = event(stale, "expired", "hub_expired", "hub", "expired")
        try await store.wantReplay(stale.opId, eventId: e.eventId, atMs: now)
        // Kept while its strike cannot be written: a stale row.
        try sql(db, "CREATE TRIGGER test_fail BEFORE DELETE ON hub_op_missing BEGIN SELECT RAISE(ABORT, 'test'); END")
        _ = try? await store.keepEvent(e, valid: true, atMs: now)  // fails whole: the event is not kept either
        let staleKept = try await store.eventKept(e.eventId)
        XCTAssertFalse(staleKept)
        try sql(
            db,
            """
            INSERT INTO hub_op_events (event_id, op_id, mid, recipient, rev, class, kind, reason, authority, scope, detail, at, source,
                valid, received_at) VALUES ('\(e.eventId)', '\(stale.opId)', '\(stale.mid)', '\(stale.recipient)', 1, 'expired',
                'hub_expired', 'expired', 'hub', '', '', '', 'status_topic', 1, \(now))
            """)
        _ = try await store.keepEvent(event(expiredOnly, "expired", "hub_expired", "hub", "expired"), valid: true, atMs: now)
        let later = now + 3_600_000 + 12 * 3_600_000 + 10  // past the bound of all four (created 0 to 3 ms apart)
        let listed = Set(try await store.toGiveUp(nowMs: later, withinMs: 12 * 3_600_000, limit: 10).map(\.opId))
        try sql(db, "DROP TRIGGER test_fail")
        XCTAssertEqual([named.opId, nothing.opId], listed)
        let owed = try await store.owed(nowMs: now, withinMs: 12 * 3_600_000, after: HubOpCursor(), limit: 10)
        XCTAssertFalse(owed.contains { $0.opId == stale.opId })
        try await store.giveUp(named.opId, atMs: later)
        XCTAssertEqual(HubMsgStatus.unknown, try status(db, named))
        let given = try await store.op(named.opId)
        XCTAssertNotEqual(0, given?.replayAt)
    }

    func testTheListingsPageWithACursor() async throws {
        let db = try AppDatabase.inMemory()
        let store = db.hubMsg
        var ops: [HubOp] = []
        for i in 0..<7 { ops.append(try await outgoing(store, Int64(i), created: now)) }
        var seen: Set<String> = []
        var c = HubOpCursor()
        var pages = 0
        while pages < 5 {
            pages += 1
            let page = try await store.toReconcile(nowMs: now, withinMs: 3_600_000, after: c, limit: 3)
            for o in page { XCTAssertTrue(seen.insert(o.opId).inserted, "listed twice") }
            if page.count < 3 { break }
            c = HubOpCursor(key: page[page.count - 1].createdAt, opId: page[page.count - 1].opId)
        }
        XCTAssertEqual(Set(ops.map(\.opId)), seen)
    }

    func testAVersion1DatabaseUpgradesTo2AndKeepsItsMessages() async throws {
        let queue = try DatabaseQueue()
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1: Android schema 18") { db in
            for statement in AppDatabase.schemaV1 { try db.execute(sql: statement) }
        }
        try v1.migrate(queue)
        try await queue.write { d in
            var m = MessageRecord(timestamp: 1000, transport: "sms", direction: "rx", sender: "+31600000000", text: "kept")
            try m.insert(d)
        }
        let db = try AppDatabase(queue)
        XCTAssertEqual(1, try count(db, "SELECT COUNT(*) FROM messages WHERE text = 'kept'"))
        let store = db.hubMsg
        let op = try await outgoing(store)
        _ = try await store.keepEvent(event(op, "forwarded", "hub_forwarded", "hub"), valid: true, atMs: now)
        XCTAssertEqual(HubMsgStatus.forwarded, try status(db, op))
    }
}
