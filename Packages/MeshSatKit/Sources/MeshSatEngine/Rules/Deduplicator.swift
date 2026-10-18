// Mirrors dedup/Deduplicator.kt (the Bridge's internal/dedup): O(1) duplicate detection on
// composite keys with a TTL, so a forwarded message cannot loop between transports.
import Crypto
import Foundation

public final class Deduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private let ttlMs: Int64
    private let maxSize: Int
    private let now: @Sendable () -> Int64
    private var seen: [String: Int64] = [:]
    private var order: [String] = []
    private var lastPrune: Int64 = 0

    public init(
        ttlMs: Int64 = 10 * 60_000, maxSize: Int = 10_000,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.ttlMs = ttlMs
        self.maxSize = maxSize
        self.now = now
    }

    /// True if from+packetId was seen recently (skip it), false the first time.
    public func isDuplicate(from: UInt32, packetId: UInt32) -> Bool {
        isDuplicateKey("\(from):\(packetId)")
    }

    /// The same for an arbitrary key (an SMS, for instance). Expired entries go first, at most
    /// once a minute: nothing called prune(), so the TTL never applied and only the size cap
    /// ever let a key go (MESHSAT-1584).
    public func isDuplicateKey(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let t = now()
        if t - lastPrune >= 60_000 {
            pruneLocked(t)
            lastPrune = t
        }
        if let mark = seen[key] {
            if t - mark <= ttlMs { return true }
            seen[key] = nil  // expired since the last prune: new again
            order.removeAll { $0 == key }
        }
        if seen.count >= maxSize, let oldest = order.first {
            order.removeFirst()
            seen[oldest] = nil
        }
        seen[key] = now()
        order.append(key)
        return false
    }

    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    /// A key for a text that is the same in every launch: Swift's hashValue is seeded per process,
    /// so an Iridium MT keyed on it was a new message after every app start (MESHSAT-1584).
    public static func stableKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Remove expired entries; returns how many.
    @discardableResult
    public func prune() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pruneLocked(now())
    }

    @discardableResult
    private func pruneLocked(_ t: Int64) -> Int {
        var pruned = 0
        order.removeAll { key in
            guard let mark = seen[key], t - mark > ttlMs else { return false }
            seen[key] = nil
            pruned += 1
            return true
        }
        return pruned
    }
}
