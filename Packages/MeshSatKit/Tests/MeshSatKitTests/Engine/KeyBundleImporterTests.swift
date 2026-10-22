// A kit's meshsat://key/ bundle on iOS (MESHSAT-1631), against bundles made by the Bridge's own
// keystore (Fixtures/keybundle/bridge_bundles.json) and ones signed here. Mirrors
// KeyBundleImporterTest.kt.
import Crypto
import Foundation
import XCTest

@testable import MeshSatEngine

final class MemKeyBundleStore: KeyBundleStore, @unchecked Sendable {
    private let lock = NSLock()
    private var trusts: [String: BridgeTrust] = [:]
    private var keys: [String: ConversationKey] = [:]
    private var creds: [String: ProviderCredential] = [:]

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }
    func trust(_ bridgeHash: String) async throws -> BridgeTrust? { locked { trusts[bridgeHash] } }
    func upsertTrust(_ trust: BridgeTrust) async throws { locked { trusts[trust.bridgeHash] = trust } }
    func upsertConversationKey(_ key: ConversationKey) async throws { locked { keys[key.sender] = key } }
    func upsertCredential(_ credential: ProviderCredential) async throws { locked { creds[credential.id] = credential } }
    func key(_ sender: String) -> String? { locked { keys[sender]?.hexKey } }
    func pinned(_ hash: String) -> BridgeTrust? { locked { trusts[hash] } }
    var credentialIds: Set<String> { locked { Set(creds.keys) } }
    var keyCount: Int { locked { keys.count } }
}

