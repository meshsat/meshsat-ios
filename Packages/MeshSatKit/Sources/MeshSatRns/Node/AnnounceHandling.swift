// Mirrors rns/AnnounceHandling.kt: the announce branch of Transport.inbound (path table replacement
// rules, the announce table for rebroadcast as a transport node), Transport.jobs' retransmissions,
// the per-interface announce cap, and Destination.announce.
import Foundation
import MeshSatNet

private let maxRandomBlobs = 64

/// The time an interface at `bitrate` must stay quiet after `bytes` of announce so announces take ANNOUNCE_CAP percent of it.
private func announceWaitMs(bytes: Int, bitrate: Int) -> Int64 {
    let txTimeSec: Double = Double(bytes) * 8.0 / Double(bitrate)
    let capFraction: Double = Double(Rns.announceCap) / 100.0
    let waitSec: Double = txTimeSec / capFraction
    return Int64(waitSec * 1000.0)
}

/// One row of Transport.announce_table.
final class AnnounceEntry: @unchecked Sendable {
    let timestampMs: Int64
    var retransmitTimeoutMs: Int64
    var retries: Int
    let receivedFrom: [UInt8]
    let hops: Int
    let ann: Announce
    let sourceIface: String
    var localRebroadcasts = 0
    /// true: send as PATH_RESPONSE on attachedIface only.
    let blockRebroadcasts: Bool
    let attachedIface: String

    init(
        timestampMs: Int64, retransmitTimeoutMs: Int64, retries: Int = 0, receivedFrom: [UInt8], hops: Int, ann: Announce,
        sourceIface: String = "", blockRebroadcasts: Bool = false, attachedIface: String = ""
    ) {
        self.timestampMs = timestampMs
        self.retransmitTimeoutMs = retransmitTimeoutMs
        self.retries = retries
        self.receivedFrom = receivedFrom
        self.hops = hops
        self.ann = ann
        self.sourceIface = sourceIface
        self.blockRebroadcasts = blockRebroadcasts
        self.attachedIface = attachedIface
    }
}

/// Delays announces on a slow interface to the 2 % cap.
final class AnnounceQueue: @unchecked Sendable {
    var allowedAtMs: Int64 = 0
    var pending: [[UInt8]] = []
    var timerSet = false
}

extension Node {
    /// Transport.inbound's path replacement rules: the random blobs of the new path entry when this announce
    /// should add or replace the path, nil when it is kept out.
    static func replacementBlobs(existing: PathEntry?, hops: Int, randomBlob: [UInt8], emitted: Int64, nowMs: Int64) -> [[UInt8]]? {
        guard hops < Rns.pathfinderM + 1 else { return nil }
        var shouldAdd = false
        var blobs: [[UInt8]] = []
        if let existing {
            blobs = existing.randomBlobs
            if hops <= existing.hops {
                if !blobs.contains(randomBlob), emitted > existing.emittedAt() { shouldAdd = true }
            } else {
                var pathEmitted: Int64 = 0
                for b in blobs {
                    let ts = Announce.blobTimestamp(b)
                    if ts > pathEmitted { pathEmitted = ts }
                    if pathEmitted >= emitted { break }
                }
                if nowMs >= existing.expiresMs {
                    shouldAdd = !blobs.contains(randomBlob)
                } else if emitted > pathEmitted {
                    shouldAdd = !blobs.contains(randomBlob)
                } else if emitted == pathEmitted, existing.unresponsive {
                    shouldAdd = true
                }
            }
        } else {
            shouldAdd = true
        }
        guard shouldAdd else { return nil }
        if !blobs.contains(randomBlob) {
            blobs.append(randomBlob)
            while blobs.count > maxRandomBlobs { blobs.removeFirst() }
        }
        return blobs
    }

