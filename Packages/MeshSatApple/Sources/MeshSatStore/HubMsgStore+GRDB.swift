// Mirrors data/RoomHubMsgStore.kt and data/HubMsgEntities.kt: the Hub app route's store on the
// app's database (schema v2, Android Room v21's hub_ops, hub_op_events, hub_op_missing and
// hub_inbox, same columns): every method is one transaction. The chat row is the ledger: an event
// is kept and the row's status recomputed in the same transaction. [MESHSAT-1584]
import Foundation
import GRDB
import MeshSatEngine
import MeshSatHub

extension AppDatabase {
    /// Android Room v21's hub_msg tables (time 0 = not set).
    static let schemaV2HubMsg: [String] = [
        """
        CREATE TABLE IF NOT EXISTS hub_ops (op_id TEXT NOT NULL, mid TEXT NOT NULL, recipient TEXT NOT NULL,
            message_id INTEGER NOT NULL, expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL, submission TEXT NOT NULL,
            published_at INTEGER NOT NULL, replay_at INTEGER NOT NULL, replay_given_up_at INTEGER NOT NULL, PRIMARY KEY(op_id))
        """,
        "CREATE INDEX IF NOT EXISTS index_hub_ops_expires_at ON hub_ops (expires_at)",
        """
        CREATE TABLE IF NOT EXISTS hub_op_events (event_id TEXT NOT NULL, op_id TEXT NOT NULL, mid TEXT NOT NULL,
            recipient TEXT NOT NULL, rev INTEGER NOT NULL, class TEXT NOT NULL, kind TEXT NOT NULL, reason TEXT NOT NULL,
            authority TEXT NOT NULL, scope TEXT NOT NULL, detail TEXT NOT NULL, at TEXT NOT NULL, source TEXT NOT NULL,
            valid INTEGER NOT NULL, received_at INTEGER NOT NULL, PRIMARY KEY(event_id))
        """,
        "CREATE INDEX IF NOT EXISTS index_hub_op_events_op_id ON hub_op_events (op_id)",
        """
        CREATE TABLE IF NOT EXISTS hub_op_missing (op_id TEXT NOT NULL, event_id TEXT NOT NULL, since INTEGER NOT NULL,
            PRIMARY KEY(op_id, event_id))
        """,
        """
        CREATE TABLE IF NOT EXISTS hub_inbox (origin TEXT NOT NULL, op_id TEXT NOT NULL, mid TEXT NOT NULL,
            recipient TEXT NOT NULL, content_type TEXT NOT NULL, mid_expires_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
            content_sha256 TEXT NOT NULL, message_id INTEGER NOT NULL, committed_at INTEGER NOT NULL,
            within_skew INTEGER NOT NULL, unjudged INTEGER NOT NULL, PRIMARY KEY(origin, op_id))
        """,
        "CREATE INDEX IF NOT EXISTS index_hub_inbox_origin_mid ON hub_inbox (origin, mid)",
        "CREATE INDEX IF NOT EXISTS index_hub_inbox_expires_at ON hub_inbox (expires_at)",
    ]

    public var hubMsg: GRDBHubMsgStore { GRDBHubMsgStore(db: writer) }
}

/// The route's store on GRDB. Each method runs in one write transaction.
public struct GRDBHubMsgStore: HubMsgStore {
    let db: any DatabaseWriter

    public init(db: any DatabaseWriter) { self.db = db }

    // MARK: Rows

    private static func op(_ r: Row) -> HubOp {
        HubOp(
            opId: r["op_id"], mid: r["mid"], recipient: r["recipient"], messageId: r["message_id"], expiresAt: r["expires_at"],
            createdAt: r["created_at"], submission: r["submission"], publishedAt: r["published_at"], replayAt: r["replay_at"],
            replayGivenUpAt: r["replay_given_up_at"])
    }

    private static func kept(_ r: Row) -> KeptHubEvent {
        KeptHubEvent(
            event: HubEvent(
                source: r["source"], opId: r["op_id"], mid: r["mid"], recipient: r["recipient"], eventId: r["event_id"], rev: r["rev"],
                cls: r["class"], kind: r["kind"], reason: r["reason"], authority: r["authority"], scope: r["scope"], detail: r["detail"],
                at: r["at"]),
            valid: r["valid"], added: false)
    }

