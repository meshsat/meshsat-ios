// Mirrors reticulum/RnsAnnounceHandler.kt: creates this node's announces and processes incoming
// ones with verification, deduplication and a delayed relay.
//
// A full announce on the wire is the RnsPacket header (18 bytes) and the RnsAnnounce data
// (148 bytes and up), 166 bytes at least.
import Foundation
import MeshSatCrypto
import MeshSatWire

/// Forwards a framed announce packet (header and data) to the interfaces.
public typealias RnsRelayCallback = @Sendable (_ packet: [UInt8], _ destHash: [UInt8]) -> Void

/// A new, verified announce.
public struct RnsAnnounceEvent: Sendable, Equatable {
    public let destHash: [UInt8]
    public let encryptionPub: [UInt8]
    public let signingPub: [UInt8]
    public let appData: [UInt8]?
    public let hops: Int
    public let sourceInterface: String
}

public typealias RnsAnnounceCallback = @Sendable (RnsAnnounceEvent) -> Void

public final class RnsAnnounceHandler: @unchecked Sendable {
    private let identity: Identity
    private let relayCallback: RnsRelayCallback?
    private let announceCallback: RnsAnnounceCallback?
    private let maxHops: Int
    private let dedupTtlMs: Int64
    private let maxDedupEntries: Int
    private let minRelayDelayMs: Int64
    private let maxRelayDelayMs: Int64
    private let appName: String
    private let aspects: [String]
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let lock = NSLock()
    /// Dedup cache in insertion order (Android: an access-ordered LinkedHashMap).
    private var seen: [String: Int64] = [:]
    private var seenOrder: [String] = []
    private var localHashes: Set<String> = []
    private var pruner: Task<Void, Never>?
    /// Our Reticulum destination hash, from the identity and the app name.
    public let localDestHash: [UInt8]

    public init(
        identity: Identity, relayCallback: RnsRelayCallback? = nil, announceCallback: RnsAnnounceCallback? = nil,
        maxHops: Int = RnsConstants.maxHops, dedupTtlMs: Int64 = 30 * 60_000, maxDedupEntries: Int = 10_000, minRelayDelayMs: Int64 = 100,
        maxRelayDelayMs: Int64 = 2_000, appName: String = RnsDestination.appName, aspects: [String] = [RnsDestination.aspectNode],
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) {
        self.identity = identity
        self.relayCallback = relayCallback
        self.announceCallback = announceCallback
        self.maxHops = maxHops
        self.dedupTtlMs = dedupTtlMs
        self.maxDedupEntries = maxDedupEntries
        self.minRelayDelayMs = minRelayDelayMs
        self.maxRelayDelayMs = maxRelayDelayMs
        self.appName = appName
        self.aspects = aspects
        self.now = now
        self.sleep = sleep
        self.localDestHash = RnsDestination.computeDestHash(
            encryptionPub: identity.encryptionPubRaw, signingPub: identity.signingPubRaw, appName: appName, aspects: aspects)
        localHashes.insert(Hex.encode(localDestHash))
    }

    /// A signed Reticulum announce packet for this node, ready to send. The app data carries
    /// MeshSat's device metadata only; both public keys are in the announce itself.
    public func createAnnounce(deviceType: UInt8 = MeshSatAppData.deviceIos, capabilities: UInt8 = 0) -> [UInt8] {
        let appData = MeshSatAppData.encode(deviceType: deviceType, capabilities: capabilities)
        let (announce, destHash) = RnsAnnounce.create(
            encryptionPub: identity.encryptionPubRaw, signingPub: identity.signingPubRaw, appName: appName, aspects: aspects,
            appData: appData, now: now() / 1000, sign: { identity.sign($0) })
        return RnsPacket.announce(destHash: destHash, announceData: announce.marshal()).marshal()
    }

    /// An incoming announce packet. True when it was new and valid.
    @discardableResult
    public func handleAnnounce(_ raw: [UInt8], sourceInterface: String) -> Bool {
        guard let packet = try? RnsPacket.unmarshal(raw), packet.packetType == RnsConstants.packetAnnounce,
            let announce = try? RnsAnnounce.unmarshal(packet.data), announce.verify(destHash: packet.destHash)
        else { return false }
        let dedupKey = Hex.encode(announce.announceHash(destHash: packet.destHash))
        lock.lock()
        if seen[dedupKey] != nil {
            lock.unlock()
            return false
        }
        seen[dedupKey] = now()
        seenOrder.append(dedupKey)
        let isLocal = localHashes.contains(Hex.encode(packet.destHash))
        lock.unlock()
        announceCallback?(
            RnsAnnounceEvent(
                destHash: packet.destHash, encryptionPub: announce.encryptionPub, signingPub: announce.signingPub,
                appData: announce.appData,
                hops: packet.hops, sourceInterface: sourceInterface))
        // Never relay our own announces, nor one that has travelled far enough.
        if isLocal || packet.hops >= maxHops { return true }
        if relayCallback != nil { scheduleRelay(packet) }
        return true
    }

    /// The background dedup cache pruner, every two minutes.
    public func startPruner() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, (try? await self.sleep(2 * 60_000)) != nil else { return }
                self.prune()
            }
        }
        lock.lock()
        pruner?.cancel()
        pruner = task
        lock.unlock()
    }

    public func stopPruner() {
        lock.lock()
        let p = pruner
        pruner = nil
        lock.unlock()
        p?.cancel()
    }

    public func seenCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    /// Register another local destination hash (never relayed).
    public func registerLocal(_ destHash: [UInt8]) {
        lock.lock()
        localHashes.insert(Hex.encode(destHash))
        lock.unlock()
    }

    public func isLocal(_ destHash: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return localHashes.contains(Hex.encode(destHash))
    }

    private func scheduleRelay(_ packet: RnsPacket) {
        let range = max(0, maxRelayDelayMs - minRelayDelayMs)
        let delayMs = minRelayDelayMs + (range > 0 ? Int64.random(in: 0..<range) : 0)
        Task { [self] in
            guard (try? await sleep(delayMs)) != nil else { return }
            var relayed = packet
            relayed.hops = packet.hops + 1
            relayCallback?(relayed.marshal(), packet.destHash)
        }
    }

    func prune() {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        seenOrder.removeAll { key in
            if let at = seen[key], t - at > dedupTtlMs {
                seen.removeValue(forKey: key)
                return true
            }
            return false
        }
        if seen.count > maxDedupEntries {
            let excess = seen.count - maxDedupEntries
            for key in seenOrder.prefix(excess) { seen.removeValue(forKey: key) }
            seenOrder.removeFirst(excess)
        }
    }
}
