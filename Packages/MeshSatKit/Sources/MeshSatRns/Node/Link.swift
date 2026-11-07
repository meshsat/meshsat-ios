// Mirrors rns/Link.kt: an RNS link (RNS/Link.py), initiated by us or accepted for a local
// destination, and the manager that holds the pending and active ones. Lock order where locks
// nest: link.mu, then the manager's mu, then the node's lock (a link packet transmits under the
// link lock, as Kotlin does).
import Foundation
import MeshSatNet

/// RNS.Link status.
public enum LinkState: Sendable {
    case pending
    case handshake
    case active
    case stale
    case closed
}

/// An RNS link, initiated by us or accepted for a local destination (RNS/Link.py).
public final class Link: CustomStringConvertible, @unchecked Sendable {
    public let id: [UInt8]
    /// The remote destination (initiator) or the local destination (responder).
    public let dest: [UInt8]
    public let initiator: Bool
    public var idHex: String { id.hex }
    public internal(set) var iface: String {
        get { mu.sync { ifaceRaw } }
        set { mu.sync { ifaceRaw = newValue } }
    }
    private var ifaceRaw = ""

    let mu = NSRecursiveLock()
    var stateRaw = LinkState.pending
    /// Our ephemeral x25519 private key.
    var prv: [UInt8]?
    /// Ephemeral ed25519 seed (initiator); the responder signs with its identity.
    var sigSeed: [UInt8]?
    var signer: (@Sendable ([UInt8]) throws -> [UInt8])?
    var peerPub: [UInt8]?
    var peerSigPub: [UInt8]?
    var key: [UInt8]?
    var token: Token?
    public internal(set) var mtu: Int {
        get { mu.sync { mtuRaw } }
        set { mu.sync { mtuRaw = newValue } }
    }
    public internal(set) var mdu: Int {
        get { mu.sync { mduRaw } }
        set { mu.sync { mduRaw = newValue } }
    }
    private var mtuRaw = Rns.mtu
    private var mduRaw = LinkWire.mdu(Rns.mtu)
    var rttMsRaw: Int64 = 0
    var keepaliveMs: Int64 = Int64(Rns.keepaliveMax) * 1000
    var staleTimeMs: Int64 = 2 * Int64(Rns.keepaliveMax) * 1000
    var requestTimeMs: Int64 = 0
    var establishTimeoutMs: Int64 = 0
    var activatedAtMs: Int64 = 0
    var lastInboundMs: Int64 = 0
    var lastOutboundMs: Int64 = 0
    var lastKeepaliveMs: Int64 = 0
    var lastProofMs: Int64 = 0
    var staleSinceMs: Int64 = 0
    var expectedHops = 1
    /// 64-byte public key once identified.
    var remoteIdent: [UInt8]?
    var local: Destination?
    /// Initiator: the destination identity.
    var destIdentity: RnsIdentity?
    var resources: LinkResources?
    /// Requests we sent and still wait for, by request id (Link.pending_requests).
    var pendingRequests: [String: RequestReceipt] = [:]

    /// Whether an advertised resource of the given data size is received; nil rejects every resource.
    public var acceptResources: (@Sendable (_ size: Int) -> Bool)?
    /// A completed incoming resource.
    public var onResource: (@Sendable (Link, [UInt8]) -> Void)?
    public var onEstablished: (@Sendable (Link) -> Void)?
    public var onPacket: (@Sendable (Link, [UInt8], Packet) -> Void)?
    public var onClosed: (@Sendable (Link) -> Void)?
    public var onIdentified: (@Sendable (Link, [UInt8]) -> Void)?
    /// Resource and other contexts not handled here.
    public var onContext: (@Sendable (Link, Packet) -> Void)?

    /// Completes when the link is active (initiator side), or fails when it does.
    public let established = Promise<Link>()
    /// Completes when the link closes.
    public let closed = Promise<Link>()

    init(id: [UInt8], dest: [UInt8], initiator: Bool) {
        self.id = id
        self.dest = dest
        self.initiator = initiator
    }