    /// The announce branch of Transport.inbound.
    func handleAnnounce(_ pkt: Packet) -> Bool {
        let h = pkt.hdr
        guard
            let ann = try? Announce.unpackPayload(
                h.data, destHash: h.destHash, hops: h.hops, contextFlag: h.contextFlag, context: h.context)
        else { return true }
        if let why = ann.verify() {
            log("rns: invalid announce on \(pkt.iface): \(why)")
            return true
        }
        count { $0.announcesRx += 1 }
        if localDestination(h.destHash) != nil { return true }  // our own announce echoed back

        let nowMs = now()
        let receivedFrom = h.headerType == Rns.header2 ? (h.transportId ?? h.destHash) : h.destHash
        let hops = h.hops
        let randomBlob = ann.random
        let emitted = Announce.blobTimestamp(randomBlob)
        let destKey = h.destHash.hex

        struct Accepted {
            let entry: PathEntry
            let answerOn: [String]
            let waiters: [Promise<Bool>]
        }
        let accepted: Accepted? = lock.sync {
            // A rebroadcast by another node of an announce we hold for retransmission.
            if h.headerType == Rns.header2, let e = announceTable[destKey] {
                if hops - 1 == e.hops {
                    e.localRebroadcasts += 1
                    if e.retries > 0, e.localRebroadcasts >= Rns.localRebroadcastsMax { announceTable[destKey] = nil }
                }
                if hops - 1 == e.hops + 1, e.retries > 0, nowMs < e.retransmitTimeoutMs { announceTable[destKey] = nil }
            }

            guard
                let blobs = Self.replacementBlobs(
                    existing: paths.get(h.destHash), hops: hops, randomBlob: randomBlob, emitted: emitted, nowMs: nowMs)
            else { return nil }
            let entry = PathEntry(
                destHash: h.destHash, timestampMs: nowMs, nextHop: receivedFrom, hops: hops, expiresMs: nowMs + paths.ttlMs,
                randomBlobs: blobs, iface: pkt.iface, announce: ann, packetHash: pkt.hash)
            if h.context != Rns.ctxPathResponse {
                announceTable[destKey] = AnnounceEntry(
                    timestampMs: nowMs, retransmitTimeoutMs: nowMs + Int64(Double.random(in: 0..<1) * Rns.pathfinderRW * 1000),
                    receivedFrom: receivedFrom, hops: hops, ann: ann, sourceIface: pkt.iface)
            }
            // Answer waiting discovery path requests at once.
            let answerOn = discoveryPRs.removeValue(forKey: destKey)?.requestingIfaces ?? []
            paths.put(entry)
            // Remember the identity.
            let k =
                identities[destKey]
                ?? {
                    let n = KnownIdentity(destHash: h.destHash)
                    identities[destKey] = n
                    return n
                }()
            k.publicKey = ann.publicKey
            k.identity = RnsIdentity.fromPublicBytesOrNil(ann.publicKey)
            k.appData = ann.appData
            if ann.contextFlag != 0, let r = ann.ratchet {
                k.ratchet = r
                k.ratchetAtMs = nowMs
            }
            k.lastSeenMs = nowMs
            let waiters = pathWaiters.removeValue(forKey: destKey) ?? []
            inflightPRs[destKey] = nil
            return Accepted(entry: entry, answerOn: answerOn, waiters: waiters)
        }
        guard let acc = accepted else { return true }

        for ifc in acc.answerOn {
            guard paidGate(ifc, h.destHash, .announce) else { continue }
            if let raw = try? ann.transportPacket(transportId: idHash, hops: hops, context: Rns.ctxPathResponse) { transmit(ifc, raw) }
        }
        for w in acc.waiters { w.complete(true) }
        log("rns: path learned \(destKey.prefix(8)) hops=\(hops) iface=\(pkt.iface) via=\(receivedFrom.hex8)")
        onPathChanged?(h.destHash, acc.entry)
        onAnnounce?(ann, pkt)
        return true
    }

    /// Retransmits queued announces (Transport.jobs).
    func processAnnounceTable(_ nowMs: Int64) {
        struct Out {
            let raw: [UInt8]
            let ifaces: [String]?
            let dest: [UInt8]
            let source: String
        }
        var outgoing: [Out] = []
        lock.sync {
            for (destKey, e) in announceTable {
                if e.retries > 0, e.retries >= Rns.localRebroadcastsMax {
                    announceTable[destKey] = nil
                } else if e.retries > Rns.pathfinderR {
                    announceTable[destKey] = nil
                } else if nowMs > e.retransmitTimeoutMs {
                    e.retransmitTimeoutMs = nowMs + Int64((Rns.pathfinderG + Rns.pathfinderRW) * 1000)
                    e.retries += 1
                    let ctx = e.blockRebroadcasts ? Rns.ctxPathResponse : Rns.ctxNone
                    // A rebroadcast goes out on every floodable interface, the one it arrived on included: on a
                    // shared medium that repetition is the point, and on a multi-peer TCP interface the other
                    // peers only hear it that way.
                    if let raw = try? e.ann.transportPacket(transportId: idHash, hops: e.hops, context: ctx) {
                        outgoing.append(
                            Out(
                                raw: raw, ifaces: e.attachedIface.isEmpty ? nil : [e.attachedIface], dest: e.ann.destHash,
                                source: e.sourceIface))
                    }
                    if let held = heldAnnounces.removeValue(forKey: destKey) { announceTable[destKey] = held }
                }
            }
        }
        for o in outgoing {
            let ifaces: [String]
            if let fixed = o.ifaces {
                // A path response on a paid link for an unlisted destination stays home.
                guard paidGate(fixed[0], o.dest, .announce) else { continue }
                ifaces = fixed
            } else {
                // Paid interfaces open to this destination join the flood, never the one the announce came in
                // on: on a paid link that echo is a paid message for nothing.
                ifaces = tx.floodable() + paidTake(o.dest, .announce, except: o.source)
            }
            log("rns: rebroadcasting announce for \(o.dest.hex8) on \(ifaces)")
            for id in ifaces { sendAnnounceOn(id, o.raw, nowMs) }
            count { $0.announcesTx += 1 }
        }
    }

