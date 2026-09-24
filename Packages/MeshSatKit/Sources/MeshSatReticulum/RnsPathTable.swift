// Mirrors reticulum/RnsPathTable.kt: the path table with cost-aware routing (MESHSAT-222).
// Multiple paths per destination (one per interface); the best is the lowest composite score
// of cost, hops and latency, among online interfaces first. Time is injected for the tests.
import Foundation
import MeshSatWire

public struct RnsPath: Sendable, Equatable {
    public static let defaultTtlMs: Int64 = 30 * 60 * 1000

    public var destHash: [UInt8]
    public var nextHop: [UInt8]?  // nil = direct, no relay
    public var interfaceId: String
    public var hops: Int
    public var costCents: Int
    public var latencyMs: Int
    public var createdAt: Int64
    public var lastSeen: Int64
    public var expiresAt: Int64
    public var announceCount: Int

    public init(
        destHash: [UInt8], nextHop: [UInt8]?, interfaceId: String, hops: Int, costCents: Int, latencyMs: Int,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000), lastSeen: Int64? = nil, expiresAt: Int64? = nil,
        announceCount: Int = 1
    ) {
        self.destHash = destHash
        self.nextHop = nextHop
        self.interfaceId = interfaceId
        self.hops = hops
        self.costCents = costCents
        self.latencyMs = latencyMs
        self.createdAt = createdAt
        self.lastSeen = lastSeen ?? createdAt
        self.expiresAt = expiresAt ?? createdAt + RnsPath.defaultTtlMs
        self.announceCount = announceCount
    }

    public var destHashHex: String { Hex.encode(destHash) }
    public func isExpired(nowMs: Int64) -> Bool { nowMs > expiresAt }
    /// Composite path score (lower is better): free before paid, fewer hops, lower latency.
    public var score: Int { costCents * 1000 + hops * 100 + latencyMs / 100 }
}

public final class RnsPathTable: @unchecked Sendable {
    private let interfaces: @Sendable () -> [any RnsInterface]
    private let pathTtlMs: Int64
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var paths: [String: [RnsPath]] = [:]

    public init(
        interfaces: @escaping @Sendable () -> [any RnsInterface], pathTtlMs: Int64 = RnsPath.defaultTtlMs,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.interfaces = interfaces
        self.pathTtlMs = pathTtlMs
        self.now = now
    }

    /// Record or update a path from an announce. True when this is a new destination.
    @discardableResult
    public func updateFromAnnounce(destHash: [UInt8], interfaceId: String, hops: Int, nextHop: [UInt8]? = nil) -> Bool {
        let key = Hex.encode(destHash)
        let iface = interfaces().first { $0.interfaceId == interfaceId }
        let costCents = iface?.costCents ?? 0
        let latencyMs = iface?.latencyMs ?? 0
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        var list = paths[key] ?? []
        if let idx = list.firstIndex(where: { $0.interfaceId == interfaceId }) {
            var p = list[idx]
            if hops <= p.hops {
                p.hops = hops
                p.nextHop = nextHop
                p.costCents = costCents
                p.latencyMs = latencyMs
            }
            p.lastSeen = t
            p.expiresAt = t + pathTtlMs
            p.announceCount += 1
            list[idx] = p
            paths[key] = list
            return false
        }
        list.append(
            RnsPath(
                destHash: destHash, nextHop: nextHop, interfaceId: interfaceId, hops: hops, costCents: costCents, latencyMs: latencyMs,
                createdAt: t, lastSeen: t, expiresAt: t + pathTtlMs))
        paths[key] = list
        return list.count == 1
    }

    /// The best path: lowest score among online interfaces, else among any live path.
    public func bestPath(_ destHash: [UInt8]) -> RnsPath? {
        let onlineIds = Set(interfaces().filter { $0.isOnline }.map { $0.interfaceId })
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        guard let candidates = paths[Hex.encode(destHash)]?.filter({ !$0.isExpired(nowMs: t) }), !candidates.isEmpty else { return nil }
        let online = candidates.filter { onlineIds.contains($0.interfaceId) }
        return (online.isEmpty ? candidates : online).min { $0.score < $1.score }
    }

