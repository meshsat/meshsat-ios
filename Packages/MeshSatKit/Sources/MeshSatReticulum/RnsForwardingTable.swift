// Mirrors reticulum/RnsForwardingTable.kt: the transport node's forwarding entries learned from
// announces and path responses, one per egress interface, best by cost then hops (MESHSAT-199).
import Foundation
import MeshSatWire

public final class RnsForwardingTable: @unchecked Sendable {
    public static let defaultTtlMs: Int64 = 30 * 60 * 1000
    public static let maxEntries = 10_000

    public struct Entry: Sendable, Equatable {
        public var destHash: [UInt8]
        public var nextHop: [UInt8]?
        public var egressInterface: String
        public var hops: Int
        public var costCents: Int
        public var createdAt: Int64
        public var lastSeen: Int64
        public var expiresAt: Int64

        public init(
            destHash: [UInt8], nextHop: [UInt8]?, egressInterface: String, hops: Int, costCents: Int,
            createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000), lastSeen: Int64? = nil, expiresAt: Int64? = nil
        ) {
            self.destHash = destHash
            self.nextHop = nextHop
            self.egressInterface = egressInterface
            self.hops = hops
            self.costCents = costCents
            self.createdAt = createdAt
            self.lastSeen = lastSeen ?? createdAt
            self.expiresAt = expiresAt ?? createdAt + RnsForwardingTable.defaultTtlMs
        }

        public var destHashHex: String { Hex.encode(destHash) }
        public func isExpired(nowMs: Int64) -> Bool { nowMs > expiresAt }
        /// Lower is better: cost x 1000 + hops x 100.
        public var score: Int { costCents * 1000 + hops * 100 }
    }

    private let ttlMs: Int64
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var entries: [String: [Entry]] = [:]

    public init(
        ttlMs: Int64 = RnsForwardingTable.defaultTtlMs,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.ttlMs = ttlMs
        self.now = now
    }

    /// Learn a path. True when this is the first entry for the destination.
    @discardableResult
    public func learn(destHash: [UInt8], nextHop: [UInt8]?, egressInterface: String, hops: Int, costCents: Int = 0) -> Bool {
        let key = Hex.encode(destHash)
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        var list = entries[key] ?? []
        let isNew = list.isEmpty
        if let idx = list.firstIndex(where: { $0.egressInterface == egressInterface }) {
            if hops <= list[idx].hops {
                list[idx] = Entry(
                    destHash: destHash, nextHop: nextHop, egressInterface: egressInterface, hops: hops, costCents: costCents, createdAt: t,
                    expiresAt: t + ttlMs)
            } else {
                list[idx].lastSeen = t
                list[idx].expiresAt = t + ttlMs
            }
        } else {
            list.append(
                Entry(
                    destHash: destHash, nextHop: nextHop, egressInterface: egressInterface, hops: hops, costCents: costCents, createdAt: t,
                    expiresAt: t + ttlMs))
        }
        entries[key] = list
        if entries.count > Self.maxEntries { pruneOldest() }
        return isNew
    }

    /// The best live entry for a destination.
    public func lookup(_ destHash: [UInt8]) -> Entry? {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        return entries[Hex.encode(destHash)]?.filter { !$0.isExpired(nowMs: t) }.min { $0.score < $1.score }
    }

    /// Every live entry for a destination, best first.
    public func allEntries(_ destHash: [UInt8]) -> [Entry] {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        return (entries[Hex.encode(destHash)] ?? []).filter { !$0.isExpired(nowMs: t) }.sorted { $0.score < $1.score }
    }

    public func hasEntry(_ destHash: [UInt8]) -> Bool { !allEntries(destHash).isEmpty }

    public func remove(_ destHash: [UInt8]) {
        lock.lock()
        entries.removeValue(forKey: Hex.encode(destHash))
        lock.unlock()
    }

    public func removeInterface(_ interfaceId: String) {
        lock.lock()
        for (k, v) in entries {
            let kept = v.filter { $0.egressInterface != interfaceId }
            if kept.isEmpty { entries.removeValue(forKey: k) } else { entries[k] = kept }
        }
        lock.unlock()
    }

    /// Remove expired entries; the number removed.
    @discardableResult
    public func prune() -> Int {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        var removed = 0
        for (k, v) in entries {
            let kept = v.filter { !$0.isExpired(nowMs: t) }
            removed += v.count - kept.count
            if kept.isEmpty { entries.removeValue(forKey: k) } else { entries[k] = kept }
        }
        return removed
    }

    public func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func totalEntries() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.count }
    }

    /// Every destination's best live entry.
    public func snapshot() -> [String: Entry] {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Entry] = [:]
        for (k, v) in entries {
            if let best = v.filter({ !$0.isExpired(nowMs: t) }).min(by: { $0.score < $1.score }) { out[k] = best }
        }
        return out
    }

    /// Drop the quarter of entries seen longest ago (called under the lock).
    private func pruneOldest() {
        let all = entries.values.flatMap { $0 }.sorted { $0.lastSeen < $1.lastSeen }
        for entry in all.prefix(entries.count / 4) {
            let key = entry.destHashHex
            entries[key]?.removeAll { $0.egressInterface == entry.egressInterface && $0.destHash == entry.destHash }
            if entries[key]?.isEmpty == true { entries.removeValue(forKey: key) }
        }
    }
}
