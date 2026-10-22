// Mirrors crypto/KeyBundleImporter.kt (MESHSAT-495): a kit's `meshsat://key/` QR code, the signed
// bundle of its channel keys. MESHSAT-1631.
//
// v1 (legacy, 86-byte header): no signing key inside, so the signature cannot be checked here;
// the keys are imported and the result says UNVERIFIED.
//   Version(1)=0x01 | BridgeHash(16) | Timestamp(4) | EntryCount(1) | Signature(64)
// v2 (118-byte header): the Ed25519 signing key is inside the signed bytes, pinned on first use
// per bridge hash (bridge_trust); a later bundle must verify under the pinned key.
//   Version(1)=0x02 | BridgeHash(16) | Timestamp(4) | EntryCount(1) | SigningPubkey(32) | Signature(64)
// Each entry: ChannelType(1) | AddrLen(1) | Address(N) | AESKey(32). The signature covers every
// byte but its own 64.
import Crypto
import Foundation

/// What an import writes, the app's database in the app and a fake in the tests.
public protocol KeyBundleStore: Sendable {
    func trust(_ bridgeHash: String) async throws -> BridgeTrust?
    func upsertTrust(_ trust: BridgeTrust) async throws
    func upsertConversationKey(_ key: ConversationKey) async throws
    func upsertCredential(_ credential: ProviderCredential) async throws
}

public enum KeyBundleImporter {
    public static let urlPrefix = "meshsat://key/"

    static let v1HeaderSize = 86
    static let v2PubkeyOffset = 22
    static let v2SignatureOffset = 54
    static let v2HeaderSize = 118
    static let signatureSize = 64
    static let aesKeySize = 32

    /// Android's table: a type it does not name is "unknown" (the key lands under its address only).
    static let channelTypes: [UInt8: String] = [
        0x00: "sms", 0x01: "mesh", 0x02: "iridium", 0x04: "zigbee", 0x05: "mqtt", 0x06: "webhook",
    ]

    public enum TrustStatus: Sendable, Equatable {
        /// The first bundle from this bridge: the signature verifies and its key is now pinned.
        case newTrusted
        /// A later bundle that verifies under the pinned key.
        case existingTrusted
        /// A v1 bundle: imported, but nothing could check it.
        case unverifiedV1
    }

    public enum ImportResult: Sendable, Equatable {
        case success(count: Int, status: TrustStatus, bridgeHashHex: String)
        /// A v2 bundle signed by another key than the one pinned for its bridge: a rotation or an
        /// impersonation. Nothing is imported; the person decides (`forceRepin`).
        case keyMismatch(bridgeHashHex: String, storedPubkey: Data, presentedPubkey: Data, firstSeen: Int64)
        case invalidSignature(String)
        case malformed(String)
    }

    public static func isKeyBundleUrl(_ s: String) -> Bool { s.hasPrefix(urlPrefix) }

