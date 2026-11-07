// Mirrors lxmf/LxmfRouter.kt (the Bridge's internal/lxmf/router.go): the LXMF endpoint
// (LXMF/LXMRouter.py 1.2.0): one lxmf.delivery destination on the node with ratchets and a
// display name, inbound delivery with stamp checks and dedup, and an outbound queue that delivers
// opportunistically (one packet), directly (a link, reused, a resource for large messages) or
// through a propagation node, with upstream's attempt limits and retry scheduling, plus the
// propagation node client (syncing what a node holds for us). [MESHSAT-1553]
//
// One message the app sends is one `Outbound` whose `state` moves outbound -> sending -> sent ->
// delivered, or failed; the app's own ledger records that, it does not retry the LXMF message
// itself (LXMF already did). Every clock reading is the node's, so a test clock drives it; the
// 1 s outbound tick is one Task on it (Kotlin's single scheduler thread).
import Foundation
import MeshSatNet
import MeshSatReticulum
import MeshSatRns
import MeshSatWire

extension NSRecursiveLock {
    @inline(__always)
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

public final class LxmfRouter: @unchecked Sendable {
    public static let pathRequestWaitMs: Int64 = 7_000
    public static let deliveryRetryWaitMs: Int64 = 10_000
    public static let maxDeliveryAttempts = 5
    public static let maxPathlessTries = 1
    /// LXMPeer.MESSAGE_GET_PATH and the error codes a node answers with.
    public static let messageGetPath = "/get"
    public static let errorNoIdentity: Int64 = 0xf0
    public static let errorNoAccess: Int64 = 0xf1
    public static let errorInvalidStamp: Int64 = 0xf5
    public static let prPathTimeoutMs: Int64 = 10_000
    public static let syncRequestTimeoutMs: Int64 = 60_000
    public static let syncTransferTimeoutMs: Int64 = 600_000

    public struct Config: Sendable {
        public var identity: RnsIdentity
        public var displayName: String
        /// Announced for inbound messages (0 = none).
        public var stampCost = 0
        /// Drops inbound messages with a missing or invalid stamp.
        public var enforceStamps = false
        /// Refuses destinations that demand more work than this.
        public var maxOutboundStampCost = 16
        /// The largest inbound resource accepted, bytes.
        public var deliveryLimit = 1000 * 1000
        /// Ratchets persisted from an earlier run (newest first) and when the newest was made.
        public var ratchets: [[UInt8]] = []
        public var ratchetsLatestMs: Int64 = 0
        public var onRatchetsChanged: (@Sendable ([[UInt8]], Int64) -> Void)?
        /// Every accepted inbound message.
        public var onMessage: (@Sendable (LxMessage) -> Void)?
        /// An outbound message changed state.
        public var onOutboundState: (@Sendable (Outbound) -> Void)?
        public var log: @Sendable (String) -> Void = { _ in }

        public init(identity: RnsIdentity, displayName: String) {
            self.identity = identity
            self.displayName = displayName
        }
    }

    /// One message in the outbound queue.
    public final class Outbound: @unchecked Sendable {
        public let message: LxMessage
        public let desiredMethod: LxMethod?
        /// Completes with the final state: delivered, failed, rejected, cancelled, or sent for a propagated message the node took.
        public let result = Promise<LxState>()
        public var hashHex: String { message.hashHex }

        struct Fields {
            var state = LxState.outbound
            var method: LxMethod
            var representation = LxRepresentation.packet
            var attempts = 0
            var maxAttempts = LxmfRouter.maxDeliveryAttempts
            var nextAttemptMs: Int64 = 0
            var awaitingPath = false
            var sentOnPath = false
            var pathRequestRetried = false
            var lastError = ""
            var deliveredAtMs: Int64 = 0
            var receipt: Receipt?
            /// PROPAGATED: msgpack([time, [dest || encrypted || stamp]]) once built, and the transient id the node files it under.
            var propagationPacked: [UInt8]?
            var transientId: [UInt8]?
        }

        private let lock = NSLock()
        private var f: Fields