    public var state: LinkState { mu.sync { stateRaw } }
    public var rttMs: Int64 { mu.sync { rttMsRaw } }
    public var remoteIdentity: [UInt8]? { mu.sync { remoteIdent } }
    public var keepalive: Int64 { mu.sync { keepaliveMs } }
    /// How long the initiator waits for the proof: the per-hop timeout times the path's hops plus one.
    public var establishTimeout: Int64 { establishTimeoutMs }

    public func encrypt(_ plain: [UInt8]) throws -> [UInt8] {
        guard let t = mu.sync({ token }) else { throw NodeError("link has no key yet") }
        return try t.encrypt(plain)
    }

    /// Nil when the token does not verify.
    public func decrypt(_ ct: [UInt8]) -> [UInt8]? {
        guard let t = mu.sync({ token }) else { return nil }
        return try? t.decrypt(ct)
    }

    func sign(_ data: [UInt8]) throws -> [UInt8] {
        guard let s = mu.sync({ signer }) else { throw NodeError("link cannot sign") }
        return try s(data)
    }

    func noteProof(_ nowMs: Int64) { mu.sync { lastProofMs = nowMs } }

    func res() -> LinkResources {
        mu.sync {
            if let r = resources { return r }
            let r = LinkResources()
            resources = r
            return r
        }
    }

    public var description: String { "<Link \(idHex) \(state)>" }
}

/// Pending and active links.
public final class LinkManager: @unchecked Sendable {
    unowned let n: Node
    private let mu = NSRecursiveLock()
    private var pending: [String: Link] = [:]
    private var links: [String: Link] = [:]

    init(node: Node) { n = node }

    func node() -> Node { n }

    /// An active (or stale) link by id.
    func active(_ id: [UInt8]) -> Link? { mu.sync { links[id.hex] } }

    /// Any known link by id.
    public func get(_ id: [UInt8]) -> Link? { mu.sync { links[id.hex] ?? pending[id.hex] } }

    public func all() -> [Link] { mu.sync { Array(pending.values) + Array(links.values) } }

    /// Caller holds l.mu.
    private func updateKeepalive(_ l: Link) {
        var ka = Int64(Double(l.rttMsRaw) * (Double(Rns.keepaliveMax) / 1.75))
        if ka > Int64(Rns.keepaliveMax) * 1000 { ka = Int64(Rns.keepaliveMax) * 1000 }
        if ka < Int64(Rns.keepaliveMin) * 1000 { ka = Int64(Rns.keepaliveMin) * 1000 }
        l.keepaliveMs = ka
        l.staleTimeMs = 2 * ka
    }

    /// Opens a link to a remote destination known from an announce.
    public func initiate(_ dest: [UInt8]) throws -> Link {
        guard let destId = n.recall(dest)?.identity else { throw NodeError("destination \(dest.hex8) identity unknown") }
        let prv = RnsIdentity.generateX25519()
        let sigSeed = RnsIdentity.generateSigningSeed()
        guard let ephPub = RnsIdentity.ratchetPublic(prv), let ephSigPub = RnsIdentity.signingPublicOfSeed(sigSeed) else {
            throw NodeError("ephemeral key generation failed")
        }
        var mtu = Rns.mtu
        let ifc = n.nextHopInterface(dest)
        if !ifc.isEmpty {
            let hw = n.tx.hwMtu(ifaceId: ifc)
            if hw >= 1, hw < mtu { mtu = hw }
        }
        let lr = LinkWire.Request(ephPub: ephPub, ephSigPub: ephSigPub, mtu: mtu, mode: LinkWire.modeAes256Cbc)
        let raw = try Header(
            headerType: Rns.header1, destType: Rns.destSingle, packetType: Rns.packetLinkRequest, destHash: dest, context: Rns.ctxNone,
            data: lr.pack()
        ).pack()
        let id = try LinkWire.linkIdFromRequestPacket(raw)
        let hops = max(1, n.paths.hops(dest))
        let nowMs = n.now()
        let l = Link(id: id, dest: dest, initiator: true)
        l.prv = prv
        l.sigSeed = sigSeed
        l.signer = { data in
            guard let s = RnsIdentity.signWithSeed(sigSeed, data) else { throw NodeError("ephemeral signing failed") }
            return s
        }
        l.peerSigPub = destId.sigPubRaw
        l.destIdentity = destId
        l.mtu = mtu
        l.mdu = LinkWire.mdu(mtu)
        l.requestTimeMs = nowMs
        l.establishTimeoutMs = Int64(Rns.perHopTimeout * hops + 6) * 1000
        l.expectedHops = hops
        mu.sync { pending[l.idHex] = l }
        let ifaces = n.outbound(raw, dest: dest, destType: Rns.destSingle)
        if ifaces.isEmpty {
            mu.sync { pending[l.idHex] = nil }
            throw NodeError("no path to \(dest.hex8) and nothing to flood on")
        }
        if ifaces.count == 1 { l.iface = ifaces[0] }
        l.lastOutboundMs = nowMs
        n.log("rns: link request sent \(l.idHex.prefix(8)) -> \(dest.hex8)")
        return l
    }

