// Mirrors data/MessageAttachmentEntity.kt (MessageAttachmentDao, AppDatabase.insertAttachments;
// MESHSAT-1735): a voice note or a photo kept with a message, the bytes as they travel in the LXMF
// field with the audio mode or the image format. Sent and received alike, in the database rather
// than a file, so a message and its attachments live and die together. Same table and columns as
// Android. The store is capped at 16 MiB, oldest out first.
import Foundation
import GRDB
import MeshSatLXMF

extension AppDatabase {
    /// Android Room's message_attachments table and its two indices.
    static let schemaV6MessageAttachments: [String] = [
        """
        CREATE TABLE IF NOT EXISTS message_attachments (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            message_id INTEGER NOT NULL, kind TEXT NOT NULL, mode INTEGER NOT NULL, format TEXT NOT NULL,
            size INTEGER NOT NULL, data BLOB NOT NULL, created_at INTEGER NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS index_message_attachments_message_id ON message_attachments (message_id)",
        "CREATE INDEX IF NOT EXISTS index_message_attachments_created_at ON message_attachments (created_at)",
    ]

    public var attachments: GRDBMessageAttachmentStore { GRDBMessageAttachmentStore(db: writer) }
}

/// One stored attachment (MessageAttachmentEntity).
public struct MessageAttachmentRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let messageId: Int64
    /// "audio" or "image".
    public let kind: String
    /// Audio: the LXMF audio mode (Opus OGG = 0x10, Codec2 700C = 0x03). 0 for an image.
    public let mode: Int
    /// Image: the format name ("webp"). Empty for audio.
    public let format: String
    public let data: [UInt8]
    public let createdAt: Int64

    public var attachment: LxAttachment {
        kind == LxAttachmentKind.audio.rawValue ? .audio(mode: mode, data: data) : .image(format: format, data: data)
    }
}

/// MessageAttachmentDao on GRDB.
public struct GRDBMessageAttachmentStore: Sendable {
    /// What the phone keeps of notes and photos, received and sent alike (the Bridge's default, 16 MiB).
    public static let storeBytes: Int64 = 16 * 1024 * 1024

    let db: any DatabaseWriter

    public init(db: any DatabaseWriter) { self.db = db }

    private static func record(_ r: Row) -> MessageAttachmentRecord {
        let blob: Data = r["data"]
        return MessageAttachmentRecord(
            id: r["id"], messageId: r["message_id"], kind: r["kind"], mode: r["mode"], format: r["format"], data: [UInt8](blob),
            createdAt: r["created_at"])
    }

    /// Files `atts` under `messageId`, then trims the store to `cap`, oldest first, in one transaction
    /// (AppDatabase.insertAttachments); the rows just written are never the ones trimmed. The ids written.
    @discardableResult
    public func insertAttachments(messageId: Int64, _ atts: [LxAttachment], now: Int64, cap: Int64 = storeBytes) async throws -> [Int64] {
        try await db.write { d in
            var ids: [Int64] = []
            for a in atts {
                try d.execute(
                    sql: "INSERT INTO message_attachments (message_id, kind, mode, format, size, data, created_at) "
                        + "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [messageId, a.kind.rawValue, a.mode, a.format, a.data.count, Data(a.data), now])
                ids.append(d.lastInsertedRowID)
            }
            var over = (try Int64.fetchOne(d, sql: "SELECT COALESCE(SUM(size), 0) FROM message_attachments") ?? 0) - cap
            let keep = Set(ids)
            while over > 0 {
                let victims = try Row.fetchAll(d, sql: "SELECT id, size FROM message_attachments ORDER BY created_at, id LIMIT 32")
                    .map { (id: $0["id"] as Int64, size: $0["size"] as Int64) }.filter { !keep.contains($0.id) }
                if victims.isEmpty { break }
                var drop: [Int64] = []
                for v in victims where over > 0 {
                    drop.append(v.id)
                    over -= v.size
                }
                let marks = Array(repeating: "?", count: drop.count).joined(separator: ",")
                try d.execute(sql: "DELETE FROM message_attachments WHERE id IN (\(marks))", arguments: StatementArguments(drop))
            }
            return ids
        }
    }

    public func forMessage(_ messageId: Int64) async throws -> [MessageAttachmentRecord] {
        try await db.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM message_attachments WHERE message_id = ? ORDER BY id", arguments: [messageId]).map(
                Self.record)
        }
    }

    /// Every attachment in one conversation, keyed like the conversation query, for the chat view.
    public func forConversation(_ peer: String) async throws -> [MessageAttachmentRecord] {
        try await db.read { d in try Self.conversation(d, peer) }
    }

    /// The same, live (Room's Flow): a new value whenever a message or an attachment of the conversation
    /// is written. A message row is filed before its attachments, so a view that reads them once when the
    /// row appears misses them; this one gets them when they land.
    public func observeConversation(_ peer: String) -> AsyncValueObservation<[MessageAttachmentRecord]> {
        ValueObservation.tracking { d in try Self.conversation(d, peer) }.values(in: db)
    }

    private static func conversation(_ d: Database, _ peer: String) throws -> [MessageAttachmentRecord] {
        try Row.fetchAll(
            d,
            sql: """
                SELECT a.* FROM message_attachments a JOIN messages m ON m.id = a.message_id
                WHERE m.sender = ? OR (m.recipient = ? AND m.direction = 'tx') ORDER BY a.id
                """, arguments: [peer, peer]
        ).map(Self.record)
    }

    public func totalBytes() async throws -> Int64 {
        try await db.read { d in try Int64.fetchOne(d, sql: "SELECT COALESCE(SUM(size), 0) FROM message_attachments") ?? 0 }
    }

    public func count() async throws -> Int {
        try await db.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM message_attachments") ?? 0 }
    }

    @discardableResult
    public func deleteForMessage(_ messageId: Int64) async throws -> Int {
        try await db.write { d in
            try d.execute(sql: "DELETE FROM message_attachments WHERE message_id = ?", arguments: [messageId])
            return d.changesCount
        }
    }
}