        init(message: LxMessage, desiredMethod: LxMethod?) {
            self.message = message
            self.desiredMethod = desiredMethod
            f = Fields(method: desiredMethod ?? .direct)
        }

        func read<T>(_ kp: KeyPath<Fields, T>) -> T {
            lock.lock()
            defer { lock.unlock() }
            return f[keyPath: kp]
        }

        func update<T>(_ body: (inout Fields) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&f)
        }

        public var state: LxState { read(\.state) }
        public var method: LxMethod { read(\.method) }
        public var representation: LxRepresentation { read(\.representation) }
        public var attempts: Int { read(\.attempts) }
        public var maxAttempts: Int { read(\.maxAttempts) }
        public var lastError: String { read(\.lastError) }
        public var deliveredAtMs: Int64 { read(\.deliveredAtMs) }
        public var transientId: [UInt8]? { read(\.transientId) }
    }

    /// Known lxmf.delivery peers from the path table.
    public struct Peer: Sendable, Equatable {
        public let destHash: String
        public let displayName: String?
        public let stampCost: Int
        public let hops: Int
        public let iface: String
        public let lastSeenMs: Int64
        public let hasRatchet: Bool
    }

    public let node: Node
    /// Our lxmf.delivery destination.
    public let dest: Destination
    let cfg: Config
    let log: @Sendable (String) -> Void
    let lock = NSRecursiveLock()
    var seen: [String: Int64] = [:]
    var seenOrder: [String] = []
    /// Links we initiated, by delivery hash.
    var directLinks: [String: Link] = [:]
    /// Links peers initiated and identified on.
    var backchannelLinks: [String: Link] = [:]
    var pendingOutbound: [Outbound] = []
    var pathRequestTimes: [String: Int64] = [:]
    var identified = Set<String>()
    var jobs: Task<Void, Never>?
    var running = false
    var processing = false

    // Propagation nodes (P3b)
    let pnNameHash = Rns.nameHash(LxMessage.propagationName)
    var propagationNodeFixed: [UInt8]?
    var autoSelect = true
    var propagationLink: Link?
    var processedTransientIds: [String: Int64] = [:]
    var processedOrder: [String] = []
    var syncStateRaw = SyncState.idle
    var syncProgressRaw: Float = 0
    var lastSyncRaw: SyncResult?
    var syncPromise: Promise<SyncResult>?

    public init(node: Node, config: Config) {
        self.node = node
        cfg = config
        log = config.log
        let d = Destination(name: LxMessage.deliveryName, identity: config.identity)
        d.acceptLinks = true
        d.proveAll = true
        let name = config.displayName
        let cost = config.stampCost
        d.appData = { LxmfAppData.encode(displayName: name, stampCost: cost, compression: false) }
        d.enableRatchets(existing: config.ratchets, latestMs: config.ratchetsLatestMs)
        d.onRatchetsChanged = config.onRatchetsChanged
        let limit = config.deliveryLimit
        d.acceptResources = { size in (1...limit).contains(size) }
        dest = node.addDestination(d)
        wire(d)
    }

    /// The destination's callbacks into the router; outside init so the closures capture a finished `self`.
    func wire(_ d: Destination) {
        let ownHash = d.hash
        // Opportunistic: the packet carried packed[16:], prepend our hash (delivery_packet).
        d.onPacket = { [weak self] plain, pkt in _ = self?.inbound(ownHash + plain, method: .opportunistic, iface: pkt.iface) }
        d.onLink = { [weak self] l in l.onIdentified = { [weak self] link, pub in self?.onIdentified(link, pub) } }
        d.onLinkPacket = { [weak self] _, plain, pkt in _ = self?.inbound(plain, method: .direct, iface: pkt.iface) }
        d.onLinkClosed = { [weak self] l in self?.forgetLink(l) }
        d.onLinkResource = { [weak self] l, data in _ = self?.inbound(data, method: .direct, iface: l.iface) }
    }

    public var hash: [UInt8] { dest.hash }
    public var hashHex: String { dest.hashHex }
    public var displayName: String { cfg.displayName }
    public var stampCost: Int { cfg.stampCost }