    /// Answers a link request for a local destination (Link.validate_request + prove).
    func accept(_ d: Destination, _ pkt: Packet) {
        guard d.acceptLinks else { return }
        let h = pkt.hdr
        let lr: LinkWire.Request
        do {
            lr = try LinkWire.Request.unpack(h.data)
        } catch {
            n.log("rns: bad link request: \(error)")
            return
        }
        guard let id = try? LinkWire.linkIdFromRequestPacket(pkt.raw) else { return }
        var mtu = Rns.mtu
        if lr.signalled {
            mtu = lr.mtu
            let hw = n.tx.hwMtu(ifaceId: pkt.iface)
            if hw >= 1, hw < mtu { mtu = hw }
        }
        let prv = RnsIdentity.generateX25519()
        guard let shared = RnsIdentity.x25519Agree(prv: prv, pub: lr.ephPub), let ephPub = RnsIdentity.ratchetPublic(prv) else { return }
        let key = LinkWire.deriveLinkKey(shared: shared, linkId: id)
        guard let token = try? Token(key: key) else { return }
        let nowMs = n.now()
        let l = Link(id: id, dest: d.hash, initiator: false)
        l.iface = pkt.iface
        l.stateRaw = .handshake
        l.prv = prv
        let identity = d.identity
        l.signer = { data in try identity.sign(data) }
        l.peerPub = lr.ephPub
        l.peerSigPub = lr.ephSigPub
        l.key = key
        l.token = token
        l.mtu = mtu
        l.mdu = LinkWire.mdu(mtu)
        l.requestTimeMs = nowMs
        l.local = d
        l.establishTimeoutMs = Int64(Rns.perHopTimeout * max(1, h.hops) + 6) * 1000
        l.acceptResources = d.acceptResources
        mu.sync { links[l.idHex] = l }

        let signed = LinkWire.proofSignedData(
            linkId: id, ephPub: ephPub, identitySigPub: identity.sigPubRaw, mtu: mtu, mode: LinkWire.modeAes256Cbc)
        guard let sig = try? identity.sign(signed) else { return }
        let lp = LinkWire.ProofData(signature: sig, ephPub: ephPub, mtu: mtu, mode: LinkWire.modeAes256Cbc)
        guard
            let raw = try? Header(
                headerType: Rns.header1, destType: Rns.destLink, packetType: Rns.packetProof, destHash: id, context: Rns.ctxLrProof,
                data: lp.pack()
            ).pack()
        else { return }
        l.lastOutboundMs = nowMs
        n.transmit(pkt.iface, raw)
        n.log("rns: link request accepted \(l.idHex.prefix(8)) for \(d.name) on \(pkt.iface), proof sent")
    }

