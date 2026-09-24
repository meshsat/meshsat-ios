// The record and settings contracts with MeshSat Android: column names, table-level defaults
// and setting keys are spelled the same, so the DAOs' SQL and a settings export are shared.
import Foundation
import MeshSatEngine
import XCTest

final class RecordsAndSettingsTests: XCTestCase {
    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    func testDeliveryColumnsAreAndroids() throws {
        let d = MessageDelivery(msgRef: "sos:1:a", channel: "sms_0", createdAt: 1, updatedAt: 1, recipient: "+31612345678")
        let cols = try keys(d)
        for expected in [
            "msg_ref", "channel", "status", "priority", "text_preview", "retries", "max_retries", "last_error", "visited",
            "ttl_seconds", "qos_level", "seq_num", "created_at", "updated_at", "recipient", "sat_ref", "origin",
        ] {
            XCTAssertTrue(cols.contains(expected), expected)
        }
        XCTAssertFalse(cols.contains("msgRef"))
        XCTAssertEqual(d.status, "queued")
        XCTAssertEqual(d.maxRetries, 3)
        XCTAssertEqual(d.qosLevel, 1)
        XCTAssertEqual(MessageDelivery.runawaySafetyLimit, 120)
    }

    func testOtherSnakeCaseColumns() throws {
        XCTAssertTrue(
            try keys(AccessRule(interfaceId: "mesh_0", direction: "ingress", name: "all", filterNodeGroup: "g")).isSuperset(of: [
                "interface_id", "forward_to", "filter_node_group", "forward_options", "qos_level", "rate_limit_per_min", "match_count",
            ]))
        XCTAssertTrue(
            try keys(Contact(fingerprint: "f", name: "n", signingPub: "p")).isSuperset(of: [
                "signing_pub", "mesh_node_id", "bridge_id", "issued_at", "added_at",
            ]))
        XCTAssertTrue(try keys(AuditLogEntry(timestamp: "t", eventType: "e")).isSuperset(of: ["event_type", "prev_hash", "hash"]))
        XCTAssertTrue(try keys(FailoverMember(groupId: "g", interfaceId: "i", priority: 1)).isSuperset(of: ["group_id", "interface_id"]))
        XCTAssertTrue(
            try keys(
                ProviderCredential(
                    id: "i", provider: "p", name: "n", credType: "c", encryptedData: Data(), certNotAfter: "x", receivedAt: 0)
            )
            .isSuperset(of: ["cred_type", "encrypted_data", "cert_not_after", "cert_subject", "cert_fingerprint", "received_at"]))
        // Room's camelCase columns stay camelCase.
        XCTAssertTrue(
            try keys(MessageRecord(timestamp: 1, transport: "mesh", direction: "rx", sender: "!1", text: "hi")).isSuperset(of: [
                "rawText", "forwardedTo",
            ]))
        XCTAssertTrue(try keys(TleCacheEntry(satelliteName: "s", line1: "1", line2: "2", fetchedAt: 0)).contains("satelliteName"))
    }

    func testSettingsKeysAreAndroids() {
        XCTAssertEqual(SettingsKey.meshtasticBleAddress.key, "meshtastic_ble_address")
        XCTAssertEqual(SettingsKey.iridiumNodePipeEnabled.key, "iridium_node_pipe_enabled")
        XCTAssertTrue(SettingsKey.iridiumNodePipeEnabled.defaultValue)
        XCTAssertEqual(SettingsKey.msvqscStages.defaultValue, "3")
        XCTAssertEqual(SettingsKey.deadmanTimeoutMin.defaultValue, "120")
        XCTAssertEqual(SettingsKey.aprsIsServer.defaultValue, "rotate.aprs2.net")
        XCTAssertEqual(SettingsKey.compress(channel: "sms")?.key, "compress_sms")
        XCTAssertNil(SettingsKey.compress(channel: "tak"))
        XCTAssertTrue(SettingsKey.hubRelayEnabled.defaultValue)
        XCTAssertEqual(SettingsKey.hubHealthInterval.defaultValue, "30")
        XCTAssertEqual(SettingsKey.takCallsignPrefix.defaultValue, "MESHSAT")
        XCTAssertEqual(SecretKey.routingSigningPrivate, "routing_signing_key_private")
        XCTAssertEqual(SecretKey.hubClientKeyPem, "hub_client_key_pem")
    }

    func testMemoryKeyValueStore() {
        let store = MemoryKeyValueStore()
        XCTAssertFalse(store.contains(SecretKey.encryptionKey))
        store.set(SecretKey.encryptionKey, "00ff")
        XCTAssertEqual(store.get(SecretKey.encryptionKey), "00ff")
        store.remove(SecretKey.encryptionKey)
        XCTAssertNil(store.get(SecretKey.encryptionKey))
    }
}