    func now() -> Int64 { node.now() }
    func tag(_ m: LxMessage) -> String { "<LXMessage \(m.hashHex.prefix(16))>" }

    public func start() {
        let clock = node.cfg.clock
        lock.locked {
            guard !running else { return }
            running = true
            jobs = Task.detached(priority: .utility) { [weak self] in
                while true {
                    await clock.sleep(ms: 1000)
                    guard let self, self.isRunning else { return }
                    self.processOutbound()
                }
            }
        }
    }

    public func stop() {
        let t: Task<Void, Never>? = lock.locked {
            running = false
            let t = jobs
            jobs = nil
            return t
        }
        t?.cancel()
    }

    var isRunning: Bool { lock.locked { running } }

    /// Emits the delivery announce on every floodable interface and every paid interface open to it.
    @discardableResult
    public func announce() -> Bool { node.announce(dest) }

    // MARK: Inbound

    func sourceSigPub(_ source: [UInt8]) -> [UInt8]? { node.recall(source)?.identity?.sigPubRaw }

    /// Validates and delivers a packed message (LXMRouter.lxmf_delivery). Returns it, or nil when dropped.
    @discardableResult
    public func inbound(_ packed: [UInt8], method: LxMethod, iface: String) -> LxMessage? {
        var m: LxMessage
        do {
            m = try LxMessage.unpack(packed, sigPubOf: { [weak self] s in self?.sourceSigPub(s) })
        } catch {
            log("lxmf: could not assemble message: \(error)")
            return nil
        }
        guard m.dest == dest.hash else {
            log("lxmf: message for \(m.destHex.prefix(8)), not for us")
            return nil
        }
        m.method = method
        m.iface = iface
        m.receivedAtMs = now()
        if cfg.stampCost > 0 {
            m.stampChecked = true
            if let s = m.stamp {
                let wb = LxStamper.workblock(m.hash)
                m.stampValid = LxStamper.stampValid(workblock: wb, stamp: s, cost: cfg.stampCost)
                if m.stampValid { m.stampValue = LxStamper.stampValue(workblock: wb, stamp: s) }
            }
            if !m.stampValid, cfg.enforceStamps {
                log("lxmf: dropping \(tag(m)) with invalid stamp")
                return nil
            }
        }
        let duplicate: Bool = lock.locked {
            if seen[m.hashHex] != nil { return true }
            seen[m.hashHex] = now()
            seenOrder.append(m.hashHex)
            if seenOrder.count > 10_000 {
                for k in seenOrder.prefix(1000) { seen[k] = nil }
                seenOrder.removeFirst(1000)
            }
            return false
        }
        if duplicate { return m }  // already delivered
        if !m.sourceKnown {
            // Ask for the source so the next message verifies; this one is still delivered, flagged unverified, as upstream does.
            requestPathThrottled(m.source)
        }
        log("lxmf: message \(tag(m)) from \(m.sourceHex.prefix(8)) via \(method) valid=\(m.signatureValid) bytes=\(m.content.count)")
        cfg.onMessage?(m)
        return m
    }

    /// A peer's link became a backchannel to its delivery destination (delivery_remote_identified).
    func onIdentified(_ l: Link, _ pub: [UInt8]) {
        guard let id = RnsIdentity.fromPublicBytesOrNil(pub) else { return }
        let peer = id.destHash(LxMessage.deliveryName)
        lock.locked { backchannelLinks[Hex.encode(peer)] = l }
        node.remember(dest: peer, pub: pub)
        log("lxmf: backchannel from \(Hex.encode(peer).prefix(8)) on \(l.idHex.prefix(8))")
        trigger()
    }

    func forgetLink(_ l: Link) {
        lock.locked {
            directLinks = directLinks.filter { $0.value !== l }
            backchannelLinks = backchannelLinks.filter { $0.value !== l }
        }
    }

    /// Whether a link to `peer` exists (delivery_link_available).
    public func deliveryLinkAvailable(_ peer: [UInt8]) -> Bool {
        lock.locked {
            let k = Hex.encode(peer)
            return directLinks[k]?.state == .active || backchannelLinks[k]?.state == .active
        }
    }

