// Mirrors data/WarningEntity.kt (WarningDao) and Room migration 23 -> 24 (MESHSAT-1734, iOS
// MESHSAT-1819): the public warnings a kit relayed over the mesh, as this phone heard them. Same
// table and columns as Android, so a database copied between the apps reads the same.
import Foundation
import GRDB
import MeshSatEngine

extension AppDatabase {
    /// Android Room v24's warnings table and its two indices.
    static let schemaV4Warnings: [String] = [
        """
        CREATE TABLE IF NOT EXISTS warnings (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, received_at INTEGER NOT NULL,
            port INTEGER NOT NULL, sender TEXT NOT NULL, sender_name TEXT NOT NULL, kind TEXT NOT NULL, test INTEGER NOT NULL,
            event TEXT NOT NULL, severity TEXT NOT NULL, until_utc TEXT NOT NULL, text TEXT NOT NULL, label TEXT NOT NULL,
            raw TEXT NOT NULL, dedup_key TEXT NOT NULL, cancelled_at INTEGER NOT NULL, replaced_at INTEGER NOT NULL,
            acknowledged_at INTEGER NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS index_warnings_received_at ON warnings (received_at)",
        "CREATE INDEX IF NOT EXISTS index_warnings_dedup_key ON warnings (dedup_key)",
    ]

    public var warnings: GRDBWarningStore { GRDBWarningStore(db: writer) }
}

/// WarningDao on GRDB.
public struct GRDBWarningStore: WarningStore {
    let db: any DatabaseWriter

    public init(db: any DatabaseWriter) { self.db = db }

    private static func record(_ r: Row) -> WarningRecord {
        WarningRecord(
            id: r["id"], receivedAt: r["received_at"], port: r["port"], sender: r["sender"], senderName: r["sender_name"], kind: r["kind"],
            test: r["test"], event: r["event"], severity: r["severity"], until: r["until_utc"], text: r["text"], label: r["label"],
            raw: r["raw"], dedupKey: r["dedup_key"], cancelledAt: r["cancelled_at"], replacedAt: r["replaced_at"],
            acknowledgedAt: r["acknowledged_at"])
    }

    public func insert(_ w: WarningRecord) async throws -> Int64 {
        try await db.write { d in
            try d.execute(
                sql: """
                    INSERT INTO warnings (received_at, port, sender, sender_name, kind, test, event, severity, until_utc, text, label,
                        raw, dedup_key, cancelled_at, replaced_at, acknowledged_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    w.receivedAt, w.port, w.sender, w.senderName, w.kind, w.test, w.event, w.severity, w.until, w.text, w.label, w.raw,
                    w.dedupKey, w.cancelledAt, w.replacedAt, w.acknowledgedAt,
                ])
            return d.lastInsertedRowID
        }
    }

    public func countRecent(key: String, since: Int64) async throws -> Int {
        try await db.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM warnings WHERE dedup_key = ? AND received_at >= ?", arguments: [key, since]) ?? 0
        }
    }

    public func standingOf(event: String, test: Bool) async throws -> [WarningRecord] {
        try await db.read { d in
            try Row.fetchAll(
                d,
                sql: """
                    SELECT * FROM warnings WHERE kind != 'cancel' AND event = ? AND test = ? AND cancelled_at = 0 AND replaced_at = 0
                    ORDER BY received_at, id
                    """, arguments: [event, test]
            ).map(Self.record)
        }
    }

    public func markReplaced(_ ids: [Int64], at: Int64) async throws { try await mark("replaced_at", ids, at) }

    public func markCancelled(_ ids: [Int64], at: Int64) async throws { try await mark("cancelled_at", ids, at) }

    private func mark(_ column: String, _ ids: [Int64], _ at: Int64) async throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try await db.write { d in
            try d.execute(
                sql: "UPDATE warnings SET \(column) = ? WHERE id IN (\(marks))",
                arguments: StatementArguments([at] + ids))
        }
    }

    public func acknowledge(_ id: Int64, at: Int64) async throws {
        try await db.write { d in
            try d.execute(sql: "UPDATE warnings SET acknowledged_at = ? WHERE id = ? AND acknowledged_at = 0", arguments: [at, id])
        }
    }

    public func byId(_ id: Int64) async throws -> WarningRecord? {
        try await db.read { d in try Row.fetchOne(d, sql: "SELECT * FROM warnings WHERE id = ?", arguments: [id]).map(Self.record) }
    }

    public func recent(limit: Int) async throws -> [WarningRecord] {
        try await db.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM warnings ORDER BY received_at DESC, id DESC LIMIT ?", arguments: [limit])
                .map(Self.record)
        }
    }

    public func unacknowledged() async throws -> WarningRecord? {
        try await db.read { d in
            try Row.fetchOne(
                d,
                sql: """
                    SELECT * FROM warnings WHERE kind != 'cancel' AND cancelled_at = 0 AND replaced_at = 0 AND acknowledged_at = 0
                    ORDER BY received_at DESC, id DESC LIMIT 1
                    """
            ).map(Self.record)
        }
    }

    public func deleteOlderThan(_ before: Int64) async throws -> Int {
        try await db.write { d in
            try d.execute(sql: "DELETE FROM warnings WHERE received_at < ?", arguments: [before])
            return d.changesCount
        }
    }
}