final class KeyBundleImporterTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "bridge_bundles", withExtension: "json", subdirectory: "Fixtures/keybundle"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func bytes(_ url: String) -> [UInt8] {
        KeyBundleImporter.base64URL(String(url.dropFirst(KeyBundleImporter.urlPrefix.count))) ?? []
    }

    private func url(_ b: [UInt8]) -> String {
        KeyBundleImporter.urlPrefix
            + Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    struct Entry {
        let type: UInt8
        let address: String
        let fill: UInt8
    }

    /// A v2 bundle for `hash`, signed by `key` (or carrying `claimed` as its key while signed by `key`).
    private func v2(
        hash: [UInt8], key: Curve25519.Signing.PrivateKey, claimed: [UInt8]? = nil, entries: [Entry]
    ) throws -> [UInt8] {
        var head: [UInt8] = [0x02] + hash + [0, 0, 0, 1, UInt8(entries.count)]
        head += claimed ?? Array(key.publicKey.rawRepresentation)
        var body: [UInt8] = []
        for e in entries {
            body += [e.type, UInt8(e.address.utf8.count)] + Array(e.address.utf8) + [UInt8](repeating: e.fill, count: 32)
        }
        let sig = try key.signature(for: Data(head + body))
        return head + Array(sig) + body
    }

    private let hashA = [UInt8](repeating: 0xA0, count: 16)

    func testTheBridgesV2BundlePinsItsKeyAndKeepsEachChannelsKey() async throws {
        let f = try fixture()
        let store = MemKeyBundleStore()
        let r = await KeyBundleImporter.importFromURL(try XCTUnwrap(f["v2_url"] as? String), store: store, now: 1000)
        XCTAssertEqual(r, .success(count: 4, status: .newTrusted, bridgeHashHex: try XCTUnwrap(f["bridge_hash"] as? String)))
        let pin = try XCTUnwrap(store.pinned(try XCTUnwrap(f["bridge_hash"] as? String)))
        XCTAssertEqual(KeyBundleImporter.hex(pin.pubkey), f["signing_pub"] as? String)
        XCTAssertEqual(pin.importCount, 1)
        XCTAssertEqual(store.key("iridium:shared"), String(repeating: "22", count: 32))
        XCTAssertEqual(store.key("mesh:shared"), String(repeating: "11", count: 32))
        XCTAssertEqual(store.key("shared"), String(repeating: "22", count: 32), "the address row: the last entry wins, as on Android")
        XCTAssertEqual(store.key("sms:+31600000001"), String(repeating: "33", count: 32))
        XCTAssertEqual(store.key("MSTEST-10"), String(repeating: "44", count: 32))
        XCTAssertNil(store.key("unknown:MSTEST-10"), "a channel Android does not name gets no channel row")
        // Android's credential ids for the same bundle (Java's String hash).
        XCTAssertEqual(
            store.credentialIds,
            ["a0a1a2a3_mesh_-35db539b", "a0a1a2a3_iridium_-35db539b", "a0a1a2a3_sms_-49147372", "a0a1a2a3_unknown_1c9940d4"])

        let again = await KeyBundleImporter.importFromURL(try XCTUnwrap(f["v2_url"] as? String), store: store, now: 2000)
        XCTAssertEqual(again, .success(count: 4, status: .existingTrusted, bridgeHashHex: pin.bridgeHash))
        XCTAssertEqual(store.pinned(pin.bridgeHash)?.importCount, 2)
        XCTAssertEqual(store.pinned(pin.bridgeHash)?.lastSeen, 2000)
    }

    func testTheBridgesV1BundleIsImportedUnverified() async throws {
        let f = try fixture()
        let store = MemKeyBundleStore()
        let r = await KeyBundleImporter.importFromURL(try XCTUnwrap(f["v1_url"] as? String), store: store)
        XCTAssertEqual(r, .success(count: 1, status: .unverifiedV1, bridgeHashHex: try XCTUnwrap(f["bridge_hash"] as? String)))
        XCTAssertNil(store.pinned(try XCTUnwrap(f["bridge_hash"] as? String)), "v1 pins nothing")
    }

    func testATamperedBundleOrASwappedKeyIsRefused() async throws {
        let f = try fixture()
        var b = bytes(try XCTUnwrap(f["v2_url"] as? String))
        b[b.count - 1] ^= 0x01
        let store = MemKeyBundleStore()
        guard case .invalidSignature = await KeyBundleImporter.importFromURL(url(b), store: store) else {
            return XCTFail("a changed key byte was taken")
        }
        var swapped = bytes(try XCTUnwrap(f["v2_url"] as? String))
        let other = Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        swapped.replaceSubrange(22..<54, with: other)
        guard case .invalidSignature = await KeyBundleImporter.importFromURL(url(swapped), store: store) else {
            return XCTFail("another key in the header was taken")
        }
        let k = Curve25519.Signing.PrivateKey()
        let forged = try v2(
            hash: hashA, key: Curve25519.Signing.PrivateKey(), claimed: Array(k.publicKey.rawRepresentation),
            entries: [Entry(type: 0x02, address: "shared", fill: 0x55)])
        guard case .invalidSignature = await KeyBundleImporter.importFromURL(url(forged), store: store) else {
            return XCTFail("a signature by another key was taken")
        }
        XCTAssertEqual(store.keyCount, 0)
    }

    func testAnotherKeyForAPinnedBridgeNeedsTheUsersYes() async throws {
        let store = MemKeyBundleStore()
        let first = Curve25519.Signing.PrivateKey()
        let second = Curve25519.Signing.PrivateKey()
        _ = await KeyBundleImporter.importFromURL(
            url(try v2(hash: hashA, key: first, entries: [Entry(type: 0x02, address: "shared", fill: 0x01)])), store: store)
        let rotated = url(try v2(hash: hashA, key: second, entries: [Entry(type: 0x02, address: "shared", fill: 0x02)]))
        let r = await KeyBundleImporter.importFromURL(rotated, store: store, now: 5)
        guard case .keyMismatch(_, let stored, let presented, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(stored, first.publicKey.rawRepresentation)
        XCTAssertEqual(presented, second.publicKey.rawRepresentation)
        XCTAssertEqual(store.key("iridium:shared"), String(repeating: "01", count: 32), "nothing imported on a mismatch")

        let forced = await KeyBundleImporter.importFromURL(rotated, store: store, forceRepin: true, now: 6)
        guard case .success(1, .newTrusted, _) = forced else { return XCTFail("\(forced)") }
        XCTAssertEqual(store.pinned(KeyBundleImporter.hex(hashA))?.pubkey, second.publicKey.rawRepresentation)
        XCTAssertEqual(store.key("iridium:shared"), String(repeating: "02", count: 32))
    }

    func testMalformedInputIsRefused() async throws {
        let store = MemKeyBundleStore()
        guard case .malformed = await KeyBundleImporter.importFromURL("https://meshsat.net", store: store) else {
            return XCTFail("taken, not refused")
        }
        guard case .malformed = await KeyBundleImporter.importFromURL(url([0x02, 0x01]), store: store) else {
            return XCTFail("taken, not refused")
        }
        guard case .malformed = await KeyBundleImporter.importFromURL(url([0x03] + [UInt8](repeating: 0, count: 120)), store: store)
        else { return XCTFail("taken, not refused") }
        // A v2 header that promises more entries than it carries.
        var short = try v2(hash: hashA, key: Curve25519.Signing.PrivateKey(), entries: [Entry(type: 0x02, address: "shared", fill: 0x01)])
        short[21] = 2
        let r = await KeyBundleImporter.importFromURL(url(short), store: store)
        guard case .invalidSignature = r else { return XCTFail("\(r)") }  // the count is signed too
    }

    func testJavaStringHash() {
        XCTAssertEqual(KeyBundleImporter.javaHashHex("shared"), "-35db539b")
        XCTAssertEqual(KeyBundleImporter.javaHashHex("+31600000001"), "-49147372")
        XCTAssertEqual(KeyBundleImporter.javaHashHex("MSTEST-10"), "1c9940d4")
        XCTAssertEqual(KeyBundleImporter.javaHashHex("Καλη😀"), "5b340d96", "UTF-16 units, a surrogate pair included")
    }
}