    // MARK: Outbound

    /// What a peer announced: name and stamp cost, from the node's known identities.
    public func peerInfo(_ peer: [UInt8]) -> LxmfAppData.Info? {
        guard let k = node.recall(peer) else { return nil }
        return LxmfAppData.parse(k.appData)
    }

    /// Queues one message. `method` nil picks like Sideband: opportunistic when it fits one packet, no delivery
    /// link exists and the peer announced a ratchet, else direct; and always direct when the path crosses a
    /// paid link (the satellite), because opportunistic retries would each be a paid packet and a stock
    /// client's receipt timeout is shorter than the round trip. The stamp, when the peer demands one, is
    /// generated here before the message is queued.
    @discardableResult
    public func send(_ peer: [UInt8], content: [UInt8], title: [UInt8] = [], fields: [MpEntry] = [], method: LxMethod? = nil) throws
        -> Outbound
    {
        let info = peerInfo(peer)
        let cost = info?.stampCost ?? 0
        guard cost <= cfg.maxOutboundStampCost else {
            throw LxmfError("destination requires stamp cost \(cost), above the limit of \(cfg.maxOutboundStampCost)")
        }
        var m = LxMessage(dest: peer, source: dest.hash, title: title, content: content, fields: fields)
        try m.pack(source: cfg.identity, stampCost: cost, stamper: { h, c in LxStamper.generateStamp(messageId: h, cost: c)?.stamp })
        let o = Outbound(message: m, desiredMethod: method)
        let size = m.contentSize()
        var chosen = method
        if chosen == nil {
            chosen = .direct
            let k = node.recall(peer)
            if size <= LxMessage.encryptedPacketMaxContent, !deliveryLinkAvailable(peer), k?.ratchet != nil, !node.crossesPaidLink(peer) {
                chosen = .opportunistic
            }
        }
        if chosen == .opportunistic, size > LxMessage.encryptedPacketMaxContent { chosen = .direct }
        guard let chosenMethod = chosen else { throw LxmfError("no method") }
        o.update {
            $0.method = chosenMethod
            $0.representation = (chosenMethod == .direct && size > LxMessage.linkPacketMaxContent) ? .resource : .packet
        }
        if chosenMethod == .propagated, propagationNode() == nil { throw LxmfError("no propagation node known") }
        lock.locked { pendingOutbound.append(o) }
        // Pre-emptively request an unknown path for an opportunistic message (handle_outbound), and the
        // recipient's identity for a propagated one, which is encrypted for it here.
        if (chosenMethod == .opportunistic && !node.paths.has(peer)) || (chosenMethod == .propagated && node.recall(peer) == nil) {
            requestPathThrottled(peer)
            scheduleAttempt(o, peer, pathRequest: true)
        }
        log("lxmf: queued \(tag(m)) to \(Hex.encode(peer).prefix(8)) \(chosenMethod) \(o.representation) stamp_cost=\(cost)")
        cfg.onOutboundState?(o)
        trigger()
        return o
    }

    public func cancel(_ o: Outbound) {
        if o.state.terminal { return }
        setState(o, .cancelled)
    }

    public func pending() -> [Outbound] { lock.locked { pendingOutbound } }

    func trigger() {
        guard isRunning else { return }
        Task.detached(priority: .utility) { [weak self] in self?.processOutbound() }
    }

    func setState(_ o: Outbound, _ s: LxState, error: String = "") {
        let changed: Bool = o.update {
            if $0.state == s { return false }
            $0.state = s
            if !error.isEmpty { $0.lastError = error }
            if s == .delivered { $0.deliveredAtMs = now() }
            return true
        }
        guard changed else { return }
        cfg.onOutboundState?(o)
        if s.terminal { o.result.complete(s) }
    }

    func failMessage(_ o: Outbound, _ why: String) {
        lock.locked { pendingOutbound.removeAll { $0 === o } }
        log("lxmf: \(tag(o.message)) failed: \(why)")
        setState(o, o.state == .rejected ? .rejected : .failed, error: why)
    }

