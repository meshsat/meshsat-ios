// Mirrors rns/Paths.kt: one row of Transport.path_table and the table itself.
import Foundation

/// One row of the path table (Transport.path_table).
public final class PathEntry: @unchecked Sendable {
    public let destHash: [UInt8]
    /// Last use.
    public var timestampMs: Int64
    /// Transport id of the next hop (== dest when direct).
    public let nextHop: [UInt8]
    public let hops: Int
    public var expiresMs: Int64
    /// The 10-byte random hashes heard, newest last.
    public var randomBlobs: [[UInt8]]
    /// Received on / next-hop interface.
    public let iface: String
    public let announce: Announce
    public let packetHash: [UInt8]
    public var unresponsive = false

    public init(
        destHash: [UInt8], timestampMs: Int64, nextHop: [UInt8], hops: Int, expiresMs: Int64, randomBlobs: [[UInt8]],
        iface: String, announce: Announce, packetHash: [UInt8]
    ) {
        self.destHash = destHash
        self.timestampMs = timestampMs
        self.nextHop = nextHop
        self.hops = hops
        self.expiresMs = expiresMs
        self.randomBlobs = randomBlobs
        self.iface = iface
        self.announce = announce
        self.packetHash = packetHash
    }

    /// The destination is a neighbour: one hop, or heard by its own HEADER_1 announce (next hop == its
    /// hash) however many hops a paid link's extra hops count. A packet to a neighbour stays HEADER_1; a
    /// HEADER_2 with its own hash as the transport id is what a stock peer drops (the Bridge's bc9cfb9).
    public var direct: Bool { hops <= 1 || nextHop == destHash }

    /// The newest emission timestamp among the random blobs.
    public func emittedAt() -> Int64 { randomBlobs.map { Announce.blobTimestamp($0) }.max() ?? 0 }
}

/// Known paths; expired entries stay one extra TTL so a worse path can replace them (as RNS keeps candidates).
public final class PathTable: @unchecked Sendable {
    public let ttlMs: Int64
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var m: [String: PathEntry] = [:]

    public init(ttlMs: Int64, now: @escaping @Sendable () -> Int64) {
        self.ttlMs = ttlMs
        self.now = now
    }

    public func get(_ dest: [UInt8]) -> PathEntry? {
        lock.lock()
        defer { lock.unlock() }
        return m[dest.hex]
    }

    public func has(_ dest: [UInt8]) -> Bool {
        guard let e = get(dest) else { return false }
        return now() < e.expiresMs
    }

    public func hops(_ dest: [UInt8]) -> Int { get(dest)?.hops ?? -1 }

    public func put(_ e: PathEntry) {
        lock.lock()
        defer { lock.unlock() }
        m[e.destHash.hex] = e
    }

    public func remove(_ dest: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        m[dest.hex] = nil
    }

    @discardableResult
    public func expire(_ nowMs: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let gone = m.filter { nowMs > $0.value.expiresMs + ttlMs }.map(\.key)
        for k in gone { m[k] = nil }
        return gone.count
    }

    public func all() -> [PathEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(m.values)
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return m.count
    }
}
