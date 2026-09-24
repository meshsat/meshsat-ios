// Mirrors engine/SigningService.kt (port of meshsat/internal/engine/signing.go): an Ed25519
// signing key and the tamper-evident audit log, a SHA-256 hash chain over
// prev_hash + timestamp + event_type + detail. The key pair is kept in the secure store as the
// hex of the 32-byte seed and the raw public key (Android keeps PKCS#8 and X.509 DER; the two
// stores are never shared, so the layout is each app's own).
import Crypto
import Foundation
import Logging

public protocol AuditStore: Sendable {
    @discardableResult func insert(_ entry: AuditLogEntry) async throws -> Int64
    /// Newest first.
    func getRecent(limit: Int) async throws -> [AuditLogEntry]
}

public final class SigningService: @unchecked Sendable {
    private static let log = Logger(label: "SigningService")
    static let keyPrivate = "signing_private_key"
    static let keyPublic = "signing_public_key"

    private let audit: any AuditStore
    private let key: Curve25519.Signing.PrivateKey
    private let lock = NSLock()
    private var lastHash = ""
    private let now: @Sendable () -> Date

    /// Hex of the raw 32-byte public key: the signer id.
    public let signerId: String

    public init(audit: any AuditStore, store: any KeyValueStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.audit = audit
        self.now = now
        if let seedHex = store.get(Self.keyPrivate), let seed = Self.bytes(seedHex),
            let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        {
            key = k
        } else {
            key = Curve25519.Signing.PrivateKey()
            store.set(Self.keyPrivate, Self.hex(Array(key.rawRepresentation)))
            store.set(Self.keyPublic, Self.hex(Array(key.publicKey.rawRepresentation)))
        }
        signerId = Self.hex(Array(key.publicKey.rawRepresentation))
        Self.log.info("signing service initialized: \(signerId.prefix(16))...")
    }

    /// Ed25519 over `data`: a 64-byte signature.
    public func sign(_ data: [UInt8]) -> [UInt8] { Array((try? key.signature(for: data)) ?? Data()) }

    /// The last hash from the store, for chain continuity; once, after construction.
    public func loadLastHash() async {
        if let last = try? await audit.getRecent(limit: 1).first { setLastHash(last.hash) }
    }

    private func setLastHash(_ hash: String) {
        lock.lock()
        lastHash = hash
        lock.unlock()
    }

    static let utcFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func chainHash(prevHash: String, timestamp: String, eventType: String, detail: String) -> String {
        var h = SHA256()
        h.update(data: Data(prevHash.utf8))
        h.update(data: Data(timestamp.utf8))
        h.update(data: Data(eventType.utf8))
        h.update(data: Data(detail.utf8))
        return hex(Array(h.finalize()))
    }

    /// A tamper-evident audit entry on the chain.
    public func auditEvent(
        _ eventType: String, interfaceId: String? = nil, direction: String? = nil, deliveryId: Int64? = nil, ruleId: Int64? = nil,
        detail: String = ""
    ) async {
        // One writer at a time, so the chain never forks: the lock is taken for the whole entry,
        // and the store's own serial queue orders the inserts.
        let entry = chained(
            AuditLogEntry(
                timestamp: "", interfaceId: interfaceId, direction: direction, eventType: eventType, deliveryId: deliveryId, ruleId: ruleId,
                detail: detail))
        do {
            try await audit.insert(entry)
        } catch {
            Self.log.error("audit log insert failed: \(error)")
            rollback(to: entry.prevHash, from: entry.hash)
        }
    }

    /// The entry with its timestamp, prev_hash and hash, the chain moved on under the lock.
    private func chained(_ template: AuditLogEntry) -> AuditLogEntry {
        lock.lock()
        defer { lock.unlock() }
        var entry = template
        entry.timestamp = Self.utcFormat.string(from: now())
        entry.prevHash = lastHash
        entry.hash = Self.chainHash(prevHash: lastHash, timestamp: entry.timestamp, eventType: entry.eventType, detail: entry.detail)
        lastHash = entry.hash
        return entry
    }

    private func rollback(to prev: String, from hash: String) {
        lock.lock()
        if lastHash == hash { lastHash = prev }
        lock.unlock()
    }

    /// The integrity of the last `limit` entries: (valid count, index of the first broken entry
    /// from the oldest, or -1 when every one is as written).
    public func verifyChain(limit: Int = 1000) async -> (valid: Int, brokenAt: Int) {
        guard let entries = try? await audit.getRecent(limit: limit), !entries.isEmpty else { return (0, -1) }
        let ordered = Array(entries.reversed())
        for (i, e) in ordered.enumerated() {
            let expected = Self.chainHash(prevHash: e.prevHash, timestamp: e.timestamp, eventType: e.eventType, detail: e.detail)
            if e.hash != expected { return (i, i) }
        }
        return (ordered.count, -1)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