    /// The round trip a path promises: 6 s a hop each way (destination_round_trip, a kit's 9704 hops count).
    func roundTripMs(_ peer: [UInt8]) -> Int64 {
        let hops = node.paths.hops(peer)
        if hops < 1 { return 0 }
        return 2 * Int64(Rns.perHopTimeout * hops) * 1000
    }

    func pathRequestWaitMs() -> Int64 { max(Self.pathRequestWaitMs, mediumPathTimeoutMs()) }

    /// The longest round trip among known paths, capped: what a path request may take (medium_path_timeout).
    func mediumPathTimeoutMs() -> Int64 {
        let worst = node.paths.all().map(\.hops).max() ?? 1
        return min(2 * Int64(Rns.perHopTimeout * worst) * 1000, 120_000)
    }

    func scheduleAttempt(_ o: Outbound, _ peer: [UInt8], pathRequest: Bool = false) {
        let nowMs = now()
        let roundTrip: Int64
        if pathRequest {
            roundTrip = mediumPathTimeoutMs()
            o.update {
                $0.nextAttemptMs = nowMs + max(Self.pathRequestWaitMs, roundTrip)
                $0.awaitingPath = true
            }
        } else {
            roundTrip = roundTripMs(peer)
            o.update { $0.nextAttemptMs = nowMs + max(Self.deliveryRetryWaitMs, roundTrip) }
        }
        let maxAttempts =
            roundTrip > Self.deliveryRetryWaitMs
            ? max(3, Int((Double(Self.maxDeliveryAttempts) * Double(Self.deliveryRetryWaitMs) / Double(roundTrip)).rounded()))
            : Self.maxDeliveryAttempts
        o.update { $0.maxAttempts = maxAttempts }
    }

    func attemptDue(_ o: Outbound, _ peer: [UInt8]) -> Bool {
        let next = o.read(\.nextAttemptMs)
        if next == 0 { return true }
        if now() > next { return true }
        return o.read(\.awaitingPath) && node.paths.has(peer)
    }

    @discardableResult
    func requestPathThrottled(_ peer: [UInt8]) -> Bool {
        let window = pathRequestWaitMs()
        let k = Hex.encode(peer)
        let nowMs = now()
        let allowed: Bool = lock.locked {
            if let last = pathRequestTimes[k], nowMs - last < window { return false }
            pathRequestTimes = pathRequestTimes.filter { nowMs - $0.value < window }
            pathRequestTimes[k] = nowMs
            return true
        }
        guard allowed else { return false }
        _ = node.requestPath(peer, timeoutMs: window)
        return true
    }

    func pathRequestPending(_ peer: [UInt8]) -> Bool {
        lock.locked {
            guard let t = pathRequestTimes[Hex.encode(peer)] else { return false }
            return now() - t < pathRequestWaitMs()
        }
    }

    /// LXMRouter.process_outbound.
    func processOutbound() {
        let claimed: Bool = lock.locked {
            if processing { return false }
            processing = true
            return true
        }
        guard claimed else { return }
        defer { lock.locked { processing = false } }
        let list = lock.locked { pendingOutbound }
        for o in list {
            let state = o.state
            if state == .delivered {
                lock.locked { pendingOutbound.removeAll { $0 === o } }
                // Backchannel: identify on the link we opened so the peer can answer on it.
                let peerKey = o.message.destHex
                let l = lock.locked { directLinks[peerKey] }
                if o.method == .direct, let l, l.initiator, l.remoteIdentity == nil, !lock.locked({ identified.contains(l.idHex) }),
                    l.state == .active
                {
                    do {
                        try node.links.identify(l, cfg.identity)
                        lock.locked { _ = identified.insert(l.idHex) }
                        log("lxmf: identified on \(l.idHex.prefix(8)) for the backchannel")
                    } catch {
                        log("lxmf: identify failed: \(error)")
                    }
                }
            } else if state == .cancelled || state == .rejected {
                failMessage(o, "\(state)")
            } else if state == .generating {
                // a stamp is being generated on its own task
            } else {
                switch o.method {
                case .opportunistic: processOpportunistic(o)
                case .direct: processDirect(o)
                case .propagated: processPropagated(o)
                }
            }
        }
    }

