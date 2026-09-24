// Mirrors the smaller DAOs of data/: contacts, forwarding rules, signal history, node
// positions, conversation keys, access rules, object groups, failover groups, the audit log,
// the TLE cache, provider credentials, Reticulum TCP peers, the Iridium credit log, HeMB bond
// groups, bridge trust and telemetry. Same SQL as the Kotlin.
import Foundation
import GRDB
import MeshSatEngine

public struct ContactDao: Sendable {
    let db: any DatabaseWriter

    public func observeAll() -> AsyncValueObservation<[Contact]> {
        ValueObservation.tracking { db in try Contact.fetchAll(db, sql: "SELECT * FROM contacts ORDER BY name COLLATE NOCASE") }.values(
            in: db)
    }

    public func getAll() async throws -> [Contact] {
        try await db.read { db in try Contact.fetchAll(db, sql: "SELECT * FROM contacts ORDER BY name COLLATE NOCASE") }
    }

    public func get(_ fingerprint: String) async throws -> Contact? {
        try await db.read { db in try Contact.fetchOne(db, sql: "SELECT * FROM contacts WHERE fingerprint = ?", arguments: [fingerprint]) }
    }

    public func upsert(_ contact: Contact) async throws {
        try await db.write { db in try contact.upsert(db) }
    }

    public func delete(_ fingerprint: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM contacts WHERE fingerprint = ?", arguments: [fingerprint]) }
    }
}

public struct ForwardingRuleDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() -> AsyncValueObservation<[ForwardingRuleRecord]> {
        ValueObservation.tracking { db in try ForwardingRuleRecord.fetchAll(db, sql: "SELECT * FROM forwarding_rules ORDER BY id ASC") }
            .values(in: db)
    }

    public func getAllSync() async throws -> [ForwardingRuleRecord] {
        try await db.read { db in try ForwardingRuleRecord.fetchAll(db, sql: "SELECT * FROM forwarding_rules ORDER BY id ASC") }
    }

    /// Insert, replacing a row with the same id (Room's REPLACE).
    @discardableResult
    public func insert(_ rule: ForwardingRuleRecord) async throws -> Int64 {
        try await db.write { db in
            var r = rule
            if r.id == nil {
                try r.insert(db)
            } else {
                try r.upsert(db)
            }
            return r.id ?? 0
        }
    }

    public func update(_ rule: ForwardingRuleRecord) async throws {
        try await db.write { db in try rule.update(db) }
    }

    public func deleteById(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM forwarding_rules WHERE id = ?", arguments: [id]) }
    }

    public func deleteAll() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM forwarding_rules") }
    }
}

public struct SignalDao: Sendable {
    let db: any DatabaseWriter

    public func insert(_ record: SignalRecord) async throws {
        try await db.write { db in
            var r = record
            try r.insert(db)
        }
    }

    /// The readings of a source since a moment, oldest first (SignalDao.getSince).
    /// One-shot read of the readings since `since` (the passes screen's signal history).
    public func fetchSince(source: String, since: Int64) async throws -> [SignalRecord] {
        try await db.read { db in
            try SignalRecord.fetchAll(
                db, sql: "SELECT * FROM signal_history WHERE source = ? AND timestamp >= ? ORDER BY timestamp ASC",
                arguments: [source, since])
        }
    }

    public func getRecent(source: String, limit: Int = 360) -> AsyncValueObservation<[SignalRecord]> {
        ValueObservation.tracking { db in
            try SignalRecord.fetchAll(
                db, sql: "SELECT * FROM signal_history WHERE source = ? ORDER BY timestamp DESC LIMIT ?", arguments: [source, limit])
        }.values(in: db)
    }

    public func getSince(source: String, since: Int64) -> AsyncValueObservation<[SignalRecord]> {
        ValueObservation.tracking { db in
            try SignalRecord.fetchAll(
                db, sql: "SELECT * FROM signal_history WHERE source = ? AND timestamp > ? ORDER BY timestamp ASC",
                arguments: [source, since])
        }.values(in: db)
    }

