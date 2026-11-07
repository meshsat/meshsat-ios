// Mirrors data/LxmfMidEntity.kt and AppDatabase.insertLxmfOnce (HeMB-NG contract C2, MESHSAT-1641): an
// LXMF message id this phone has taken in, per sender, so a repeat of the message (a retry with a new
// LXMF hash, or the same message over another route) is dropped, also after a restart. Kept 30 days.
// Same table and columns as Android.
import Foundation
import GRDB
import MeshSatEngine

extension AppDatabase {
    /// Android Room's lxmf_mids table and its index.
    static let schemaV5LxmfMids: [String] = [
        """
        CREATE TABLE IF NOT EXISTS lxmf_mids (origin TEXT NOT NULL, mid TEXT NOT NULL, received_at INTEGER NOT NULL,
            PRIMARY KEY(origin, mid))
        """,
        "CREATE INDEX IF NOT EXISTS index_lxmf_mids_received_at ON lxmf_mids (received_at)",
    ]

    public var lxmfMids: GRDBLxmfMidStore { GRDBLxmfMidStore(db: writer) }
}

/// LxmfMidDao on GRDB, plus the one-transaction filing of a message with its mid.
public struct GRDBLxmfMidStore: Sendable {
    /// LXMF_MID_RETENTION_MS: how long a taken id is remembered.
    public static let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1000

    let db: any DatabaseWriter

    public init(db: any DatabaseWriter) { self.db = db }

    /// Files an inbound LXMF message that carries a mid, with its (origin, mid), in one transaction (r40
    /// review R40-R2): both or neither. The row id, or nil for a repeat, with nothing written. A failure
    /// throws and writes nothing, so the message can come again and be taken then.
    public func insertLxmfOnce(origin: String, mid: String, now: Int64, message: MessageRecord) async throws -> Int64? {
        try await db.write { d in
            try d.execute(
                sql: "INSERT OR IGNORE INTO lxmf_mids (origin, mid, received_at) VALUES (?, ?, ?)", arguments: [origin, mid, now])
            guard d.changesCount == 1 else { return nil }
            var m = message
            try m.insert(d)
            return m.id
        }
    }

    /// Remembers (origin, mid) alone; false when it was already there.
    public func insert(origin: String, mid: String, now: Int64) async throws -> Bool {
        try await db.write { d in
            try d.execute(
                sql: "INSERT OR IGNORE INTO lxmf_mids (origin, mid, received_at) VALUES (?, ?, ?)", arguments: [origin, mid, now])
            return d.changesCount == 1
        }
    }

    @discardableResult
    public func pruneBefore(_ cutoff: Int64) async throws -> Int {
        try await db.write { d in
            try d.execute(sql: "DELETE FROM lxmf_mids WHERE received_at < ?", arguments: [cutoff])
            return d.changesCount
        }
    }

    public func count() async throws -> Int {
        try await db.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM lxmf_mids") ?? 0 }
    }
}