    /// Validates a link request proof for one of our pending links.
    func handleProof(_ pkt: Packet) {
        let h = pkt.hdr
        guard let l = mu.sync({ pending[h.destHash.hex] }) else { return }
        guard let lp = try? LinkWire.ProofData.unpack(h.data), lp.mode == LinkWire.modeAes256Cbc else { return }
        let established: Bool = l.mu.sync {
            guard l.stateRaw == .pending, let destId = l.destIdentity, let prv = l.prv else { return false }
            let confirmedMtu = lp.signalled ? lp.mtu : Rns.mtu
            let signed = LinkWire.proofSignedData(
                linkId: l.id, ephPub: lp.ephPub, identitySigPub: destId.sigPubRaw, mtu: lp.mtu, mode: lp.mode, signalled: lp.signalled)
            guard destId.verify(signed, signature: lp.signature) else {
                n.log("rns: invalid link proof signature \(l.idHex.prefix(8))")
                return false
            }
            guard let shared = RnsIdentity.x25519Agree(prv: prv, pub: lp.ephPub) else { return false }
            let key = LinkWire.deriveLinkKey(shared: shared, linkId: l.id)
            guard let token = try? Token(key: key) else { return false }
            l.peerPub = lp.ephPub
            l.key = key
            l.token = token
            l.mtu = confirmedMtu
            l.mdu = LinkWire.mdu(confirmedMtu)
            let nowMs = n.now()
            l.rttMsRaw = nowMs - l.requestTimeMs
            l.iface = pkt.iface
            l.stateRaw = .active
            l.activatedAtMs = nowMs
            l.lastProofMs = nowMs
            l.lastInboundMs = nowMs
            updateKeepalive(l)
            mu.sync {
                pending[l.idHex] = nil
                links[l.idHex] = l
            }
            // The RTT packet activates the responder side.
            if let ct = try? token.encrypt(LinkWire.rttData(Double(l.rttMsRaw) / 1000.0)) {
                sendLinkPacket(l, Rns.packetData, Rns.ctxLrrtt, ct)
            }
            n.log("rns: link established \(l.idHex.prefix(8)) -> \(l.dest.hex8) rtt=\(l.rttMsRaw)ms mtu=\(confirmedMtu)")
            return true
        }
        guard established else { return }
        l.established.complete(l)
        l.onEstablished?(l)
    }

    /// Transmits a packet on the link's interface (Transport.outbound for LINK destinations). Caller holds l.mu.
    @discardableResult
    func sendLinkPacket(_ l: Link, _ ptype: Int, _ context: Int, _ data: [UInt8]) -> [UInt8] {
        guard
            let raw = try? Header(
                headerType: Rns.header1, destType: Rns.destLink, packetType: ptype, destHash: l.id, context: context, data: data
            )
            .pack()
        else { return [] }
        l.lastOutboundMs = n.now()
        if context == Rns.ctxKeepalive { l.lastKeepaliveMs = l.lastOutboundMs }
        n.transmit(l.iface, raw)
        return raw
    }

    /// Encrypts and sends plaintext as a link DATA packet; the receipt resolves when the peer's proof arrives.
    @discardableResult
    public func send(_ l: Link, _ plain: [UInt8]) throws -> Receipt {
        try l.mu.sync {
            guard l.stateRaw == .active || l.stateRaw == .stale else { throw NodeError("link not active") }
            guard plain.count <= l.mduRawValue else { throw NodeError("plaintext \(plain.count) exceeds the link MDU \(l.mduRawValue)") }
            guard let token = l.token else { throw NodeError("link has no key yet") }
            let ct = try token.encrypt(plain)
            let raw = sendLinkPacket(l, Rns.packetData, Rns.ctxNone, ct)
            // Link proofs are signed by the peer's link signing key: the destination identity when we
            // initiated, the initiator's ephemeral key otherwise.
            let nowMs = n.now()
            let r = Receipt(
                hash: Header.packetHash(raw), dest: l.id, sentAtMs: nowMs,
                timeoutAtMs: nowMs + Int64(Rns.perHopTimeout * max(1, l.expectedHops) + 6) * 1000, sigPub: l.peerSigPub, link: l)
            n.addReceipt(r)
            return r
        }
    }

