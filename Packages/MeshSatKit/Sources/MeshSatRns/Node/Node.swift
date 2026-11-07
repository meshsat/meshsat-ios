// Mirrors rns/Node.kt: the Reticulum node (RNS/Transport.py, RNS/Link.py) on top of the wire
// format in this module: packet filtering and deduplication, the path table with RNS replacement
// rules, announce rebroadcast as a transport node, HEADER_2 forwarding with link and reverse
// tables, path requests, links, packet proofs and receipts, resources. A port of the Bridge's
// internal/rns, which is verified against Python RNS by its interop tests; the Kotlin port and
// this one are verified the same way (MESHSAT-1553, MESHSAT-1735).
//
// The node knows nothing about sockets or radios: a `Transmitter` puts raw packets on named
// interfaces and the owner feeds received packets to `inbound`. Paid bearers never appear in
// `Transmitter.floodable()`, so nothing in here can flood them; a `PaidPolicy` opens one to a
// few named destinations instead.
//
// Threading: `lock` (recursive, as Kotlin's ReentrantLock) guards the tables; callbacks run
// outside it, on whichever thread fed the packet or on the jobs task. Nothing transmits under
// the lock. The 250 ms jobs tick is one Task on the injected clock; Kotlin's one-shot scheduler
// is a due-list that the same tick drains, so a test clock never waits.
import Foundation
import MeshSatNet
import MeshSatReticulum
import MeshSatWire

extension Array where Element == UInt8 {
    var hex: String { Hex.encode(self) }
    /// The first eight hex digits, for logs.
    var hex8: String { String(hex.prefix(8)) }
}

extension NSRecursiveLock {
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

public protocol Transmitter: Sendable {
    /// Puts one raw packet on the named interface; false when it could not be sent.
    func transmit(ifaceId: String, raw: [UInt8]) -> Bool
    /// The online interfaces that may carry broadcast traffic (announces, path requests, pathless packets). Never a paid bearer.
    func floodable() -> [String]
    /// The interface's hardware MTU, or 0 when unknown.
    func hwMtu(ifaceId: String) -> Int
    /// Bits per second, or 0 when unknown or effectively unlimited (no announce cap).
    func bitrate(ifaceId: String) -> Int
    /// Whether a (paid) interface is up; a policy skips a down one instead of booking a send on it.
    func online(ifaceId: String) -> Bool
}

extension Transmitter {
    public func hwMtu(ifaceId: String) -> Int { 0 }
    public func bitrate(ifaceId: String) -> Int { 0 }
    public func online(ifaceId: String) -> Bool { true }
}

public struct NodeConfig: Sendable {
    public let identity: RnsIdentity
    /// Interfaces whose HEADER_1 packets for a destination that is not local are forwarded along a known
    /// path even though a stock node would not (its peers cannot address a transport): the MeshSat
    /// extension for the Meshtastic bearer.
    public let forwardHeader1From: Set<String>
    /// Overrides PATHFINDER_E (one week).
    public let pathTtlMs: Int64
    public let clock: any DriverClock
    public let log: @Sendable (String) -> Void

    public init(
        identity: RnsIdentity, forwardHeader1From: Set<String> = [], pathTtlMs: Int64 = Rns.pathfinderE * 1000,
        clock: any DriverClock = SystemDriverClock(), log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.identity = identity
        self.forwardHeader1From = forwardHeader1From
        self.pathTtlMs = pathTtlMs
        self.clock = clock
        self.log = log
    }
}

/// What Kotlin throws as IllegalStateException / IllegalArgumentException from the node's send paths.
public struct NodeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A received packet handed to destination and link callbacks.
public struct Packet: Sendable {
    public let raw: [UInt8]
    public let hdr: Header
    public let hash: [UInt8]
    public let iface: String

    public init(raw: [UInt8], hdr: Header, hash: [UInt8], iface: String) {
        self.raw = raw
        self.hdr = hdr
        self.hash = hash
        self.iface = iface
    }