    /// All live paths to a destination, best first.
    public func allPaths(_ destHash: [UInt8]) -> [RnsPath] {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        return (paths[Hex.encode(destHash)] ?? []).filter { !$0.isExpired(nowMs: t) }.sorted { $0.score < $1.score }
    }

    public func hasPath(_ destHash: [UInt8]) -> Bool { !allPaths(destHash).isEmpty }

    /// Hop count via the best path, or -1.
    public func hopsTo(_ destHash: [UInt8]) -> Int { bestPath(destHash)?.hops ?? -1 }

    public func removeDest(_ destHash: [UInt8]) {
        lock.lock()
        paths.removeValue(forKey: Hex.encode(destHash))
        lock.unlock()
    }

    /// Remove every path via an interface (disabled or removed for good).
    public func removeInterface(_ interfaceId: String) {
        lock.lock()
        for (k, v) in paths {
            let kept = v.filter { $0.interfaceId != interfaceId }
            if kept.isEmpty { paths.removeValue(forKey: k) } else { paths[k] = kept }
        }
        lock.unlock()
    }

    /// An interface went offline: its paths get at most five minutes more, not removed, since
    /// they may come back with it.
    public func markInterfaceStale(_ interfaceId: String) {
        let limit = now() + 5 * 60 * 1000
        lock.lock()
        for (k, v) in paths {
            paths[k] = v.map { p in
                var p = p
                if p.interfaceId == interfaceId { p.expiresAt = min(p.expiresAt, limit) }
                return p
            }
        }
        lock.unlock()
    }

    public func prune() {
        let t = now()
        lock.lock()
        for (k, v) in paths {
            let kept = v.filter { !$0.isExpired(nowMs: t) }
            if kept.isEmpty { paths.removeValue(forKey: k) } else { paths[k] = kept }
        }
        lock.unlock()
    }

    public func destCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }

    public func pathCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.values.reduce(0) { $0 + $1.count }
    }

    /// Every destination and its best live path.
    public func snapshot() -> [String: RnsPath?] {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        return paths.mapValues { $0.filter { !$0.isExpired(nowMs: t) }.min { $0.score < $1.score } }
    }
}

/// Path request/response for active path discovery: the request is flooded with the target
/// hash; a node that knows a path answers with [dest_hash(16) + next_hop(16) + hops(1)].
public enum RnsPathDiscovery {
    public static let pathRequestSize = RnsConstants.destHashLen
    public static let pathResponseSize = RnsConstants.destHashLen * 2 + 1

    public static func createRequest(targetDestHash: [UInt8]) -> [UInt8] {
        RnsPacket.data(
            destHash: targetDestHash, payload: targetDestHash, destType: RnsConstants.destPlain, context: RnsConstants.ctxPathResponse
        )
        .marshal()
    }

    public static func createResponse(requesterDestHash: [UInt8], targetDestHash: [UInt8], nextHop: [UInt8], hops: Int) -> [UInt8] {
        RnsPacket.data(
            destHash: requesterDestHash, payload: targetDestHash + nextHop + [UInt8(hops & 0xFF)], destType: RnsConstants.destPlain,
            context: RnsConstants.ctxPathResponse
        ).marshal()
    }

    public struct PathResponse: Sendable, Equatable {
        public let target: [UInt8]
        public let nextHop: [UInt8]
        public let hops: Int
    }

    /// The target, next hop and hop count of a path response, or nil.
    public static func parseResponse(_ payload: [UInt8]) -> PathResponse? {
        guard payload.count >= pathResponseSize else { return nil }
        let n = RnsConstants.destHashLen
        return PathResponse(target: Array(payload[0..<n]), nextHop: Array(payload[n..<2 * n]), hops: Int(payload[2 * n]))
    }
}