    private static func opRow(_ d: Database, _ opId: String) throws -> HubOp? {
        try Row.fetchOne(d, sql: "SELECT * FROM hub_ops WHERE op_id = ?", arguments: [opId]).map(op)
    }

    private static func restatus(_ d: Database, _ opId: String) throws {
        guard let o = try opRow(d, opId) else { return }
        let events = try Row.fetchAll(d, sql: "SELECT * FROM hub_op_events WHERE op_id = ? ORDER BY rev, event_id", arguments: [opId])
            .map(kept)
        try d.execute(sql: "UPDATE messages SET forwardedTo = ? WHERE id = ?", arguments: [HubMsgStatus.of(o, events), o.messageId])
    }

    private static let completedClause =
        "e.valid = 1 AND e.class = 'completed' AND e.event_id NOT LIKE 'refusal:%'"
    private static let stillMissing = """
        EXISTS (SELECT 1 FROM hub_op_missing m WHERE m.op_id = hub_ops.op_id
            AND NOT EXISTS (SELECT 1 FROM hub_op_events k WHERE k.event_id = m.event_id AND k.op_id = m.op_id))
        """

    private static func clearIdle(_ d: Database, _ opId: String?) throws {
        let only = opId == nil ? "" : "op_id = ? AND "
        try d.execute(
            sql: """
                UPDATE hub_ops SET replay_at = 0 WHERE \(only)replay_at != 0
                AND NOT EXISTS (SELECT 1 FROM hub_op_missing m WHERE m.op_id = hub_ops.op_id)
                """, arguments: opId.map { [$0] } ?? [])
    }

    // MARK: The sender

    public func createOutgoing(_ op: HubOp, sender: String, text: String) async throws -> Int64 {
        try await db.write { d in
            var m = MessageRecord(
                timestamp: op.createdAt, transport: "hub", direction: "tx", sender: sender, recipient: op.recipient, text: text,
                forwarded: true, forwardedTo: HubMsgStatus.queued)
            try m.insert(d)
            let id = m.id ?? 0
            try d.execute(
                sql: """
                    INSERT INTO hub_ops (op_id, mid, recipient, message_id, expires_at, created_at, submission, published_at, replay_at,
                        replay_given_up_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0)
                    """, arguments: [op.opId, op.mid, op.recipient, id, op.expiresAt, op.createdAt, op.submission])
            return id
        }
    }

    public func op(_ opId: String) async throws -> HubOp? { try await db.read { d in try Self.opRow(d, opId) } }