    func processOpportunistic(_ o: Outbound) {
        let peer = o.message.dest
        if o.attempts <= o.maxAttempts {
            guard attemptDue(o, peer) else { return }
            let pathKnown = node.paths.has(peer)
            o.update { $0.awaitingPath = false }
            let attempts = o.attempts
            if attempts >= Self.maxPathlessTries, !pathKnown {
                log("lxmf: requesting path to \(Hex.encode(peer).prefix(8)) after \(attempts) pathless tries for \(tag(o.message))")
                o.update {
                    $0.attempts += 1
                    $0.sentOnPath = false
                }
                requestPathThrottled(peer)
                scheduleAttempt(o, peer, pathRequest: true)
            } else if attempts == Self.maxPathlessTries + 1, pathKnown, o.read(\.sentOnPath) {
                // Only rediscover if the previous attempt was sent along the same path.
                o.update {
                    $0.attempts += 1
                    $0.sentOnPath = false
                    $0.awaitingPath = true
                }
                if !pathRequestPending(peer) {
                    node.paths.remove(peer)
                    lock.locked { pathRequestTimes[Hex.encode(peer)] = now() }
                    _ = node.requestPath(peer, timeoutMs: pathRequestWaitMs())
                }
                let wait = pathRequestWaitMs()
                o.update { $0.nextAttemptMs = now() + wait }
            } else {
                o.update {
                    $0.attempts += 1
                    $0.sentOnPath = pathKnown
                }
                scheduleAttempt(o, peer)
                log("lxmf: opportunistic attempt \(o.attempts) for \(tag(o.message)) to \(Hex.encode(peer).prefix(8))")
                do {
                    let r = try node.sendData(peer, Array(o.message.packed[LxMessage.destLen...]), wantReceipt: true)
                    o.update { $0.receipt = r }
                    setState(o, .sent)
                    r?.result.onResult { [weak self] res in
                        guard let self, case .success(let rr) = res, rr.delivered, !o.state.terminal else { return }
                        self.setState(o, .delivered)
                        self.trigger()
                    }
                } catch {
                    log("lxmf: error sending \(tag(o.message)): \(error)")
                    failMessage(o, "\(error)")
                }
            }
        } else if attemptDue(o, peer) {
            failMessage(o, "max delivery attempts reached (opportunistic)")
        }
    }

    func processDirect(_ o: Outbound) {
        let peer = o.message.dest
        let peerKey = Hex.encode(peer)
        if o.attempts > o.maxAttempts {
            if attemptDue(o, peer) { failMessage(o, "max delivery attempts reached (direct)") }
            return
        }
        if let link = lock.locked({ directLinks[peerKey] ?? backchannelLinks[peerKey] }) {
            processDirect(o, on: link, peer: peer, peerKey: peerKey)
            return
        }
        // No link: establish one if the retry wait has elapsed.
        guard attemptDue(o, peer) else { return }
        o.update {
            $0.attempts += 1
            $0.awaitingPath = false
        }
        scheduleAttempt(o, peer)
        if o.attempts < o.maxAttempts {
            if node.paths.has(peer) {
                log("lxmf: establishing link to \(peerKey.prefix(8)) for delivery attempt \(o.attempts)")
                do {
                    let l = try node.links.initiate(peer)
                    let limit = cfg.deliveryLimit
                    l.onPacket = { [weak self] _, plain, pkt in _ = self?.inbound(plain, method: .direct, iface: pkt.iface) }
                    l.acceptResources = { size in (1...limit).contains(size) }
                    l.onResource = { [weak self] ll, data in _ = self?.inbound(data, method: .direct, iface: ll.iface) }
                    l.onEstablished = { [weak self] _ in self?.trigger() }
                    l.onClosed = { [weak self] ll in
                        self?.forgetLink(ll)
                        self?.trigger()
                    }
                    lock.locked { directLinks[peerKey] = l }
                } catch {
                    log("lxmf: link to \(peerKey.prefix(8)) not started: \(error)")
                }
            } else {
                log("lxmf: no path for delivery attempt \(o.attempts) to \(peerKey.prefix(8)), requesting one")
                requestPathThrottled(peer)
                scheduleAttempt(o, peer, pathRequest: true)
            }
        } else {
            failMessage(o, "max delivery attempts reached (direct)")
        }
    }

