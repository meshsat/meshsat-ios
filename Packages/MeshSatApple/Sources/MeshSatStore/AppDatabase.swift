// Mirrors data/AppDatabase.kt: the SQLite database, on GRDB. Android's Room schema version 18
// is iOS schema v1, same tables, columns, indices and defaults, so the DAOs' SQL is the same
// text in both apps. Later changes are appended as further migrations, never edited
// (root CLAUDE.md rule 9).
import Foundation
import GRDB
import MeshSatEngine

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Open (and migrate) the database behind `writer`.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// The app's database file: Application Support/MeshSat/meshsat.sqlite, protected until
    /// the first unlock so the gateway can write it from the background.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("MeshSat", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(MeshSatStore.databaseFileName)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return try AppDatabase(queue)
    }

    /// A database that lives in memory: tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: DAOs (one per Room DAO)

    public var messages: MessageDao { MessageDao(db: writer) }
    public var deliveries: MessageDeliveryDao { MessageDeliveryDao(db: writer) }
    public var contacts: ContactDao { ContactDao(db: writer) }
    public var forwardingRules: ForwardingRuleDao { ForwardingRuleDao(db: writer) }
    public var signals: SignalDao { SignalDao(db: writer) }
    public var nodePositions: NodePositionDao { NodePositionDao(db: writer) }
    public var conversationKeys: ConversationKeyDao { ConversationKeyDao(db: writer) }
    public var accessRules: AccessRuleDao { AccessRuleDao(db: writer) }
    public var objectGroups: ObjectGroupDao { ObjectGroupDao(db: writer) }
    public var failoverGroups: FailoverGroupDao { FailoverGroupDao(db: writer) }
    public var auditLog: AuditLogDao { AuditLogDao(db: writer) }
    public var tleCache: TleCacheDao { TleCacheDao(db: writer) }
    public var providerCredentials: ProviderCredentialDao { ProviderCredentialDao(db: writer) }
    public var rnsTcpPeers: RnsTcpPeerDao { RnsTcpPeerDao(db: writer) }
    public var iridiumCredits: IridiumCreditDao { IridiumCreditDao(db: writer) }
    public var hembBondGroups: HembBondGroupDao { HembBondGroupDao(db: writer) }
    public var bridgeTrust: BridgeTrustDao { BridgeTrustDao(db: writer) }
    public var telemetry: TelemetryDao { TelemetryDao(db: writer) }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1: Android schema 18") { db in
            for statement in schemaV1 { try db.execute(sql: statement) }
        }
        return m
    }

    /// Room's exported schema 18, as CREATE statements. Column types follow Room's mapping
    /// (Long/Int/Boolean INTEGER, String TEXT, ByteArray BLOB, Double REAL; nullable Kotlin
    /// types without NOT NULL); the defaults are the entities' Kotlin defaults.
    static let schemaV1: [String] = [
        """
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            timestamp INTEGER NOT NULL,
            transport TEXT NOT NULL,
            direction TEXT NOT NULL,
            sender TEXT NOT NULL,
            recipient TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL,
            rawText TEXT NOT NULL DEFAULT '',
            encrypted INTEGER NOT NULL DEFAULT 0,
            forwarded INTEGER NOT NULL DEFAULT 0,
            forwardedTo TEXT NOT NULL DEFAULT ''
        )
        """,
        """
        CREATE TABLE forwarding_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL,
            direction TEXT NOT NULL,
            sourceTransport TEXT NOT NULL,
            destTransport TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            encrypt INTEGER NOT NULL DEFAULT 0,
            filterPattern TEXT,
            filterSender TEXT
        )
        """,
        """
        CREATE TABLE signal_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            timestamp INTEGER NOT NULL,
            source TEXT NOT NULL,
            value INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE node_positions (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            timestamp INTEGER NOT NULL,
            nodeId INTEGER NOT NULL,
            nodeName TEXT NOT NULL DEFAULT '',
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE conversation_keys (
            sender TEXT NOT NULL PRIMARY KEY,
            hexKey TEXT NOT NULL,
            label TEXT NOT NULL DEFAULT ''
        )
        """,
        """
        CREATE TABLE access_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            interface_id TEXT NOT NULL,
            direction TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 10,
            name TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            action TEXT NOT NULL DEFAULT 'forward',
            forward_to TEXT NOT NULL DEFAULT '',
            filters TEXT NOT NULL DEFAULT '{}',
            filter_node_group TEXT,
            filter_sender_group TEXT,
            filter_portnum_group TEXT,
            forward_options TEXT NOT NULL DEFAULT '{}',
            qos_level INTEGER NOT NULL DEFAULT 1,
            rate_limit_per_min INTEGER NOT NULL DEFAULT 0,
            rate_limit_window INTEGER NOT NULL DEFAULT 0,
            match_count INTEGER NOT NULL DEFAULT 0,
            last_match_at TEXT
        )
        """,
        """
        CREATE TABLE object_groups (
            id TEXT NOT NULL PRIMARY KEY,
            type TEXT NOT NULL,
            label TEXT NOT NULL,
            members TEXT NOT NULL DEFAULT '[]'
        )
        """,
        """
        CREATE TABLE failover_groups (
            id TEXT NOT NULL PRIMARY KEY,
            label TEXT NOT NULL,
            mode TEXT NOT NULL DEFAULT 'failover'
        )
        """,
        """
        CREATE TABLE failover_members (
            group_id TEXT NOT NULL,
            interface_id TEXT NOT NULL,
            priority INTEGER NOT NULL,
            PRIMARY KEY(group_id, interface_id)
        )
        """,
        """
        CREATE TABLE message_deliveries (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            msg_ref TEXT NOT NULL,
            rule_id INTEGER,
            channel TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued',
            priority INTEGER NOT NULL DEFAULT 10,
            payload BLOB,
            text_preview TEXT NOT NULL DEFAULT '',
            retries INTEGER NOT NULL DEFAULT 0,
            max_retries INTEGER NOT NULL DEFAULT 3,
            next_retry INTEGER,
            last_error TEXT NOT NULL DEFAULT '',
            visited TEXT NOT NULL DEFAULT '[]',
            ttl_seconds INTEGER NOT NULL DEFAULT 0,
            expires_at INTEGER,
            qos_level INTEGER NOT NULL DEFAULT 1,
            held_at INTEGER,
            seq_num INTEGER NOT NULL DEFAULT 0,
            ack_status TEXT,
            ack_timestamp INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            custody_status TEXT,
            custodian_hash TEXT,
            bundle_id TEXT,
            recipient TEXT NOT NULL DEFAULT '',
            sat_ref TEXT NOT NULL DEFAULT '',
            origin TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE INDEX idx_md_bundle_id ON message_deliveries(bundle_id)",
        """
        CREATE TABLE audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            timestamp TEXT NOT NULL,
            interface_id TEXT,
            direction TEXT,
            event_type TEXT NOT NULL,
            delivery_id INTEGER,
            rule_id INTEGER,
            detail TEXT NOT NULL DEFAULT '',
            prev_hash TEXT NOT NULL DEFAULT '',
            hash TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE INDEX idx_audit_log_ts ON audit_log(timestamp)",
        "CREATE INDEX idx_audit_log_iface ON audit_log(interface_id)",
        "CREATE INDEX idx_audit_log_event ON audit_log(event_type)",
        """
        CREATE TABLE tle_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            satelliteName TEXT NOT NULL,
            line1 TEXT NOT NULL,
            line2 TEXT NOT NULL,
            fetchedAt INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE provider_credentials (
            id TEXT NOT NULL PRIMARY KEY,
            provider TEXT NOT NULL,
            name TEXT NOT NULL,
            cred_type TEXT NOT NULL,
            encrypted_data BLOB NOT NULL,
            cert_not_after TEXT,
            cert_subject TEXT NOT NULL DEFAULT '',
            cert_fingerprint TEXT NOT NULL DEFAULT '',
            version INTEGER NOT NULL DEFAULT 1,
            source TEXT NOT NULL DEFAULT 'local',
            received_at INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE rns_tcp_peers (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL DEFAULT 4242,
            enabled INTEGER NOT NULL DEFAULT 1,
            label TEXT NOT NULL DEFAULT ''
        )
        """,
        """
        CREATE TABLE iridium_credit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            timestamp INTEGER NOT NULL,
            messageType TEXT NOT NULL,
            costCents INTEGER NOT NULL,
            moMsn INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE hemb_bond_groups (
            id TEXT NOT NULL PRIMARY KEY,
            label TEXT NOT NULL DEFAULT '',
            members TEXT NOT NULL DEFAULT '[]',
            costBudget REAL NOT NULL DEFAULT 0.0,
            createdAt INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE bridge_trust (
            bridgeHash TEXT NOT NULL PRIMARY KEY,
            pubkey BLOB NOT NULL,
            firstSeen INTEGER NOT NULL,
            lastSeen INTEGER NOT NULL,
            label TEXT NOT NULL,
            importCount INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            timestamp INTEGER NOT NULL,
            type TEXT NOT NULL,
            tag TEXT NOT NULL,
            severity TEXT NOT NULL,
            message TEXT NOT NULL,
            detail TEXT NOT NULL
        )
        """,
        "CREATE INDEX index_telemetry_timestamp ON telemetry(timestamp)",
        "CREATE INDEX index_telemetry_type ON telemetry(type)",
        """
        CREATE TABLE contacts (
            fingerprint TEXT NOT NULL,
            name TEXT NOT NULL,
            signing_pub TEXT NOT NULL,
            mesh_node_id TEXT NOT NULL,
            bridge_id TEXT NOT NULL,
            trust TEXT NOT NULL,
            issued_at INTEGER NOT NULL,
            added_at INTEGER NOT NULL,
            PRIMARY KEY(fingerprint)
        )
        """,
    ]
}

extension MeshSatStore {
    /// Now, as the DAOs' `System.currentTimeMillis()` defaults.
    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
