// Mirrors rns/Transport.kt: the transport-instance half of Transport.inbound, packets we carry for
// other nodes: HEADER_2 forwarding along the path table, the MeshSat HEADER_1 insertion for the
// Meshtastic bearer, link transit, link request proofs in transit, packet proofs back along the
// reverse table, and the table sweeps.
import Foundation

/// One row of Transport.link_table: a link request we forwarded.
final class LinkEntry: @unchecked Sendable {
    var timestampMs: Int64
    let nextHop: [UInt8]
    let nextHopIface: String
    let remainingHops: Int
    let receivedIface: String
    let takenHops: Int
    let destHash: [UInt8]
    var validated = false
    let proofTimeoutMs: Int64

    init(
        timestampMs: Int64, nextHop: [UInt8], nextHopIface: String, remainingHops: Int, receivedIface: String, takenHops: Int,
        destHash: [UInt8], proofTimeoutMs: Int64
    ) {
        self.timestampMs = timestampMs
        self.nextHop = nextHop
        self.nextHopIface = nextHopIface
        self.remainingHops = remainingHops
        self.receivedIface = receivedIface
        self.takenHops = takenHops
        self.destHash = destHash
        self.proofTimeoutMs = proofTimeoutMs
    }
}

/// One row of Transport.reverse_table: a packet we forwarded whose proof must travel back.
struct ReverseEntry: Sendable {
    let receivedIface: String
    let outboundIface: String
    let timestampMs: Int64
}

extension Node {
    /// A HEADER_2 packet addressed to this transport instance (Transport.inbound, "packet.transport_id ==
    /// identity.hash"). False when no path is known.
    func forwardTransport(_ pkt: Packet) -> Bool {
        let h = pkt.hdr
        guard let entry = paths.get(h.destHash) else {
            log("rns: packet in transport, no path to \(h.destHash.hex), dropping")
            return false
        }
        let nowMs = now()
        var out = entry.direct ? Header.stripTransport(pkt.raw) : Header.rewriteForTransport(pkt.raw, transportId: entry.nextHop)
        out[1] = UInt8(h.hops & 0xFF)

        if h.packetType == Rns.packetLinkRequest {
            // Clamp the signalled link MTU to the smaller of both interfaces.
            var outPkt = out
            if h.data.count == LinkWire.ecPubSize + LinkWire.mtuSize {
                let (pathMtu, mode) = LinkWire.parseSignalling(h.data, offset: LinkWire.ecPubSize)
                let nhMtu = tx.hwMtu(ifaceId: entry.iface)
                let phMtu = tx.hwMtu(ifaceId: pkt.iface)
                if nhMtu == 0 {
                    outPkt.removeLast(LinkWire.mtuSize)
                } else {
                    var m = pathMtu
                    if nhMtu < m { m = nhMtu }
                    if phMtu >= 1, phMtu < m { m = phMtu }
                    if m != pathMtu {
                        outPkt.replaceSubrange((outPkt.count - LinkWire.mtuSize)..., with: LinkWire.signalling(mtu: m, mode: mode))
                    }
                }
            }
            guard let linkId = try? LinkWire.linkIdFromRequestPacket(pkt.raw) else { return true }
            let rem = max(1, entry.hops)
            lock.sync {
                linkTable[linkId.hex] = LinkEntry(
                    timestampMs: nowMs, nextHop: entry.nextHop, nextHopIface: entry.iface, remainingHops: entry.hops,
                    receivedIface: pkt.iface, takenHops: h.hops, destHash: h.destHash,
                    proofTimeoutMs: nowMs + Int64(Rns.perHopTimeout * rem) * 1000)
            }
            entry.timestampMs = nowMs
            count { $0.forwarded += 1 }
            transmit(entry.iface, outPkt)
            return true
        }
        lock.sync {
            reverseTable[pkt.truncatedHash.hex] = ReverseEntry(receivedIface: pkt.iface, outboundIface: entry.iface, timestampMs: nowMs)
        }
        entry.timestampMs = nowMs
        count { $0.forwarded += 1 }
        transmit(entry.iface, out)
        return true
    }

