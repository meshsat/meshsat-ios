// Mirrors data/MessageDao.kt. Room's Flow queries are ValueObservations here: an AsyncSequence
// that yields the fresh result after every change to the tables it reads.
import Foundation
import GRDB
import MeshSatEngine

public struct MessageDao: Sendable {
    let db: any DatabaseWriter

    @discardableResult
    public func insert(_ message: MessageRecord) async throws -> Int64 {
        try await db.write { db in
            var m = message
            try m.insert(db)
            return m.id ?? 0
        }
    }

    /// Where a sent message went, e.g. "iridium:queued" then "iridium:sbd" (MESHSAT-1243).
    public func setForwardedTo(id: Int64, _ forwardedTo: String) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE messages SET forwardedTo = ? WHERE id = ?", arguments: [forwardedTo, id])
        }
    }

    /// The same, but never over a confirmed delivery: a receipt or a delivery report can
    /// arrive before the "sent" it follows is written (MESHSAT-1246).
    public func setForwardedToUnlessDelivered(id: Int64, _ forwardedTo: String) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE messages SET forwardedTo = ? WHERE id = ? AND forwardedTo NOT IN ('iridium:delivered', 'sms:delivered')",
                arguments: [forwardedTo, id])
        }
    }

    public func getRecent(limit: Int = 100) -> AsyncValueObservation<[MessageRecord]> {
        ValueObservation.tracking { db in
            try MessageRecord.fetchAll(db, sql: "SELECT * FROM messages ORDER BY timestamp DESC LIMIT ?", arguments: [limit])
        }.values(in: db)
    }

    public func getByTransport(_ transport: String, limit: Int = 100) -> AsyncValueObservation<[MessageRecord]> {
        ValueObservation.tracking { db in
            try MessageRecord.fetchAll(
                db, sql: "SELECT * FROM messages WHERE transport = ? ORDER BY timestamp DESC LIMIT ?", arguments: [transport, limit])
        }.values(in: db)
    }

    public func getBySender(_ sender: String, limit: Int = 500) -> AsyncValueObservation<[MessageRecord]> {
        ValueObservation.tracking { db in
            try MessageRecord.fetchAll(
                db, sql: "SELECT * FROM messages WHERE sender = ? ORDER BY timestamp DESC LIMIT ?", arguments: [sender, limit])
        }.values(in: db)
    }

    /// One row per conversation, keyed by the other party: the recipient of what the phone
    /// sent, the sender of what it received (MESHSAT-1249). text and transport are bare
    /// columns: SQLite takes them from the row holding the maximum only when the query has
    /// exactly ONE min() or max(), so encryption is a SUM.
    static let conversationsSQL = """
        SELECT CASE WHEN direction = 'tx' AND recipient != '' THEN recipient ELSE sender END AS sender,
               text AS lastMessage, MAX(timestamp) AS lastTimestamp,
               COUNT(*) AS messageCount, transport,
               CASE WHEN SUM(CASE WHEN encrypted = 1 THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END AS hasEncrypted
        FROM messages
        GROUP BY CASE WHEN direction = 'tx' AND recipient != '' THEN recipient ELSE sender END
        ORDER BY lastTimestamp DESC
        """

    public func getConversations() -> AsyncValueObservation<[ConversationSummary]> {
        ValueObservation.tracking { db in try ConversationSummary.fetchAll(db, sql: Self.conversationsSQL) }.values(in: db)
    }

    public func conversations() async throws -> [ConversationSummary] {
        try await db.read { db in try ConversationSummary.fetchAll(db, sql: Self.conversationsSQL) }
    }

    public func count() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0 }
    }

    public func countByTransport(_ transport: String) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE transport = ?", arguments: [transport]) ?? 0
        }
    }

    public func countEncrypted() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE encrypted = 1") ?? 0 }
    }

    public func deleteAll() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM messages") }
    }

    public func deleteBefore(_ before: Int64) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM messages WHERE timestamp < ?", arguments: [before]) }
    }

    public func search(_ query: String, limit: Int = 100) -> AsyncValueObservation<[MessageRecord]> {
        ValueObservation.tracking { db in
            try MessageRecord.fetchAll(
                db,
                sql:
                    "SELECT * FROM messages WHERE text LIKE '%' || ? || '%' OR sender LIKE '%' || ? || '%' ORDER BY timestamp DESC LIMIT ?",
                arguments: [query, query, limit])
        }.values(in: db)
    }

    public func countForwarded() -> AsyncValueObservation<Int> {
        ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE direction = 'tx' AND forwarded = 1") ?? 0
        }.values(in: db)
    }

    public func countIncoming() -> AsyncValueObservation<Int> {
        ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE direction = 'rx'") ?? 0 }
            .values(in: db)
    }

    public func countOutgoing() -> AsyncValueObservation<Int> {
        ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE direction = 'tx'") ?? 0 }
            .values(in: db)
    }

    public func countSince(_ since: Int64) -> AsyncValueObservation<Int> {
        ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE timestamp > ?", arguments: [since]) ?? 0
        }.values(in: db)
    }

    /// Messages on one transport since a moment, for Home's lanes.
    public func countByTransportSince(_ transport: String, since: Int64) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messages WHERE transport = ? AND timestamp > ?", arguments: [transport, since]) ?? 0
        }
    }

    /// Messages for a conversation (both directions).
    public func getConversation(_ peer: String, limit: Int = 500) -> AsyncValueObservation<[MessageRecord]> {
        ValueObservation.tracking { db in
            try MessageRecord.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE sender = ? OR (recipient = ? AND direction = 'tx') ORDER BY timestamp DESC LIMIT ?",
                arguments: [peer, peer, limit])
        }.values(in: db)
    }
}