    public var truncatedHash: [UInt8] { Array(hash.prefix(Rns.hashLen)) }
}

/// A local SINGLE destination the node answers for.
public final class Destination: @unchecked Sendable {
    public static let ratchetCount = 512
    public static let defaultRatchetIntervalMs: Int64 = 30 * 60 * 1000

    public let name: String
    var identityOrNil: RnsIdentity?
    /// The identity; the node's own when none was given, once added to a node.
    public var identity: RnsIdentity {
        guard let id = identityOrNil else { preconditionFailure("destination \(name) not added to a node yet") }
        return id
    }
    public internal(set) var hash: [UInt8] = []
    public var hashHex: String { hash.hex }

    /// Peers may open links to this destination.
    public var acceptLinks = false
    /// Every delivered packet is answered with a proof (LXMF needs it).
    public var proveAll = false
    /// Supplies the announce app data.
    public var appData: (@Sendable () -> [UInt8]?)?
    /// Decrypted single-packet data.
    public var onPacket: (@Sendable (_ plain: [UInt8], _ pkt: Packet) -> Void)?
    /// A peer's link to this destination became active.
    public var onLink: (@Sendable (Link) -> Void)?
    /// Decrypted data on links to this destination.
    public var onLinkPacket: (@Sendable (Link, [UInt8], Packet) -> Void)?
    public var onLinkClosed: (@Sendable (Link) -> Void)?
    /// Whether resources advertised on links to this destination are received (nil rejects them).
    public var acceptResources: (@Sendable (_ size: Int) -> Bool)?
    /// A completed resource on such a link.
    public var onLinkResource: (@Sendable (Link, [UInt8]) -> Void)?

    // Ratchets (Destination.enable_ratchets / rotate_ratchets): newest first, nil = off.
    private let ratchetLock = NSLock()
    private var ratchets: [[UInt8]]?
    private var latestRatchetMs: Int64 = 0
    public var ratchetIntervalMs: Int64 = Destination.defaultRatchetIntervalMs
    /// Called with the full list (newest first) and the newest's time after a rotation, for persistence.
    public var onRatchetsChanged: (@Sendable ([[UInt8]], Int64) -> Void)?

    public init(name: String, identity: RnsIdentity? = nil) {
        self.name = name
        identityOrNil = identity
    }

    public var ratchetsEnabled: Bool {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        return ratchets != nil
    }

    /// Turns ratchets on, continuing from a persisted list (newest first) when there is one.
    public func enableRatchets(existing: [[UInt8]] = [], latestMs: Int64 = 0) {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        ratchets = existing.filter { $0.count == Rns.ratchetLen }
        latestRatchetMs = latestMs
    }

    /// The private keys, newest first, for decryption (the LXMF router decrypts propagated messages with them).
    public func ratchetPrivs() -> [[UInt8]] {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        return ratchets ?? []
    }

    /// Rotates when the newest is older than the interval and returns the newest public key, or nil when off.
    func rotateRatchets(nowMs: Int64) -> [UInt8]? {
        var changed: [[UInt8]]?
        var latest: Int64 = 0
        ratchetLock.lock()
        guard var list = ratchets else {
            ratchetLock.unlock()
            return nil
        }
        if list.isEmpty || nowMs > latestRatchetMs + ratchetIntervalMs {
            list.insert(RnsIdentity.generateRatchet(), at: 0)
            latestRatchetMs = nowMs
            while list.count > Destination.ratchetCount { list.removeLast() }
            ratchets = list
            changed = list
        }
        latest = latestRatchetMs
        let pub = RnsIdentity.ratchetPublic(list[0])
        ratchetLock.unlock()
        if let changed { onRatchetsChanged?(changed, latest) }
        return pub
    }

    public func latestRatchetPub() -> [UInt8]? {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        guard let first = ratchets?.first else { return nil }
        return RnsIdentity.ratchetPublic(first)
    }
}

/// What an announce taught us about a remote destination.
public final class KnownIdentity: @unchecked Sendable {
    public let destHash: [UInt8]
    public var publicKey: [UInt8] = []
    public var identity: RnsIdentity?
    public var appData: [UInt8]?
    /// 32-byte x25519 pub or nil.
    public var ratchet: [UInt8]?
    public var ratchetAtMs: Int64 = 0
    public var lastSeenMs: Int64 = 0