    /// Sends a payload with a specific context on the link; used by resource transfer.
    func sendContext(_ l: Link, _ ptype: Int, _ context: Int, _ data: [UInt8]) {
        l.mu.sync { _ = sendLinkPacket(l, ptype, context, data) }
    }

    /// Tells the responder who we are (Link.identify).
    public func identify(_ l: Link, _ id: RnsIdentity) throws {
        try l.mu.sync {
            guard l.initiator, l.stateRaw == .active, let token = l.token else {
                throw NodeError("identify needs an active initiated link")
            }
            sendLinkPacket(l, Rns.packetData, Rns.ctxLinkIdentify, try token.encrypt(try LinkWire.identifyData(identity: id, linkId: l.id)))
        }
    }

    /// Closes a link and tells the peer (Link.teardown).
    public func teardown(_ l: Link) {
        let wasClosed: Bool = l.mu.sync {
            if l.stateRaw == .closed { return true }
            if l.stateRaw == .active || l.stateRaw == .stale, let token = l.token, let ct = try? token.encrypt(l.id) {
                sendLinkPacket(l, Rns.packetData, Rns.ctxLinkClose, ct)
            }
            l.stateRaw = .closed
            return false
        }
        if wasClosed { return }
        closed(l)
    }

    func closed(_ l: Link) {
        mu.sync {
            links[l.idHex] = nil
            pending[l.idHex] = nil
        }
        n.log("rns: link closed \(l.idHex.prefix(8))")
        failRequestsOn(l, "link closed")
        l.established.fail(NodeError("link closed"))
        l.closed.complete(l)
        l.onClosed?(l)
        l.local?.onLinkClosed?(l)
    }

    /// Dispatches a packet addressed to an active link (Link.receive).
    func receive(_ l: Link, _ pkt: Packet) {
        let h = pkt.hdr
        let nowMs = n.now()
        let state: LinkState? = l.mu.sync {
            if pkt.iface != l.ifaceRawValue {
                n.log("rns: link \(l.idHex.prefix(8)) packet on \(pkt.iface), want \(l.ifaceRawValue)")
                return nil
            }
            l.lastInboundMs = nowMs
            if l.stateRaw == .stale { l.stateRaw = .active }
            return l.stateRaw
        }
        guard let state else { return }

        if h.packetType == Rns.packetProof {
            if h.context == Rns.ctxResourcePrf { handleResourceProof(l, h.data) }
            return
        }
        if receiveControl(l, pkt, state: state, nowMs: nowMs) { return }
        if receiveResource(l, pkt) { return }
        switch h.context {
        case Rns.ctxNone:
            guard let plain = l.decrypt(h.data) else { return }
            l.onPacket?(l, plain, pkt)
            if let local = l.local {
                local.onLinkPacket?(l, plain, pkt)
                if local.proveAll, let sig = try? l.sign(pkt.hash) {
                    l.mu.sync { _ = sendLinkPacket(l, Rns.packetProof, Rns.ctxNone, pkt.hash + sig) }
                }
            }

        default:
            l.onContext?(l, pkt)
        }
    }

