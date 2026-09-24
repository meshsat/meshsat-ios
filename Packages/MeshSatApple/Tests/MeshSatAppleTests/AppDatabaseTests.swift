// The store against an in-memory database: the schema opens, the DAOs' SQL runs, and the
// queries with rules in them (conversations, pending, hold/unhold) answer as Android's do.
import Foundation
import GRDB
import MeshSatEngine
import MeshSatStore
import XCTest

final class AppDatabaseTests: XCTestCase {
    func testSchemaHasAndroidsTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { db in
            try String.fetchAll(
                db,
                sql:
                    """
                    SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                    ORDER BY name
                    """
            )
        }
        XCTAssertEqual(
            tables,
            [
                "access_rules", "audit_log", "bridge_trust", "contacts", "conversation_keys", "failover_groups", "failover_members",
                "forwarding_rules", "hemb_bond_groups", "iridium_credit_log", "message_deliveries", "messages", "node_positions",
                "object_groups", "provider_credentials", "rns_tcp_peers", "signal_history", "telemetry", "tle_cache",
            ])
        let columns = try db.writer.read { db in try db.columns(in: "message_deliveries").map(\.name) }
        XCTAssertTrue(columns.contains("sat_ref"))
        XCTAssertTrue(columns.contains("origin"))
        XCTAssertEqual(columns.count, 28)
    }

    func testMessagesAndConversations() async throws {
        let db = try AppDatabase.inMemory()
        let dao = db.messages
        let a = try await dao.insert(MessageRecord(timestamp: 1000, transport: "mesh", direction: "rx", sender: "!4370c1d8", text: "hello"))
        XCTAssertEqual(a, 1)
        try await dao.insert(
            MessageRecord(
                timestamp: 2000, transport: "mesh", direction: "tx", sender: "self", recipient: "!4370c1d8", text: "hi back",
                encrypted: true))
        try await dao.insert(
            MessageRecord(timestamp: 1500, transport: "iridium", direction: "tx", sender: "self", recipient: "hub", text: "sat"))
        let conversations = try await dao.conversations()
        XCTAssertEqual(conversations.map(\.sender), ["!4370c1d8", "hub"], "sent messages file under the recipient, newest first")
        XCTAssertEqual(conversations.first?.lastMessage, "hi back")
        XCTAssertEqual(conversations.first?.messageCount, 2)
        XCTAssertEqual(conversations.first?.hasEncrypted, true)
        XCTAssertEqual(conversations.last?.hasEncrypted, false)
        let count = try await dao.countByTransportSince("mesh", since: 1200)
        XCTAssertEqual(count, 1)

        try await dao.setForwardedTo(id: 3, "iridium:delivered")
        try await dao.setForwardedToUnlessDelivered(id: 3, "iridium:sbd")
        let recent = try await db.writer.read { db in try MessageRecord.fetchAll(db, sql: "SELECT * FROM messages WHERE id = 3") }
        XCTAssertEqual(recent.first?.forwardedTo, "iridium:delivered", "a receipt is never overwritten by a late 'sent'")
    }

    func testDeliveriesPendingHoldAndUnhold() async throws {
        let db = try AppDatabase.inMemory()
        let dao = db.deliveries
        let now: Int64 = 10_000
        let id = try await dao.insert(
            MessageDelivery(
                msgRef: "msg:1", channel: "iridium_0", payload: Data([1, 2, 3]), expiresAt: now + 5000, createdAt: now, updatedAt: now))
        try await dao.insert(
            MessageDelivery(msgRef: "sos:7:a", channel: "sms_0", priority: 0, createdAt: now, updatedAt: now, recipient: "+31612345678"))
        try await dao.insert(
            MessageDelivery(msgRef: "msg:2", channel: "iridium_0", nextRetry: now + 60_000, createdAt: now, updatedAt: now))

        var pending = try await dao.getPending(channel: "iridium_0", now: now)
        XCTAssertEqual(pending.map(\.msgRef), ["msg:1"], "a retry that is not due yet waits")
        let depth = try await dao.queueDepth(channel: "iridium_0")
        XCTAssertEqual(depth, 2)
        let bytes = try await dao.queueBytes(channel: "iridium_0")
        XCTAssertEqual(bytes, 3)

        let held = try await dao.holdForChannel("iridium_0", now: now + 1000)
        XCTAssertEqual(held, 2)
        pending = try await dao.getPending(channel: "iridium_0", now: now + 1000)
        XCTAssertTrue(pending.isEmpty)
        let released = try await dao.unholdForChannel("iridium_0", now: now + 4000)
        XCTAssertEqual(released, 2)
        let first = try await dao.getById(id)
        XCTAssertEqual(first?.expiresAt, now + 5000 + 3000, "the TTL clock paused while held")
        XCTAssertEqual(first?.status, "queued")
        XCTAssertNil(first?.heldAt)

        let sos = try await dao.getByRefPrefix("sos:7:")
        XCTAssertEqual(sos.count, 1)
        XCTAssertEqual(sos.first?.recipient, "+31612345678")
        let cancelled = try await dao.cancelWaitingByRefPrefix("sos:7:", now: now + 5000)
        XCTAssertEqual(cancelled, 1)
        let again = try await dao.cancelWaitingByRefPrefix("sos:7:", now: now + 5000)
        XCTAssertEqual(again, 0)

        try await dao.setSatRef(id: id, "300234010753370:219")
        let acked = try await dao.markAckedBySatRef("300234010753370:219", now: now + 9000)
        XCTAssertEqual(acked, 1)
        let stats = try await dao.stats()
        XCTAssertEqual(stats.map { "\($0.channel)/\($0.status)/\($0.cnt)" }, ["iridium_0/queued/1", "iridium_0/retry/1", "sms_0/dead/1"])
    }

    func testContactsAndKeysUpsert() async throws {
        let db = try AppDatabase.inMemory()
        try await db.contacts.upsert(Contact(fingerprint: "ab", name: "zed", signingPub: "p1", trust: "SCANNED"))
        try await db.contacts.upsert(Contact(fingerprint: "ab", name: "Anna", signingPub: "p1"))
        try await db.contacts.upsert(Contact(fingerprint: "cd", name: "bob", signingPub: "p2"))
        let all = try await db.contacts.getAll()
        XCTAssertEqual(all.map(\.name), ["Anna", "bob"], "the same key replaces the row; sorted without case")
        try await db.conversationKeys.upsert(ConversationKey(sender: "+31", hexKey: "00", label: "a"))
        try await db.conversationKeys.upsert(ConversationKey(sender: "+31", hexKey: "ff"))
        let key = try await db.conversationKeys.getBySender("+31")
        XCTAssertEqual(key?.hexKey, "ff")
        try await db.bridgeTrust.upsert(
            BridgeTrust(bridgeHash: "h", pubkey: Data(repeating: 7, count: 32), firstSeen: 1, lastSeen: 2, label: "kit", importCount: 1))
        let trust = try await db.bridgeTrust.get("h")
        XCTAssertEqual(trust?.pubkey.count, 32)
    }

    func testTelemetryTrimAndPositions() async throws {
        let db = try AppDatabase.inMemory()
        for i in 0..<10 {
            try await db.telemetry.insert(
                TelemetryEntry(timestamp: Int64(i), type: "heap", tag: "t", severity: "sample", message: "m", detail: "{}"))
        }
        try await db.telemetry.trimType("heap", keep: 3)
        let kept = try await db.telemetry.getByType("heap", limit: 10)
        XCTAssertEqual(kept.map(\.timestamp), [9, 8, 7])

        try await db.nodePositions.insert(NodePosition(timestamp: 1, nodeId: 5, latitude: 52, longitude: 4))
        try await db.nodePositions.insert(NodePosition(timestamp: 2, nodeId: 5, latitude: 52.1, longitude: 4.1))
        try await db.nodePositions.insert(NodePosition(timestamp: 3, nodeId: 6, latitude: 51, longitude: 3))
        let latest = try await db.nodePositions.getLatest()
        XCTAssertEqual(latest?.nodeId, 6)
        var perNode: [NodePosition] = []
        for try await rows in db.nodePositions.getLatestPerNode() {
            perNode = rows
            break
        }
        XCTAssertEqual(perNode.map(\.nodeId), [6, 5])
        XCTAssertEqual(perNode.last?.latitude, 52.1)
    }

    func testSettingsRepositoryKeysAndSecrets() {
        let suite = "net.meshsat.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = SettingsRepository(defaults: defaults, secure: MemoryKeyValueStore())
        XCTAssertTrue(repo.get(SettingsKey.iridiumNodePipeEnabled))
        XCTAssertEqual(repo.get(SettingsKey.msvqscStages), "3")
        repo.set(SettingsKey.iridiumNodePipeEnabled, false)
        XCTAssertFalse(repo.get(SettingsKey.iridiumNodePipeEnabled))
        XCTAssertEqual(defaults.object(forKey: "iridium_node_pipe_enabled") as? Bool, false, "stored under Android's key")
        repo.setMeshtasticBleAddress("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        repo.clearMeshtasticBleAddress()
        XCTAssertEqual(repo.meshtasticBleAddress, "")
        repo.setSosContacts([EmergencyContact(name: "Anna", phone: "+31612345678")])
        XCTAssertEqual(repo.sosContacts.first?.phone, "+31612345678")
        repo.setHubPassword("s3cret")
        XCTAssertNil(defaults.string(forKey: "hub_password"), "a secret never lands in UserDefaults")
        XCTAssertEqual(repo.hubPassword, "s3cret")
        repo.setCompressMode(channel: "sms", "msvqsc")
        XCTAssertEqual(repo.compressMode(channel: "sms"), "msvqsc")
        XCTAssertEqual(repo.compressMode(channel: "tak"), "off")
    }
}