    /// The direct branch when a link to the peer exists: send on it, or react to its closing.
    func processDirect(_ o: Outbound, on link: Link, peer: [UInt8], peerKey: String) {
        switch link.state {
        case .active, .stale:
            if o.state != .sending {
                startTransfer(o, on: link, packed: o.message.packed, what: "transfer") { [weak self] in self?.setState(o, .delivered) }
            }
        case .closed:
            if link.established.isDone, link.established.value != nil {
                log("lxmf: link to \(peerKey.prefix(8)) closed unexpectedly, retrying the path request")
                requestPathThrottled(peer)
            } else if !o.read(\.pathRequestRetried) {
                log("lxmf: link to \(peerKey.prefix(8)) was never activated, retrying the path request")
                requestPathThrottled(peer)
                o.update { $0.pathRequestRetried = true }
            }
            forgetLink(link)
            if o.state == .sending { setState(o, .outbound) }
            if o.attempts + 1 < o.maxAttempts { scheduleAttempt(o, peer) }
        default:
            break  // pending or in handshake: wait for it to become active or close
        }
    }

    /// Puts `packed` on the link as a packet or a resource and reacts to its outcome: `delivered` on success;
    /// a timeout or failure tears the link down and returns the message to outbound; a rejection is final.
    func startTransfer(_ o: Outbound, on link: Link, packed: [UInt8], what: String, delivered: @escaping @Sendable () -> Void) {
        log("lxmf: starting \(what) of \(tag(o.message)) on \(link.idHex.prefix(8)) (\(o.representation))")
        setState(o, .sending)
        do {
            if o.representation == .packet {
                let r = try node.links.send(link, packed)
                o.update { $0.receipt = r }
                r.result.onResult { [weak self] res in
                    guard let self, !o.state.terminal else { return }
                    if case .success(let rr) = res, rr.delivered {
                        delivered()
                        self.trigger()
                    } else {
                        // __link_packet_timed_out: tear the link down, back to OUTBOUND, try again.
                        self.log("lxmf: link packet for \(self.tag(o.message)) timed out, tearing \(link.idHex.prefix(8)) down")
                        self.node.links.teardown(link)
                        self.setState(o, .outbound)
                        self.trigger()
                    }
                }
            } else {
                let res = try node.links.sendResource(link, packed)
                res.result.onResult { [weak self] out in
                    guard let self, !o.state.terminal else { return }
                    let result = (try? out.get()) ?? ResourceResult(delivered: false, error: "resource failed")
                    if result.delivered {
                        delivered()
                        self.trigger()
                    } else if result.error == "rejected by receiver" {
                        self.setState(o, .rejected, error: result.error ?? "")
                        self.trigger()
                    } else {
                        self.log(
                            "lxmf: resource for \(self.tag(o.message)) failed (\(result.error ?? "")), tearing \(link.idHex.prefix(8)) down"
                        )
                        self.node.links.teardown(link)
                        self.setState(o, .outbound, error: result.error ?? "")
                        self.trigger()
                    }
                }
            }
        } catch {
            log("lxmf: error sending \(tag(o.message)): \(error)")
            failMessage(o, "\(error)")
        }
    }

    public func peers() -> [Peer] {
        let nameHash = Rns.nameHash(LxMessage.deliveryName)
        return node.paths.all().filter { $0.announce.nameHash == nameHash }.map { e in
            let k = node.recall(e.destHash)
            let info = LxmfAppData.parse(k?.appData)
            return Peer(
                destHash: Hex.encode(e.destHash), displayName: info.displayName, stampCost: info.stampCost, hops: e.hops, iface: e.iface,
                lastSeenMs: k?.lastSeenMs ?? 0, hasRatchet: k?.ratchet != nil)
        }
    }
}