    /// The MeshSat extension: a HEADER_1 packet for a remote destination arriving from an interface whose
    /// peers cannot address a transport (the Meshtastic mesh) is inserted into transport here.
    func forwardHeader1(_ pkt: Packet) -> Bool {
        guard cfg.forwardHeader1From.contains(pkt.iface) else { return false }
        let h = pkt.hdr
        guard let entry = paths.get(h.destHash), entry.iface != pkt.iface else { return false }
        var out = entry.direct ? pkt.raw : Header.rewriteForTransport(pkt.raw, transportId: entry.nextHop)
        out[1] = UInt8(h.hops & 0xFF)
        let nowMs = now()
        lock.sync {
            if h.packetType == Rns.packetLinkRequest {
                if let linkId = try? LinkWire.linkIdFromRequestPacket(pkt.raw) {
                    linkTable[linkId.hex] = LinkEntry(
                        timestampMs: nowMs, nextHop: entry.nextHop, nextHopIface: entry.iface, remainingHops: entry.hops,
                        receivedIface: pkt.iface, takenHops: h.hops, destHash: h.destHash,
                        proofTimeoutMs: nowMs + Int64(Rns.perHopTimeout * max(1, entry.hops)) * 1000)
                }
            } else {
                reverseTable[pkt.truncatedHash.hex] = ReverseEntry(receivedIface: pkt.iface, outboundIface: entry.iface, timestampMs: nowMs)
            }
        }
        count { $0.forwarded += 1 }
        transmit(entry.iface, out)
        return true
    }

    /// Repeats packets belonging to a link we carry.
    func linkTransit(_ pkt: Packet) -> Bool {
        let h = pkt.hdr
        enum Verdict {
            case notOurs
            case drop
            case repeatOn(String)
        }
        let verdict: Verdict = lock.sync {
            guard let e = linkTable[h.destHash.hex] else { return .notOurs }
            if !e.validated { return .drop }  // a link packet before validation: drop
            let hops = h.hops
            var out = ""
            if e.nextHopIface == e.receivedIface {
                if hops == e.remainingHops || hops == e.takenHops { out = e.nextHopIface }
            } else if pkt.iface == e.nextHopIface {
                if hops == e.remainingHops { out = e.receivedIface }
            } else if pkt.iface == e.receivedIface {
                if hops == e.takenHops { out = e.nextHopIface }
            }
            if out.isEmpty { return .drop }
            hashlist.insert(pkt.hash.hex)
            e.timestampMs = now()
            statsRaw.linkTransit += 1
            return .repeatOn(out)
        }
        switch verdict {
        case .notOurs: return false
        case .drop: return true
        case .repeatOn(let iface):
            transmit(iface, pkt.raw)
            return true
        }
    }

    /// Validates and forwards a link request proof for a link in the link table. False when the proof is not for a transit link.
    func lrProofTransit(_ pkt: Packet) -> Bool {
        let h = pkt.hdr
        enum Found {
            case none
            case mismatch(Int)
            case entry(LinkEntry, KnownIdentity?)
        }
        let found: Found = lock.sync {
            guard let e = linkTable[h.destHash.hex] else { return .none }
            if h.hops != e.remainingHops || pkt.iface != e.nextHopIface { return .mismatch(e.remainingHops) }
            return .entry(e, identities[e.destHash.hex])
        }
        switch found {
        case .none:
            return false
        case .mismatch(let remaining):
            log("rns: link proof hop or interface mismatch in transit (\(h.hops) vs \(remaining))")
            return true
        case .entry(let e, let known):
            guard let lp = try? LinkWire.ProofData.unpack(h.data), let id = known?.identity else { return true }
            let signed = LinkWire.proofSignedData(
                linkId: h.destHash, ephPub: lp.ephPub, identitySigPub: id.sigPubRaw, mtu: lp.mtu, mode: lp.mode, signalled: lp.signalled)
            if !id.verify(signed, signature: lp.signature) {
                log("rns: invalid link request proof in transport")
                return true
            }
            lock.sync {
                e.validated = true
                e.timestampMs = now()
            }
            transmit(e.receivedIface, pkt.raw)
            return true
        }
    }

    /// Forwards a packet proof back along the reverse table.
    func proofTransit(_ pkt: Packet) {
        let h = pkt.hdr
        guard let e = lock.sync({ reverseTable.removeValue(forKey: h.destHash.hex) }) else { return }
        if pkt.iface != e.outboundIface { return }
        transmit(e.receivedIface, pkt.raw)
    }

    /// Sweeps the link, reverse and path tables.
    func expireTables(_ nowMs: Int64) {
        lock.sync {
            for (k, e) in reverseTable where nowMs > e.timestampMs + Int64(Rns.reverseTimeout) * 1000 { reverseTable[k] = nil }
            for (k, e) in linkTable
            where (!e.validated && nowMs > e.proofTimeoutMs) || nowMs > e.timestampMs + Int64(Rns.linkTimeout) * 1000 {
                linkTable[k] = nil
            }
        }
        paths.expire(nowMs)
    }
}