    init(destHash: [UInt8]) { self.destHash = destHash }
}

/// Monotonic counters.
public struct Stats: Sendable, Equatable {
    public var rxPackets: Int64 = 0
    public var txPackets: Int64 = 0
    public var dropped: Int64 = 0
    public var filtered: Int64 = 0
    public var announcesRx: Int64 = 0
    public var announcesTx: Int64 = 0
    public var forwarded: Int64 = 0
    public var linkTransit: Int64 = 0
    public var pathRequestsRx: Int64 = 0
    public var ifacViolations: Int64 = 0
    /// Announces, path responses and path requests sent on a paid interface under its policy, and those held back.
    public var paidTx: Int64 = 0
    public var paidSuppressed: Int64 = 0

    public init() {}
}

public final class Node: @unchecked Sendable {
    public let cfg: NodeConfig
    let tx: any Transmitter

    public var identity: RnsIdentity { cfg.identity }
    /// The transport id this node writes into HEADER_2 packets.
    public let idHash: [UInt8]
    public var idHashHex: String { idHash.hex }

    let lock = NSRecursiveLock()
    /// The node's clock, milliseconds; everything timed in the stack reads this one.
    public func now() -> Int64 { cfg.clock.nowMs() }
    func log(_ msg: String) { cfg.log(msg) }

    var dests: [String: Destination] = [:]
    public let paths: PathTable
    var identities: [String: KnownIdentity] = [:]
    var hashlist = Set<String>()
    var hashlistPrev = Set<String>()

    var announceTable: [String: AnnounceEntry] = [:]
    var heldAnnounces: [String: AnnounceEntry] = [:]
    var announceQueues: [String: AnnounceQueue] = [:]

    var linkTable: [String: LinkEntry] = [:]
    var reverseTable: [String: ReverseEntry] = [:]

    var discoveryPRs: [String: DiscoveryEntry] = [:]
    var prTags = Set<String>()
    var prTagsPrev = Set<String>()
    var inflightPRs: [String: Int64] = [:]
    var pathWaiters: [String: [Promise<Bool>]] = [:]

    var receipts: [String: Receipt] = [:]
    var ifacs: [String: Ifac] = [:]

    var paid: [String: PaidPolicy] = [:]
    var paidLast: [PaidKey: Int64] = [:]
    var crossings: [CrossingKey: Int64] = [:]

    public private(set) var links: LinkManager!

    /// Every valid announce accepted into the path table (not our own destinations).
    public var onAnnounce: (@Sendable (Announce, Packet) -> Void)?
    /// A path table entry was added or replaced.
    public var onPathChanged: (@Sendable (_ dest: [UInt8], _ entry: PathEntry) -> Void)?
    /// A data packet crossed a paid link with a policy, at most once a minute per interface, destination and direction.
    public var onPaidCrossing: (@Sendable (PaidCrossing) -> Void)?

    var statsRaw = Stats()
    private var runningRaw = false
    private var jobTask: Task<Void, Never>?
    /// Kotlin's scheduler.schedule: one-shots the jobs tick fires once due.
    var timers: [(due: Int64, task: @Sendable () -> Void)] = []

    public init(cfg: NodeConfig, tx: any Transmitter) {
        precondition(cfg.identity.hasPrivateKey, "node identity needs a private key")
        self.cfg = cfg
        self.tx = tx
        idHash = cfg.identity.hash
        let clock = cfg.clock
        paths = PathTable(ttlMs: cfg.pathTtlMs, now: { clock.nowMs() })
        links = LinkManager(node: self)
    }

    public func stats() -> Stats { lock.sync { statsRaw } }
    func count(_ f: (inout Stats) -> Void) { lock.sync { f(&statsRaw) } }

    // MARK: Local destinations and known identities