    /// Most recent record for a source (for the health scorer).
    public func getLatestForSource(_ source: String) async throws -> SignalRecord? {
        try await db.read { db in
            try SignalRecord.fetchOne(
                db, sql: "SELECT * FROM signal_history WHERE source = ? ORDER BY timestamp DESC LIMIT 1", arguments: [source])
        }
    }

    public func deleteBefore(_ before: Int64) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM signal_history WHERE timestamp < ?", arguments: [before]) }
    }
}

public struct NodePositionDao: Sendable {
    let db: any DatabaseWriter

    public func insert(_ position: NodePosition) async throws {
        try await db.write { db in
            var p = position
            try p.insert(db)
        }
    }

    /// Latest position per node.
    public func getLatestPerNode() -> AsyncValueObservation<[NodePosition]> {
        ValueObservation.tracking { db in
            try NodePosition.fetchAll(
                db,
                sql: """
                    SELECT * FROM node_positions
                    WHERE id IN (SELECT MAX(id) FROM node_positions GROUP BY nodeId)
                    ORDER BY timestamp DESC
                    """)
        }.values(in: db)
    }

    public func getByNode(_ nodeId: Int64, limit: Int = 100) -> AsyncValueObservation<[NodePosition]> {
        ValueObservation.tracking { db in
            try NodePosition.fetchAll(
                db, sql: "SELECT * FROM node_positions WHERE nodeId = ? ORDER BY timestamp DESC LIMIT ?", arguments: [nodeId, limit])
        }.values(in: db)
    }

    /// All recent positions across nodes (for track lines).
    public func getAllRecentByNode(limit: Int = 500) async throws -> [NodePosition] {
        try await db.read { db in
            try NodePosition.fetchAll(
                db, sql: "SELECT * FROM node_positions WHERE nodeId != 0 ORDER BY nodeId, timestamp ASC LIMIT ?", arguments: [limit])
        }
    }

    /// Mirrors map/MapTracks.kt loadRecentTracks: the newest `maxPoints` positions since `sinceMs`,
    /// oldest first, without the phone's own rows (node 0), for the map's track lines (B17).
    public func getRecentTracks(sinceMs: Int64, maxPoints: Int) async throws -> [NodePosition] {
        try await db.read { db in
            try NodePosition.fetchAll(
                db, sql: "SELECT * FROM node_positions WHERE nodeId != 0 AND timestamp >= ? ORDER BY timestamp DESC LIMIT ?",
                arguments: [sinceMs, maxPoints]
            ).reversed()
        }
    }

    /// Most recent position across all nodes (for the dead-man switch).
    public func getLatest() async throws -> NodePosition? {
        try await db.read { db in try NodePosition.fetchOne(db, sql: "SELECT * FROM node_positions ORDER BY timestamp DESC LIMIT 1") }
    }

    public func deleteBefore(_ before: Int64) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM node_positions WHERE timestamp < ?", arguments: [before]) }
    }
}

public struct ConversationKeyDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() -> AsyncValueObservation<[ConversationKey]> {
        ValueObservation.tracking { db in try ConversationKey.fetchAll(db, sql: "SELECT * FROM conversation_keys ORDER BY sender ASC") }
            .values(in: db)
    }

    public func getBySender(_ sender: String) async throws -> ConversationKey? {
        try await db.read { db in
            try ConversationKey.fetchOne(db, sql: "SELECT * FROM conversation_keys WHERE sender = ? LIMIT 1", arguments: [sender])
        }
    }

    public func upsert(_ key: ConversationKey) async throws {
        try await db.write { db in try key.upsert(db) }
    }

    public func deleteBySender(_ sender: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM conversation_keys WHERE sender = ?", arguments: [sender]) }
    }
}

