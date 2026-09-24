// Mirrors dedup/Deduplicator.kt (the Bridge's internal/dedup): O(1) duplicate detection on
// composite keys with a TTL, so a forwarded message cannot loop between transports.
import Foundation

public final class Deduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private let ttlMs: Int64
    private let maxSize: Int
    private let now: @Sendable () -> Int64
    private var seen: [String: Int64] = [:]
    private var order: [String] = []

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

    /// The same for an arbitrary key (an SMS, for instance).
    public func isDuplicateKey(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if seen[key] != nil { return true }
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

    /// Remove expired entries; returns how many.
    @discardableResult
    public func prune() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let t = now()
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