    /// Registers a local destination; its hash is computed from the identity and name.
    @discardableResult
    public func addDestination(_ d: Destination) -> Destination {
        if d.identityOrNil == nil { d.identityOrNil = cfg.identity }
        d.hash = d.identity.destHash(d.name)
        lock.sync { dests[d.hashHex] = d }
        return d
    }

    /// A destination built without an identity gets the node's.
    @discardableResult
    public func addDestination(_ name: String, configure: (Destination) -> Void = { _ in }) -> Destination {
        let d = Destination(name: name, identity: cfg.identity)
        configure(d)
        return addDestination(d)
    }

    public func localDestination(_ hash: [UInt8]) -> Destination? { lock.sync { dests[hash.hex] } }

    public func localDestinations() -> [Destination] { lock.sync { Array(dests.values) } }

    /// What is known about a destination, or nil.
    public func recall(_ dest: [UInt8]) -> KnownIdentity? { lock.sync { identities[dest.hex] } }

    public func knownIdentities() -> [KnownIdentity] { lock.sync { Array(identities.values) } }

    /// Stores a destination's public key without an announce (a persisted row, a link-identified peer).
    @discardableResult
    public func remember(dest: [UInt8], pub: [UInt8], appData: [UInt8]? = nil, ratchet: [UInt8]? = nil, ratchetAtMs: Int64 = 0) -> Bool {
        guard let id = RnsIdentity.fromPublicBytesOrNil(pub) else { return false }
        lock.sync {
            let k =
                identities[dest.hex]
                ?? {
                    let n = KnownIdentity(destHash: dest)
                    identities[dest.hex] = n
                    return n
                }()
            k.publicKey = pub
            k.identity = id
            if let appData { k.appData = appData }
            if let ratchet, ratchet.count == Rns.ratchetLen {
                k.ratchet = ratchet
                k.ratchetAtMs = ratchetAtMs
            }
            k.lastSeenMs = now()
        }
        return true
    }

    /// Enables interface access codes on one interface (nil disables).
    public func setIfac(_ ifaceId: String, _ f: Ifac?) { lock.sync { ifacs[ifaceId] = f } }

    // MARK: Lifecycle

    public var isRunning: Bool { lock.sync { runningRaw } }

    /// Starts the periodic jobs (Transport.jobs), every 250 ms on one task.
    public func start() {
        let clock = cfg.clock
        lock.sync {
            guard !runningRaw else { return }
            runningRaw = true
            jobTask = Task.detached(priority: .utility) { [weak self] in
                while true {
                    await clock.sleep(ms: 250)
                    guard let s = self, s.isRunning else { return }
                    s.jobs()
                }
            }
        }
    }

    public func stop() {
        let task: Task<Void, Never>? = lock.sync {
            guard runningRaw else { return nil }
            runningRaw = false
            let t = jobTask
            jobTask = nil
            return t
        }
        guard let task else { return }
        links.closeAll()
        task.cancel()
    }

    /// Runs `task` after `delayMs` from the jobs tick; at once when the node is not running (as Kotlin's shut-down scheduler).
    func schedule(delayMs: Int64, _ task: @escaping @Sendable () -> Void) {
        let inline: Bool = lock.sync {
            if !runningRaw { return true }
            timers.append((due: now() + max(0, delayMs), task: task))
            return false
        }
        if inline { task() }
    }

    func jobs() {
        let nowMs = now()
        processAnnounceTable(nowMs)
        expireTables(nowMs)
        expireReceipts(nowMs)
        expireDiscovery(nowMs)
        links.watchdog(nowMs)
        let due: [@Sendable () -> Void] = lock.sync {
            if hashlist.count > 50_000 {
                hashlistPrev = hashlist
                hashlist = []
            }
            if prTags.count > 20_000 {
                prTagsPrev = prTags
                prTags = []
            }
            let fire = timers.filter { $0.due <= nowMs }.map { $0.task }
            timers.removeAll { $0.due <= nowMs }
            return fire
        }
        for t in due { t() }
    }

    // MARK: Inbound