    /// Import a `meshsat://key/` URL. `forceRepin` replaces a pinned key, only after the person
    /// confirmed a `.keyMismatch`.
    public static func importFromURL(
        _ url: String, store: any KeyBundleStore, forceRepin: Bool = false,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async -> ImportResult {
        guard url.hasPrefix(urlPrefix) else { return .malformed("Not a meshsat key URL") }
        guard let data = base64URL(String(url.dropFirst(urlPrefix.count))) else { return .malformed("Base64 decode failed") }
        guard data.count >= v1HeaderSize else { return .malformed("Bundle too short: \(data.count) bytes") }
        switch data[0] {
        case 0x01:
            return await importV1(data, store: store, now: now)
        case 0x02:
            return await importV2(data, store: store, forceRepin: forceRepin, now: now)
        default:
            return .malformed(String(format: "Unsupported bundle version: 0x%02x", data[0]))
        }
    }

    /// Base64url with or without padding, as java.util.Base64's URL decoder takes it.
    static func base64URL(_ s: String) -> [UInt8]? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).map { Array($0) }
    }

    static func hex(_ b: some Sequence<UInt8>) -> String { b.map { String(format: "%02x", $0) }.joined() }

    static func importV1(_ data: [UInt8], store: any KeyBundleStore, now: Int64) async -> ImportResult {
        let bridgeHashHex = hex(data[1..<17])
        do {
            let n = try await writeEntries(data, from: v1HeaderSize, store: store, now: now)
            return .success(count: n, status: .unverifiedV1, bridgeHashHex: bridgeHashHex)
        } catch {
            return .malformed("Entry parse failed: \(error)")
        }
    }

    static func importV2(_ data: [UInt8], store: any KeyBundleStore, forceRepin: Bool, now: Int64) async -> ImportResult {
        guard data.count >= v2HeaderSize else {
            return .malformed("v2 bundle too short: \(data.count) bytes (need \(v2HeaderSize))")
        }
        let bridgeHashHex = hex(data[1..<17])
        let presented = Data(data[v2PubkeyOffset..<v2SignatureOffset])
        let signature = Data(data[v2SignatureOffset..<v2HeaderSize])
        // Everything but the signature, in order.
        let signed = Data(data[0..<v2SignatureOffset] + data[v2HeaderSize...])
        // Verified under the presented key before any trust check: a tampered bundle stops here,
        // a re-signed one under another key meets the pin below.
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: presented) else {
            return .invalidSignature("Signature verification error: not an Ed25519 key")
        }
        guard key.isValidSignature(signature, for: signed) else {
            return .invalidSignature("Ed25519 signature does not match bundle contents")
        }
        let status: TrustStatus
        do {
            if let existing = try await store.trust(bridgeHashHex) {
                if existing.pubkey == presented {
                    var t = existing
                    t.lastSeen = now
                    t.importCount += 1
                    try await store.upsertTrust(t)
                    status = .existingTrusted
                } else if forceRepin {
                    var t = existing
                    t.pubkey = presented
                    t.lastSeen = now
                    t.importCount += 1
                    try await store.upsertTrust(t)
                    status = .newTrusted
                } else {
                    return .keyMismatch(
                        bridgeHashHex: bridgeHashHex, storedPubkey: existing.pubkey, presentedPubkey: presented,
                        firstSeen: existing.firstSeen)
                }
            } else {
                try await store.upsertTrust(
                    BridgeTrust(
                        bridgeHash: bridgeHashHex, pubkey: presented, firstSeen: now, lastSeen: now,
                        label: "Bridge \(bridgeHashHex.prefix(8))", importCount: 1))
                status = .newTrusted
            }
            let n = try await writeEntries(data, from: v2HeaderSize, store: store, now: now)
            return .success(count: n, status: status, bridgeHashHex: bridgeHashHex)
        } catch {
            return .malformed("Entry parse failed: \(error)")
        }
    }

    struct Truncated: Error, CustomStringConvertible {
        let entry: Int
        var description: String { "Truncated entry \(entry)" }
    }

    /// Each entry as a conversation key under its address, again under "channel:address" (how a
    /// chain's key_ref names it, so a mesh "shared" never replaces the satellite's; MESHSAT-1623),
    /// and as a provider credential. Answers how many.
    static func writeEntries(_ data: [UInt8], from start: Int, store: any KeyBundleStore, now: Int64) async throws -> Int {
        let count = Int(data[21])
        let bridgeHashHex = hex(data[1..<17])
        var offset = start
        let short = String(bridgeHashHex.prefix(8))
        for i in 0..<count {
            guard offset + 2 <= data.count else { throw Truncated(entry: i) }
            let channel = channelTypes[data[offset]] ?? "unknown"
            let addrLen = Int(data[offset + 1])
            offset += 2
            guard offset + addrLen + aesKeySize <= data.count else { throw Truncated(entry: i) }
            let address = String(decoding: data[offset..<offset + addrLen], as: UTF8.self)
            offset += addrLen
            let key = Array(data[offset..<offset + aesKeySize])
            offset += aesKeySize
            let label = "Bridge \(channel) (\(short))"
            try await store.upsertConversationKey(ConversationKey(sender: address, hexKey: hex(key), label: label))
            if channel != "unknown" {
                try await store.upsertConversationKey(ConversationKey(sender: "\(channel):\(address)", hexKey: hex(key), label: label))
            }
            try await store.upsertCredential(
                ProviderCredential(
                    id: "\(short)_\(channel)_\(javaHashHex(address))", provider: channel,
                    name: "Key for \(address) (bridge \(short))", credType: "aes_key", encryptedData: Data(key),
                    version: 1, source: "qr", receivedAt: now))
        }
        return count
    }

    /// Kotlin's `address.hashCode().toString(16)`: Java's String hash over UTF-16 units, signed,
    /// so the credential ids match Android's for the same bundle.
    static func javaHashHex(_ s: String) -> String {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return h < 0 ? "-" + String(UInt32(bitPattern: 0 &- h), radix: 16) : String(h, radix: 16)
    }
}