public struct AccessRuleDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() -> AsyncValueObservation<[AccessRule]> {
        ValueObservation.tracking { db in try AccessRule.fetchAll(db, sql: "SELECT * FROM access_rules ORDER BY priority ASC, id ASC") }
            .values(in: db)
    }

    public func getAllSync() async throws -> [AccessRule] {
        try await db.read { db in try AccessRule.fetchAll(db, sql: "SELECT * FROM access_rules ORDER BY priority ASC, id ASC") }
    }

    public func getByInterfaceAndDirection(_ interfaceId: String, _ direction: String) async throws -> [AccessRule] {
        try await db.read { db in
            try AccessRule.fetchAll(
                db, sql: "SELECT * FROM access_rules WHERE interface_id = ? AND direction = ? ORDER BY priority ASC, id ASC",
                arguments: [interfaceId, direction])
        }
    }

    public func getById(_ id: Int64) async throws -> AccessRule? {
        try await db.read { db in try AccessRule.fetchOne(db, sql: "SELECT * FROM access_rules WHERE id = ?", arguments: [id]) }
    }

    @discardableResult
    public func insert(_ rule: AccessRule) async throws -> Int64 {
        try await db.write { db in
            var r = rule
            try r.insert(db)
            return r.id ?? 0
        }
    }

    public func update(_ rule: AccessRule) async throws {
        try await db.write { db in try rule.update(db) }
    }

    public func deleteById(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM access_rules WHERE id = ?", arguments: [id]) }
    }

    public func recordMatch(id: Int64, timestamp: String) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE access_rules SET match_count = match_count + 1, last_match_at = ? WHERE id = ?", arguments: [timestamp, id])
        }
    }

    public func deleteAll() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM access_rules") }
    }
}

public struct ObjectGroupDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() async throws -> [ObjectGroup] {
        try await db.read { db in try ObjectGroup.fetchAll(db, sql: "SELECT * FROM object_groups ORDER BY id") }
    }

    public func getById(_ id: String) async throws -> ObjectGroup? {
        try await db.read { db in try ObjectGroup.fetchOne(db, sql: "SELECT * FROM object_groups WHERE id = ?", arguments: [id]) }
    }

    public func upsert(_ group: ObjectGroup) async throws {
        try await db.write { db in try group.upsert(db) }
    }

    public func deleteById(_ id: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM object_groups WHERE id = ?", arguments: [id]) }
    }

    public func deleteAll() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM object_groups") }
    }
}

public struct FailoverGroupDao: Sendable {
    let db: any DatabaseWriter

    public func getAllGroups() async throws -> [FailoverGroup] {
        try await db.read { db in try FailoverGroup.fetchAll(db, sql: "SELECT * FROM failover_groups ORDER BY id") }
    }

    public func getGroup(_ id: String) async throws -> FailoverGroup? {
        try await db.read { db in try FailoverGroup.fetchOne(db, sql: "SELECT * FROM failover_groups WHERE id = ?", arguments: [id]) }
    }

    public func upsertGroup(_ group: FailoverGroup) async throws {
        try await db.write { db in try group.upsert(db) }
    }

    public func deleteGroup(_ id: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM failover_groups WHERE id = ?", arguments: [id]) }
    }

    public func getMembers(_ groupId: String) async throws -> [FailoverMember] {
        try await db.read { db in
            try FailoverMember.fetchAll(
                db, sql: "SELECT * FROM failover_members WHERE group_id = ? ORDER BY priority ASC", arguments: [groupId])
        }
    }

    public func upsertMember(_ member: FailoverMember) async throws {
        try await db.write { db in try member.upsert(db) }
    }

    public func deleteMember(groupId: String, interfaceId: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM failover_members WHERE group_id = ? AND interface_id = ?", arguments: [groupId, interfaceId])
        }
    }

    public func deleteAllMembers(_ groupId: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM failover_members WHERE group_id = ?", arguments: [groupId]) }
    }

    public func deleteAllMembersGlobal() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM failover_members") }
    }

    public func deleteAllGroups() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM failover_groups") }
    }
}

public struct AuditLogDao: Sendable {
    let db: any DatabaseWriter

    @discardableResult
    public func insert(_ entry: AuditLogEntry) async throws -> Int64 {
        try await db.write { db in
            var e = entry
            try e.insert(db)
            return e.id ?? 0
        }
    }