    /// Processes one raw packet received on `ifaceId`. True when the RNS layer consumed it, false when it is
    /// not an RNS packet this node handles (the caller may then try the MeshSat-private framing).
    @discardableResult
    public func inbound(_ rawIn: [UInt8], iface ifaceId: String) -> Bool {
        guard rawIn.count >= Rns.headerMinSize else { return false }
        var raw: [UInt8]
        var hdr: Header
        switch unwrapInbound(rawIn, ifaceId: ifaceId) {
        case .consumed: return true
        case .notOurs: return false
        case .packet(let r, let h):
            raw = r
            hdr = h
        }
        noteCrossing(ifaceId, raw, inbound: true)
        let hash = Header.packetHash(raw)
        count { $0.rxPackets += 1 }

        if !packetFilter(Packet(raw: raw, hdr: hdr, hash: hash, iface: ifaceId)) {
            count { $0.filtered += 1 }
            return true
        }

        // hops++ as Transport.inbound does before anything else; a paid link with extra hops counts as
        // more than one hop for every packet.
        let extra = paidExtraHops(ifaceId)
        if extra > 0, hdr.hops + 1 + extra <= 255 { hdr.hops += extra }
        hdr.hops += 1
        raw[1] = UInt8(hdr.hops & 0xFF)
        let pkt = Packet(raw: raw, hdr: hdr, hash: hash, iface: ifaceId)

        let destKey = hdr.destHash.hex
        lock.sync {
            let inLinkTable = linkTable[destKey] != nil
            let remember = !inLinkTable && !(hdr.packetType == Rns.packetProof && hdr.context == Rns.ctxLrProof)
            if remember { hashlist.insert(hash.hex) }
        }

        // Packets in transport: are we the designated next hop?
        if hdr.headerType == Rns.header2, hdr.packetType != Rns.packetAnnounce {
            if hdr.transportId != idHash { return true }
            if forwardTransport(pkt) { return true }
            // No path: Python drops; a link request to a local destination carrying our own transport id still gets delivered below.
            if hdr.packetType != Rns.packetLinkRequest { return true }
        }

        // Link transport: packets for links we carry in transit.
        if hdr.packetType != Rns.packetAnnounce, hdr.packetType != Rns.packetLinkRequest, hdr.context != Rns.ctxLrProof {
            if linkTransit(pkt) { return true }
        }
        return dispatch(pkt)
    }

    private enum Unwrapped {
        case consumed
        case notOurs
        case packet([UInt8], Header)
    }

    /// The IFAC check and the transport-header strip in front of Transport.inbound.
    private func unwrapInbound(_ rawIn: [UInt8], ifaceId: String) -> Unwrapped {
        var raw: [UInt8]
        if let f = lock.sync({ ifacs[ifaceId] }) {
            guard let clean = try? f.unwrap(rawIn) else {
                count { $0.ifacViolations += 1 }
                return .consumed
            }
            raw = clean
        } else if Ifac.hasFlag(rawIn) {
            count { $0.ifacViolations += 1 }
            return .consumed
        } else {
            raw = rawIn
        }
        guard var hdr = Header.unpackOrNil(raw) else { return .notOurs }
        // A peer that counts us more than one hop away (extra hops on a paid link, the satellite) inserts a
        // transport header with OUR destination hash as the next hop, because our announce reached it
        // directly. That packet is ours: strip the transport header and take it as the HEADER_1 packet it
        // would have been. MeshSat extension; a stock node never sees a direct peer beyond one hop.
        if hdr.headerType == Rns.header2, hdr.packetType != Rns.packetAnnounce, let tid = hdr.transportId, tid != idHash,
            localDestination(hdr.destHash) != nil, localDestination(tid) != nil
        {
            raw = Header.stripTransport(raw)
            guard let stripped = Header.unpackOrNil(raw) else { return .notOurs }
            hdr = stripped
        }
        return .packet(raw, hdr)
    }