    public func unpublished(limit: Int) async throws -> [HubOp] {
        try await db.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM hub_ops WHERE published_at = 0 ORDER BY created_at, op_id LIMIT ?", arguments: [limit])
                .map(Self.op)
        }
    }

    public func markPublished(_ opId: String, atMs: Int64) async throws {
        try await db.write { d in
            try d.execute(sql: "UPDATE hub_ops SET published_at = ? WHERE op_id = ? AND published_at = 0", arguments: [atMs, opId])
            try Self.restatus(d, opId)
        }
    }

    public func keepEvent(_ e: HubEvent, valid: Bool, atMs: Int64) async throws -> KeptHubEvent {
        try await db.write { d in
            try d.execute(
                sql: """
                    INSERT OR IGNORE INTO hub_op_events (event_id, op_id, mid, recipient, rev, class, kind, reason, authority, scope,
                        detail, at, source, valid, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    e.eventId, e.opId, e.mid, e.recipient, e.rev, e.cls, e.kind, e.reason, e.authority, e.scope, e.detail, e.at, e.source,
                    valid, atMs,
                ])
            let added = d.changesCount > 0
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM hub_op_events WHERE event_id = ?", arguments: [e.eventId]) else {
                throw DatabaseError(message: "event not kept")
            }
            var kept = Self.kept(row)
            kept.added = added
            if kept.valid && kept.event.cls == "completed" && !HubMsgStatus.isRefusal(kept.event) {
                try d.execute(sql: "DELETE FROM hub_op_missing WHERE op_id = ?", arguments: [kept.event.opId])
            } else {
                try d.execute(
                    sql: "DELETE FROM hub_op_missing WHERE op_id = ? AND event_id = ?", arguments: [kept.event.opId, kept.event.eventId])
            }
            try Self.clearIdle(d, kept.event.opId)
            try Self.restatus(d, kept.event.opId)
            return kept
        }
    }

    public func wantReplay(_ opId: String, eventId: String, atMs: Int64) async throws {
        try await db.write { d in
            guard try Self.opRow(d, opId) != nil else { return }
            try d.execute(sql: "UPDATE hub_ops SET replay_at = ? WHERE op_id = ? AND replay_at = 0", arguments: [atMs, opId])
            try d.execute(
                sql: "INSERT OR IGNORE INTO hub_op_missing (op_id, event_id, since) VALUES (?, ?, ?)", arguments: [opId, eventId, atMs])
        }
    }

    public func resolveKeptMissing() async throws -> Int {
        try await db.write { d in
            try d.execute(
                sql: """
                    DELETE FROM hub_op_missing WHERE event_id != ''
                    AND EXISTS (SELECT 1 FROM hub_op_events e WHERE e.event_id = hub_op_missing.event_id)
                    """)
            var n = d.changesCount
            try d.execute(
                sql: "DELETE FROM hub_op_missing WHERE op_id IN (SELECT e.op_id FROM hub_op_events e WHERE \(Self.completedClause))")
            n += d.changesCount
            try Self.clearIdle(d, nil)
            return n
        }
    }

    public func eventKept(_ eventId: String) async throws -> Bool {
        try await db.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM hub_op_events WHERE event_id = ?", arguments: [eventId]) ?? 0 > 0
        }
    }

    public func completed(_ opId: String) async throws -> Bool {
        try await db.read { d in
            try Int.fetchOne(
                d, sql: "SELECT COUNT(*) FROM hub_op_events e WHERE e.op_id = ? AND \(Self.completedClause)", arguments: [opId])
                ?? 0 > 0
        }
    }

    public func missing(_ opId: String) async throws -> [String] {
        try await db.read { d in
            try String.fetchAll(d, sql: "SELECT event_id FROM hub_op_missing WHERE op_id = ? ORDER BY since, event_id", arguments: [opId])
        }
    }

    public func owed(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp] {
        try await db.read { d in
            try Row.fetchAll(
                d,
                sql: """
                    SELECT * FROM hub_ops WHERE replay_at != 0 AND submission != '' AND replay_given_up_at = 0 AND expires_at + ? >= ?
                    AND \(Self.stillMissing)
                    AND (replay_at > ? OR (replay_at = ? AND op_id > ?)) ORDER BY replay_at, op_id LIMIT ?
                    """, arguments: [withinMs, nowMs, after.key, after.key, after.opId, limit]
            ).map(Self.op)
        }
    }

    public func toReconcile(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp] {
        try await db.read { d in
            try Row.fetchAll(
                d,
                sql: """
                    SELECT * FROM hub_ops WHERE submission != '' AND replay_given_up_at = 0 AND expires_at + ? >= ?
                    AND NOT EXISTS (SELECT 1 FROM hub_op_events e WHERE e.op_id = hub_ops.op_id AND \(Self.completedClause))
                    AND (created_at > ? OR (created_at = ? AND op_id > ?)) ORDER BY created_at, op_id LIMIT ?
                    """, arguments: [withinMs, nowMs, after.key, after.key, after.opId, limit]
            ).map(Self.op)
        }
    }

    public func toGiveUp(nowMs: Int64, withinMs: Int64, limit: Int) async throws -> [HubOp] {
        try await db.read { d in
            try Row.fetchAll(
                d,
                sql: """
                    SELECT * FROM hub_ops WHERE replay_given_up_at = 0 AND expires_at + ? < ?
                    AND NOT EXISTS (SELECT 1 FROM hub_op_events e WHERE e.op_id = hub_ops.op_id AND \(Self.completedClause))
                    AND (\(Self.stillMissing)
                        OR NOT EXISTS (SELECT 1 FROM hub_op_events e WHERE e.op_id = hub_ops.op_id AND e.valid = 1
                            AND e.class IN ('completed', 'failed', 'expired')))
                    ORDER BY created_at, op_id LIMIT ?
                    """, arguments: [withinMs, nowMs, limit]
            ).map(Self.op)
        }
    }

    public func giveUp(_ opId: String, atMs: Int64) async throws {
        try await db.write { d in
            try d.execute(
                sql: "UPDATE hub_ops SET replay_given_up_at = ? WHERE op_id = ? AND replay_given_up_at = 0", arguments: [atMs, opId])
            try Self.restatus(d, opId)
        }
    }

    public func pruneOps(nowMs: Int64) async throws -> Int {
        try await db.write { d in
            let cutoff = nowMs - HubMsgInbox.skewMs - HubMsgInbox.retentionAfterExpiryMs
            try d.execute(
                sql: "DELETE FROM hub_op_events WHERE op_id IN (SELECT op_id FROM hub_ops WHERE expires_at < ?)", arguments: [cutoff])
            try d.execute(
                sql: "DELETE FROM hub_op_missing WHERE op_id IN (SELECT op_id FROM hub_ops WHERE expires_at < ?)", arguments: [cutoff])
            try d.execute(sql: "DELETE FROM hub_ops WHERE expires_at < ?", arguments: [cutoff])
            return d.changesCount
        }
    }

    // MARK: The receiver

    /// The inbox inside the running transaction (also what the fixture cases run against).
    struct InboxTx: HubMsgInbox.Transaction {
        let d: Database

        private static func entry(_ r: Row) -> HubMsgInbox.Entry {
            HubMsgInbox.Entry(
                origin: r["origin"], opId: r["op_id"], mid: r["mid"], recipient: r["recipient"], contentType: r["content_type"],
                midExpiresAt: r["mid_expires_at"], expiresAt: r["expires_at"], contentSha256: r["content_sha256"],
                messageId: r["message_id"], committedAt: r["committed_at"], withinSkew: r["within_skew"], unjudged: r["unjudged"])
        }

        func byOp(origin: String, opId: String) throws -> HubMsgInbox.Entry? {
            try Row.fetchOne(d, sql: "SELECT * FROM hub_inbox WHERE origin = ? AND op_id = ?", arguments: [origin, opId]).map(Self.entry)
        }

        func byMid(origin: String, mid: String) throws -> HubMsgInbox.Entry? {
            try Row.fetchOne(
                d, sql: "SELECT * FROM hub_inbox WHERE origin = ? AND mid = ? ORDER BY committed_at LIMIT 1", arguments: [origin, mid]
            ).map(Self.entry)
        }

        func count() throws -> Int { try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM hub_inbox") ?? 0 }

        func pruneBefore(_ nowMs: Int64) throws -> Int {
            try d.execute(
                sql: "DELETE FROM hub_inbox WHERE expires_at + ? < ?",
                arguments: [HubMsgInbox.skewMs + HubMsgInbox.retentionAfterExpiryMs, nowMs])
            return d.changesCount
        }

        func insert(_ e: HubMsgInbox.Entry, store: Bool, body: String) throws -> HubMsgInbox.Entry {
            var kept = e
            if store {
                var m = MessageRecord(
                    timestamp: e.committedAt, transport: "hub", direction: "rx", sender: e.origin, recipient: e.recipient, text: body)
                try m.insert(d)
                kept.messageId = m.id ?? 0
            }
            try d.execute(
                sql: """
                    INSERT INTO hub_inbox (origin, op_id, mid, recipient, content_type, mid_expires_at, expires_at, content_sha256,
                        message_id, committed_at, within_skew, unjudged) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    kept.origin, kept.opId, kept.mid, kept.recipient, kept.contentType, kept.midExpiresAt, kept.expiresAt,
                    kept.contentSha256, kept.messageId, kept.committedAt, kept.withinSkew, kept.unjudged,
                ])
            return kept
        }
    }

    public func commitDelivery(_ d: HubDelivery, nowMs: Int64, clockEstablished: Bool, capacity: Int) async throws -> HubMsgInbox.Answer {
        try await db.write { db in
            try HubMsgInbox.commit(InboxTx(d: db), d, nowMs: nowMs, clockEstablished: clockEstablished, capacity: capacity)
        }
    }

    public func pruneInbox(nowMs: Int64) async throws -> Int {
        try await db.write { d in try InboxTx(d: d).pruneBefore(nowMs) }
    }
}
