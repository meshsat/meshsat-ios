// Mirrors rns/Receipts.kt: packet receipts (RNS.PacketReceipt) and the node's outbound path
// (Transport.outbound) for locally originated non-link packets.
import Foundation
import MeshSatNet

/// The outcome of a `Receipt`.
public struct ReceiptResult: Sendable, Equatable {
    public let delivered: Bool
    public let rttMs: Int64

    public init(delivered: Bool, rttMs: Int64 = 0) {
        self.delivered = delivered
        self.rttMs = rttMs
    }
}

/// Tracks a packet sent to a SINGLE destination (or on a link) until its proof arrives or the timeout passes.
public final class Receipt: @unchecked Sendable {
    public let hash: [UInt8]
    public let dest: [UInt8]
    public let sentAtMs: Int64
    public var timeoutAtMs: Int64
    /// The key that must sign the proof.
    let sigPub: [UInt8]?
    let link: Link?
    /// Completes once, delivered or timed out.
    public let result = Promise<ReceiptResult>()
    public var hashHex: String { hash.hex }

    init(hash: [UInt8], dest: [UInt8], sentAtMs: Int64, timeoutAtMs: Int64, sigPub: [UInt8]?, link: Link?) {
        self.hash = hash
        self.dest = dest
        self.sentAtMs = sentAtMs
        self.timeoutAtMs = timeoutAtMs
        self.sigPub = sigPub
        self.link = link
    }
}

extension Rns {
    /// Identity.RATCHET_EXPIRY: a peer's announced ratchet is used for 30 days.
    public static let ratchetExpiryMs: Int64 = 30 * 24 * 60 * 60 * 1000
}

extension Node {
    func addReceipt(_ r: Receipt) { lock.sync { receipts[r.hashHex] = r } }

    func removeReceipt(_ r: Receipt) { lock.sync { receipts[r.hashHex] = nil } }

    /// Matches a PROOF packet against outstanding receipts.
    func handleReceiptProof(_ pkt: Packet) {
        let data = pkt.hdr.data
        let candidates: [Receipt] = lock.sync {
            var out: [Receipt] = []
            if data.count == Proof.explicitLen {
                if let r = receipts[Array(data[0..<Rns.fullHashLen]).hex] { out.append(r) }
            } else if data.count == Proof.implicitLen {
                // A proof is addressed to the truncated packet hash, so those come first.
                let tr = pkt.hdr.destHash
                for r in receipts.values where Array(r.hash.prefix(Rns.hashLen)) == tr { out.append(r) }
                for r in receipts.values where r.dest == tr || pkt.hdr.destType == Rns.destLink {
                    if !out.contains(where: { $0 === r }) { out.append(r) }
                }
            }
            return out
        }
        for r in candidates {
            guard let pub = r.sigPub else { continue }
            if Proof.validate(data, packetHash: r.hash, sigPub: pub) {
                lock.sync { receipts[r.hashHex] = nil }
                r.link?.noteProof(now())
                r.result.complete(ReceiptResult(delivered: true, rttMs: now() - r.sentAtMs))
                return
            }
        }
    }

    func expireReceipts(_ nowMs: Int64) {
        let expired: [Receipt] = lock.sync {
            let out = receipts.values.filter { nowMs > $0.timeoutAtMs }
            for r in out { receipts[r.hashHex] = nil }
            return out
        }
        for r in expired { r.result.complete(ReceiptResult(delivered: false)) }
    }

    // MARK: Outbound

    /// Sends a locally originated non-link packet (Transport.outbound): along the path when one is known
    /// (HEADER_2 insertion beyond one hop), otherwise broadcast on every floodable interface. Returns the
    /// interfaces used, empty when none.
    func outbound(_ raw: [UInt8], dest: [UInt8], destType: Int) -> [String] {
        guard let hdr = Header.unpackOrNil(raw) else { return [] }
        if hdr.packetType != Rns.packetAnnounce, destType != Rns.destPlain, destType != Rns.destGroup {
            if let e = paths.get(dest), now() < e.expiresMs {
                let out = e.direct ? raw : Header.rewriteForTransport(raw, transportId: e.nextHop)
                e.timestampMs = now()
                return transmit(e.iface, out) ? [e.iface] : []
            }
        }
        let ifaces = tx.floodable()
        for id in ifaces { transmit(id, raw) }
        return ifaces
    }

    /// The known hop count to a destination or -1.
    public func hopsTo(_ dest: [UInt8]) -> Int { paths.hops(dest) }

    /// The interface a destination is reached on, or "".
    public func nextHopInterface(_ dest: [UInt8]) -> String { paths.get(dest)?.iface ?? "" }

    /// Encrypts `plaintext` for a remote SINGLE destination known from an announce and sends it as one DATA
    /// packet, to the peer's latest ratchet when it announced one. The receipt resolves when the
    /// destination's proof arrives.
    @discardableResult
    public func sendData(_ dest: [UInt8], _ plaintext: [UInt8], wantReceipt: Bool = true) throws -> Receipt? {
        guard let k = recall(dest), let id = k.identity else {
            throw NodeError("destination \(dest.hex8) identity unknown, no announce seen")
        }
        guard plaintext.count <= Rns.encryptedMdu else {
            throw NodeError("\(plaintext.count) bytes exceed the single-packet limit of \(Rns.encryptedMdu)")
        }
        var ratchet: [UInt8]?
        if let r = k.ratchet, r.count == Rns.ratchetLen, now() < k.ratchetAtMs + Rns.ratchetExpiryMs { ratchet = r }
        let ct = try id.encrypt(plaintext, ratchetPub: ratchet)
        let raw = try Header(
            headerType: Rns.header1, destType: Rns.destSingle, packetType: Rns.packetData, destHash: dest, context: Rns.ctxNone, data: ct
        ).pack()
        var receipt: Receipt?
        if wantReceipt {
            let hops = max(1, paths.hops(dest))
            let r = Receipt(
                hash: Header.packetHash(raw), dest: dest, sentAtMs: now(), timeoutAtMs: now() + Int64(Rns.perHopTimeout * hops + 6) * 1000,
                sigPub: id.sigPubRaw, link: nil)
            addReceipt(r)
            receipt = r
        }
        if outbound(raw, dest: dest, destType: Rns.destSingle).isEmpty {
            if let receipt { removeReceipt(receipt) }
            throw NodeError("no path to \(dest.hex8) and nothing to flood on")
        }
        return receipt
    }

    /// Transmits an already-built packet for `dest` along the path rules.
    @discardableResult
    public func sendRaw(_ raw: [UInt8], dest: [UInt8], destType: Int) -> Bool { !outbound(raw, dest: dest, destType: destType).isEmpty }
}