    /// The packet-type branches of Transport.inbound for a packet that is not in transit.
    private func dispatch(_ pkt: Packet) -> Bool {
        let hdr = pkt.hdr
        switch hdr.packetType {
        case Rns.packetAnnounce:
            return handleAnnounce(pkt)

        case Rns.packetLinkRequest:
            if hdr.destType != Rns.destSingle { return true }
            if let d = localDestination(hdr.destHash) {
                links.accept(d, pkt)
                return true
            }
            return forwardHeader1(pkt)

        case Rns.packetData:
            switch hdr.destType {
            case Rns.destLink:
                if let l = links.active(hdr.destHash) {
                    links.receive(l, pkt)
                    return true
                }
                return false  // a link we do not hold: not ours (legacy MeshSat contexts on a LINK dest)
            case Rns.destPlain:
                if hdr.destHash == Rns.pathRequestDestHash {
                    handlePathRequest(pkt)
                    return true
                }
                return false  // legacy MeshSat path requests and so on
            case Rns.destSingle:
                if let d = localDestination(hdr.destHash) {
                    deliverLocal(d, pkt)
                    return true
                }
                return forwardHeader1(pkt)
            default:
                return false
            }

        case Rns.packetProof:
            switch hdr.context {
            case Rns.ctxLrProof:
                if lrProofTransit(pkt) { return true }
                links.handleProof(pkt)
                return true
            case Rns.ctxResourcePrf:
                if let l = links.active(hdr.destHash) {
                    links.receive(l, pkt)
                    return true
                }
                return false
            default:
                proofTransit(pkt)
                handleReceiptProof(pkt)
                return true
            }

        default:
            return false
        }
    }

    /// Transport.packet_filter for a transport instance.
    func packetFilter(_ pkt: Packet) -> Bool {
        let h = pkt.hdr
        if h.headerType == Rns.header2, h.packetType != Rns.packetAnnounce, h.transportId != idHash { return false }
        switch h.context {
        case Rns.ctxKeepalive, Rns.ctxResourceReq, Rns.ctxResourcePrf, Rns.ctxResource, Rns.ctxCacheRequest, Rns.ctxChannel:
            return true
        default:
            break
        }
        if h.destType == Rns.destPlain || h.destType == Rns.destGroup {
            if h.packetType == Rns.packetAnnounce { return false }
            return h.hops <= 1
        }
        let key = pkt.hash.hex
        let seen = lock.sync { hashlist.contains(key) || hashlistPrev.contains(key) }
        if !seen { return true }
        return h.packetType == Rns.packetAnnounce && h.destType == Rns.destSingle
    }

    /// Decrypts a single-packet DATA for a local destination.
    func deliverLocal(_ d: Destination, _ pkt: Packet) {
        guard pkt.hdr.context == Rns.ctxNone else { return }
        guard let plain = (try? d.identity.decrypt(pkt.hdr.data, ratchetPrivs: d.ratchetPrivs()))?.plaintext else {
            log("rns: could not decrypt packet for \(d.name) on \(pkt.iface)")
            return
        }
        d.onPacket?(plain, pkt)
        if d.proveAll { prove(d, pkt) }
    }

    /// Answers a delivered packet with an implicit proof on the receiving interface (Identity.prove).
    func prove(_ d: Destination, _ pkt: Packet) {
        guard let sig = try? d.identity.sign(pkt.hash), let raw = try? Proof.packet(provedRaw: pkt.raw, proofData: sig) else { return }
        transmit(pkt.iface, raw)
    }

    @discardableResult
    func transmit(_ ifaceId: String, _ raw: [UInt8]) -> Bool {
        let f: Ifac? = lock.sync {
            statsRaw.txPackets += 1
            return ifacs[ifaceId]
        }
        let out: [UInt8]
        if let f {
            guard let wrapped = try? f.wrap(raw) else {
                log("rns: IFAC wrap on \(ifaceId) failed")
                return false
            }
            out = wrapped
        } else {
            out = raw
        }
        if !tx.transmit(ifaceId: ifaceId, raw: out) {
            log("rns: transmit on \(ifaceId) failed")
            return false
        }
        noteCrossing(ifaceId, raw, inbound: false)
        return true
    }
}