    /// Newest first.
    public func getRecent(limit: Int = 100) async throws -> [AuditLogEntry] {
        try await db.read { db in
            try AuditLogEntry.fetchAll(db, sql: "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", arguments: [limit])
        }
    }

    public func getByInterface(_ interfaceId: String, limit: Int = 100) async throws -> [AuditLogEntry] {
        try await db.read { db in
            try AuditLogEntry.fetchAll(
                db, sql: "SELECT * FROM audit_log WHERE interface_id = ? ORDER BY id DESC LIMIT ?", arguments: [interfaceId, limit])
        }
    }

    public func count() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_log") ?? 0 }
    }
}

public struct TleCacheDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() async throws -> [TleCacheEntry] {
        try await db.read { db in try TleCacheEntry.fetchAll(db, sql: "SELECT * FROM tle_cache ORDER BY satelliteName") }
    }

    public func getOldestFetchTime() async throws -> Int64? {
        try await db.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(fetchedAt) FROM tle_cache") }
    }

    public func deleteAll() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM tle_cache") }
    }

    public func insertAll(_ entries: [TleCacheEntry]) async throws {
        try await db.write { db in
            for entry in entries {
                var e = entry
                try e.insert(db)
            }
        }
    }
}

public struct ProviderCredentialDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() -> AsyncValueObservation<[ProviderCredential]> {
        ValueObservation.tracking { db in
            try ProviderCredential.fetchAll(db, sql: "SELECT * FROM provider_credentials ORDER BY provider, name")
        }.values(in: db)
    }

    public func getById(_ id: String) async throws -> ProviderCredential? {
        try await db.read { db in
            try ProviderCredential.fetchOne(db, sql: "SELECT * FROM provider_credentials WHERE id = ? LIMIT 1", arguments: [id])
        }
    }

    public func getByProvider(_ provider: String) async throws -> [ProviderCredential] {
        try await db.read { db in
            try ProviderCredential.fetchAll(db, sql: "SELECT * FROM provider_credentials WHERE provider = ?", arguments: [provider])
        }
    }

    public func upsert(_ credential: ProviderCredential) async throws {
        try await db.write { db in try credential.upsert(db) }
    }

    public func deleteById(_ id: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM provider_credentials WHERE id = ?", arguments: [id]) }
    }

    public func count() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_credentials") ?? 0 }
    }
}

public struct RnsTcpPeerDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() -> AsyncValueObservation<[RnsTcpPeer]> {
        ValueObservation.tracking { db in try RnsTcpPeer.fetchAll(db, sql: "SELECT * FROM rns_tcp_peers ORDER BY label, host") }.values(
            in: db)
    }

    public func getEnabled() async throws -> [RnsTcpPeer] {
        try await db.read { db in try RnsTcpPeer.fetchAll(db, sql: "SELECT * FROM rns_tcp_peers WHERE enabled = 1") }
    }

    public func upsert(_ peer: RnsTcpPeer) async throws {
        try await db.write { db in
            var p = peer
            if p.id == nil {
                try p.insert(db)
            } else {
                try p.upsert(db)
            }
        }
    }

    public func delete(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM rns_tcp_peers WHERE id = ?", arguments: [id]) }
    }

    public func count() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rns_tcp_peers") ?? 0 }
    }
}

public struct IridiumCreditDao: Sendable {
    let db: any DatabaseWriter

    public func insert(_ entry: IridiumCreditEntry) async throws {
        try await db.write { db in
            var e = entry
            try e.insert(db)
        }
    }

    public func totalCostCents() async throws -> Int? {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT SUM(costCents) FROM iridium_credit_log") }
    }