    /// The announce cap: an interface with a known bit rate may only spend ANNOUNCE_CAP percent of its time
    /// on announces (Transport.outbound). Announces beyond the cap are queued, newest last, and released as
    /// the budget allows.
    func sendAnnounceOn(_ ifaceId: String, _ raw: [UInt8], _ nowMs: Int64) {
        let bitrate = announceBitrate(ifaceId)
        if bitrate <= 0 {
            transmit(ifaceId, raw)
            return
        }
        let waitMs = announceWaitMs(bytes: raw.count, bitrate: bitrate)
        enum Action {
            case sendNow
            case drop
            case queued
            case flushAfter(Int64)
        }
        let action: Action = lock.sync {
            let q =
                announceQueues[ifaceId]
                ?? {
                    let n = AnnounceQueue()
                    announceQueues[ifaceId] = n
                    return n
                }()
            if q.pending.isEmpty, nowMs > q.allowedAtMs {
                q.allowedAtMs = nowMs + waitMs
                return .sendNow
            }
            if q.pending.count >= 16 { return .drop }
            q.pending.append(raw)
            if !q.timerSet {
                q.timerSet = true
                return .flushAfter(max(0, q.allowedAtMs - nowMs))
            }
            return .queued
        }
        switch action {
        case .sendNow: transmit(ifaceId, raw)
        case .drop: log("rns: announce queue on \(ifaceId) full, dropping")
        case .queued: break
        case .flushAfter(let delay): schedule(delayMs: delay) { [weak self] in self?.flushAnnounceQueue(ifaceId) }
        }
    }

    func flushAnnounceQueue(_ ifaceId: String) {
        let nowMs = now()
        let bitrate = announceBitrate(ifaceId)
        let raw: [UInt8]? = lock.sync {
            guard let q = announceQueues[ifaceId], !q.pending.isEmpty else {
                announceQueues[ifaceId]?.timerSet = false
                return nil
            }
            let r = q.pending.removeFirst()
            q.allowedAtMs = nowMs
            if bitrate > 0 { q.allowedAtMs = nowMs + announceWaitMs(bytes: r.count, bitrate: bitrate) }
            if !q.pending.isEmpty {
                let delay = q.allowedAtMs - nowMs
                schedule(delayMs: delay) { [weak self] in self?.flushAnnounceQueue(ifaceId) }
            } else {
                q.timerSet = false
            }
            return r
        }
        if let raw { transmit(ifaceId, raw) }
    }

    /// Emits an announce for a local destination on every floodable interface and every paid interface open
    /// to it (or only on `ifaceId` when set, which a paid interface still gates). The destination's ratchets
    /// rotate first.
    @discardableResult
    public func announce(_ d: Destination, ifaceId: String = "", pathResponse: Bool = false) -> Bool {
        let nowMs = now()
        let ratchetPub = d.rotateRatchets(nowMs: nowMs)
        guard
            let ann = try? Announce.create(
                identity: d.identity, name: d.name, appData: d.appData.flatMap { $0() }, ratchetPub: ratchetPub, nowSec: nowMs / 1000,
                pathResponse: pathResponse),
            let raw = try? ann.packet()
        else { return false }
        if !ifaceId.isEmpty {
            guard paidGate(ifaceId, d.hash, .announce) else { return false }
            sendAnnounceOn(ifaceId, raw, nowMs)
        } else {
            let ifaces = tx.floodable() + paidTake(d.hash, .announce, except: "")
            if ifaces.isEmpty { return false }
            for id in ifaces { sendAnnounceOn(id, raw, nowMs) }
        }
        count { $0.announcesTx += 1 }
        return true
    }
}