    /// The link's own control contexts (RTT, keepalive, close, identify); true when the packet was one of them.
    private func receiveControl(_ l: Link, _ pkt: Packet, state: LinkState, nowMs: Int64) -> Bool {
        let h = pkt.hdr
        switch h.context {
        case Rns.ctxLrrtt:
            if l.initiator || state != .handshake { return true }
            guard let plain = l.decrypt(h.data), let rtt = LinkWire.parseRttData(plain) else {
                teardown(l)
                return true
            }
            l.mu.sync {
                let measured = nowMs - l.requestTimeMs
                l.rttMsRaw = max(Int64(rtt * 1000), measured)
                l.stateRaw = .active
                l.activatedAtMs = nowMs
                l.expectedHops = h.hops
                updateKeepalive(l)
            }
            n.log("rns: link active \(l.idHex.prefix(8)) for \(l.local?.name ?? "?") rtt=\(l.rttMs)ms")
            l.established.complete(l)
            l.local?.onLink?(l)

        case Rns.ctxKeepalive:
            if !l.initiator, h.data.count == 1, h.data[0] == LinkWire.keepaliveInitiator {
                l.mu.sync {
                    if nowMs >= l.lastOutboundMs + l.keepaliveMs {
                        sendLinkPacket(l, Rns.packetData, Rns.ctxKeepalive, [LinkWire.keepaliveResponse])
                    }
                }
            }

        case Rns.ctxLinkClose:
            if let plain = l.decrypt(h.data), plain.count == Rns.hashLen, plain == l.id {
                l.mu.sync { l.stateRaw = .closed }
                closed(l)
            }

        case Rns.ctxLinkIdentify:
            if l.initiator { return true }
            guard let plain = l.decrypt(h.data), let pub = LinkWire.parseIdentify(plain, linkId: l.id) else { return true }
            let first: Bool = l.mu.sync {
                let f = l.remoteIdent == nil
                l.remoteIdent = pub
                return f
            }
            if first { l.onIdentified?(l, pub) }

        default:
            return false
        }
        return true
    }

    /// The resource and request contexts; true when the packet was one of them.
    private func receiveResource(_ l: Link, _ pkt: Packet) -> Bool {
        let h = pkt.hdr
        switch h.context {
        case Rns.ctxResourceAdv:
            if let plain = l.decrypt(h.data) { handleResourceAdv(l, plain) }
        case Rns.ctxResourceReq:
            if let plain = l.decrypt(h.data) { handleResourceRequest(l, plain) }
        case Rns.ctxResource:
            receivePart(l, h.data)
        case Rns.ctxResourceHmu:
            if let plain = l.decrypt(h.data) { handleResourceHmu(l, plain) }
        case Rns.ctxResourceIcl, Rns.ctxResourceRcl:
            if let plain = l.decrypt(h.data) { handleResourceCancel(l, plain) }
        case Rns.ctxResponse:
            if let plain = l.decrypt(h.data) { handleResponsePacket(l, plain) }
        default:
            return false
        }
        return true
    }

    /// Link.__watchdog_job for every link, from the node jobs.
    func watchdog(_ nowMs: Int64) {
        resourceWatchdog(nowMs)
        requestWatchdog(nowMs)
        for l in all() {
            let close: Bool = l.mu.sync {
                switch l.stateRaw {
                case .pending, .handshake:
                    if nowMs > l.requestTimeMs + l.establishTimeoutMs {
                        l.stateRaw = .closed
                        n.log("rns: link establishment timed out \(l.idHex.prefix(8))")
                        return true
                    }
                case .active:
                    var lastIn = l.lastInboundMs
                    if l.lastProofMs > lastIn { lastIn = l.lastProofMs }
                    if l.activatedAtMs > lastIn { lastIn = l.activatedAtMs }
                    if nowMs >= lastIn + l.keepaliveMs || nowMs >= l.lastOutboundMs + l.keepaliveMs {
                        if l.initiator, nowMs >= l.lastKeepaliveMs + l.keepaliveMs {
                            sendLinkPacket(l, Rns.packetData, Rns.ctxKeepalive, [LinkWire.keepaliveInitiator])
                        }
                        if nowMs >= lastIn + l.staleTimeMs {
                            l.stateRaw = .stale
                            l.staleSinceMs = nowMs
                        }
                    }
                case .stale:
                    let grace = l.rttMsRaw * 4 + Int64(Rns.staleGrace) * 1000
                    if nowMs > l.staleSinceMs + grace {
                        if let token = l.token, let ct = try? token.encrypt(l.id) {
                            sendLinkPacket(l, Rns.packetData, Rns.ctxLinkClose, ct)
                        }
                        l.stateRaw = .closed
                        return true
                    }
                case .closed:
                    break
                }
                return false
            }
            if close { closed(l) }
        }
    }

    func closeAll() { for l in all() { teardown(l) } }
}

extension Link {
    /// The raw fields for callers that already hold `mu`.
    var mduRawValue: Int { mduRaw }
    var ifaceRawValue: String { ifaceRaw }
}