    public func costSince(_ since: Int64) async throws -> Int? {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT SUM(costCents) FROM iridium_credit_log WHERE timestamp > ?", arguments: [since])
        }
    }

    public func messagesSince(_ since: Int64) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM iridium_credit_log WHERE timestamp > ?", arguments: [since]) ?? 0
        }
    }

    public func getRecent(limit: Int = 50) -> AsyncValueObservation<[IridiumCreditEntry]> {
        ValueObservation.tracking { db in
            try IridiumCreditEntry.fetchAll(db, sql: "SELECT * FROM iridium_credit_log ORDER BY timestamp DESC LIMIT ?", arguments: [limit])
        }.values(in: db)
    }
}

public struct HembBondGroupDao: Sendable {
    let db: any DatabaseWriter

    public func getAll() async throws -> [HembBondGroup] {
        try await db.read { db in try HembBondGroup.fetchAll(db, sql: "SELECT * FROM hemb_bond_groups ORDER BY createdAt ASC") }
    }

    public func getById(_ id: String) async throws -> HembBondGroup? {
        try await db.read { db in try HembBondGroup.fetchOne(db, sql: "SELECT * FROM hemb_bond_groups WHERE id = ?", arguments: [id]) }
    }

    public func insert(_ group: HembBondGroup) async throws {
        try await db.write { db in try group.upsert(db) }
    }

    public func delete(_ id: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM hemb_bond_groups WHERE id = ?", arguments: [id]) }
    }
}

public struct BridgeTrustDao: Sendable {
    let db: any DatabaseWriter

    public func get(_ hash: String) async throws -> BridgeTrust? {
        try await db.read { db in try BridgeTrust.fetchOne(db, sql: "SELECT * FROM bridge_trust WHERE bridgeHash = ?", arguments: [hash]) }
    }

    public func getAll() async throws -> [BridgeTrust] {
        try await db.read { db in try BridgeTrust.fetchAll(db, sql: "SELECT * FROM bridge_trust ORDER BY lastSeen DESC") }
    }

    public func upsert(_ entity: BridgeTrust) async throws {
        try await db.write { db in try entity.upsert(db) }
    }

    public func delete(_ hash: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM bridge_trust WHERE bridgeHash = ?", arguments: [hash]) }
    }

    public func count() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_trust") ?? 0 }
    }
}

public struct TelemetryDao: Sendable {
    let db: any DatabaseWriter

    @discardableResult
    public func insert(_ entry: TelemetryEntry) async throws -> Int64 {
        try await db.write { db in
            var e = entry
            try e.insert(db)
            return e.id ?? 0
        }
    }

    public func getByType(_ type: String, limit: Int) async throws -> [TelemetryEntry] {
        try await db.read { db in
            try TelemetryEntry.fetchAll(
                db, sql: "SELECT * FROM telemetry WHERE type = ? ORDER BY timestamp DESC LIMIT ?", arguments: [type, limit])
        }
    }

    public func getRecent(limit: Int) async throws -> [TelemetryEntry] {
        try await db.read { db in
            try TelemetryEntry.fetchAll(db, sql: "SELECT * FROM telemetry ORDER BY timestamp DESC LIMIT ?", arguments: [limit])
        }
    }

    public func getSince(id sinceId: Int64, limit: Int) async throws -> [TelemetryEntry] {
        try await db.read { db in
            try TelemetryEntry.fetchAll(
                db, sql: "SELECT * FROM telemetry WHERE id > ? ORDER BY timestamp DESC LIMIT ?", arguments: [sinceId, limit])
        }
    }

    public func countByType(_ type: String) async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE type = ?", arguments: [type]) ?? 0 }
    }

    public func count() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry") ?? 0 }
    }

    /// Trim the oldest rows of a type, keeping the most recent `keep`.
    public func trimType(_ type: String, keep: Int) async throws {
        try await db.write { db in
            try db.execute(
                sql: """
                    DELETE FROM telemetry
                    WHERE type = ?
                    AND id NOT IN (
                        SELECT id FROM telemetry WHERE type = ? ORDER BY timestamp DESC LIMIT ?
                    )
                    """,
                arguments: [type, type, keep])
        }
    }

    public func deleteAll() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM telemetry") }
    }

    public func deleteByType(_ type: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM telemetry WHERE type = ?", arguments: [type]) }
    }
}
