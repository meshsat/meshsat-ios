// Mirrors rns/PathRequests.kt: the path-request branch of Transport.inbound and Transport.path_request
// for a transport instance that searches on every interface. Data: dest (16) || [requestor transport
// id (16)] || tag.
import Foundation
import MeshSatNet

/// One row of Transport.discovery_path_requests.
final class DiscoveryEntry: @unchecked Sendable {
    var timeoutMs: Int64
    var requestingIfaces: [String] = []
    var engaged = false

    init(timeoutMs: Int64) { self.timeoutMs = timeoutMs }
}

extension Node {
    func handlePathRequest(_ pkt: Packet) {
        let data = pkt.hdr.data
        guard data.count >= Rns.hashLen else { return }
        let dest = Array(data[0..<Rns.hashLen])
        var requestor: [UInt8]?
        var tag: [UInt8]
        if data.count > 2 * Rns.hashLen {
            requestor = Array(data[Rns.hashLen..<(2 * Rns.hashLen)])
            tag = Array(data[(2 * Rns.hashLen)...])
        } else if data.count > Rns.hashLen {
            tag = Array(data[Rns.hashLen...])
        } else {
            return  // tagless
        }
        if tag.count > Rns.hashLen { tag = Array(tag.prefix(Rns.hashLen)) }
        let unique = dest.hex + tag.hex
        let destKey = dest.hex

        enum Step {
            case drop
            case local(Destination)
            case search
        }
        let step: Step = lock.sync {
            if prTags.contains(unique) || prTagsPrev.contains(unique) { return .drop }
            prTags.insert(unique)
            statsRaw.pathRequestsRx += 1
            if inflightPRs[destKey] != nil {
                // Batch onto the existing discovery.
                let d =
                    discoveryPRs[destKey]
                    ?? {
                        let n = DiscoveryEntry(timeoutMs: now() + Int64(Rns.pathRequestTimeout) * 1000)
                        discoveryPRs[destKey] = n
                        return n
                    }()
                if !d.requestingIfaces.contains(pkt.iface) { d.requestingIfaces.append(pkt.iface) }
                return .drop
            }
            inflightPRs[destKey] = now()
            if let local = dests[destKey] { return .local(local) }
            return .search
        }
        switch step {
        case .drop:
            return
        case .local(let local):
            // Local destination: answer with an announce on the requesting interface.
            if announce(local, ifaceId: pkt.iface, pathResponse: true) {
                log("rns: answered path request for \(local.name) on \(pkt.iface)")
            }
            resolveInflight(destKey)
            return
        case .search:
            break
        }

        // Known path: queue the cached announce as a path response after the grace period.
        if let e = paths.get(dest) {
            if let requestor, e.nextHop == requestor {
                log("rns: not answering path request, next hop is the requestor")
                resolveInflight(destKey)
                return
            }
            let nowMs = now()
            lock.sync {
                if let held = announceTable[destKey], !held.blockRebroadcasts { heldAnnounces[destKey] = held }
                announceTable[destKey] = AnnounceEntry(
                    timestampMs: nowMs, retransmitTimeoutMs: nowMs + Int64(Rns.pathRequestGrace * 1000), retries: Rns.pathfinderR,
                    receivedFrom: e.nextHop, hops: e.hops, ann: e.announce, blockRebroadcasts: true, attachedIface: pkt.iface)
            }
            resolveInflight(destKey)
            return
        }

        // Unknown: search on every other floodable interface with the same tag.
        let alreadyEngaged: Bool = lock.sync {
            if let d = discoveryPRs[destKey], d.engaged {
                if !d.requestingIfaces.contains(pkt.iface) { d.requestingIfaces.append(pkt.iface) }
                return true
            }
            let d =
                discoveryPRs[destKey]
                ?? {
                    let n = DiscoveryEntry(timeoutMs: 0)
                    discoveryPRs[destKey] = n
                    return n
                }()
            d.timeoutMs = now() + Int64(Rns.pathRequestTimeout) * 1000
            d.engaged = true
            if !d.requestingIfaces.contains(pkt.iface) { d.requestingIfaces.append(pkt.iface) }
            return false
        }
        if alreadyEngaged { return }
        let tag16 = tag.count >= Rns.hashLen ? Array(tag.prefix(Rns.hashLen)) : tag + [UInt8](repeating: 0, count: Rns.hashLen - tag.count)
        for id in tx.floodable() + paidTake(dest, .pathRequest, except: pkt.iface) where id != pkt.iface {
            sendPathRequest(dest, id, tag16)
        }
    }

    func resolveInflight(_ destKey: String) { lock.sync { inflightPRs[destKey] = nil } }

    func expireDiscovery(_ nowMs: Int64) {
        lock.sync {
            for (k, d) in discoveryPRs where nowMs > d.timeoutMs {
                discoveryPRs[k] = nil
                inflightPRs[k] = nil
            }
            for (k, t) in inflightPRs where nowMs > t + Int64(Rns.pathRequestTimeout) * 1000 { inflightPRs[k] = nil }
        }
    }

    /// One path request packet on an interface: dest || our transport id || tag, to the PLAIN path request destination.
    func sendPathRequest(_ dest: [UInt8], _ ifaceId: String, _ tag: [UInt8]) {
        guard
            let raw = try? Header(
                headerType: Rns.header1, transportType: Rns.transportBroadcast, destType: Rns.destPlain, packetType: Rns.packetData,
                destHash: Rns.pathRequestDestHash, context: Rns.ctxNone, data: dest + idHash + tag
            ).pack()
        else { return }
        transmit(ifaceId, raw)
    }

    /// Asks the network for a path. The promise completes true when an announce for `dest` arrives, or with
    /// whether a path is known once `timeoutMs` passes.
    public func requestPath(_ dest: [UInt8], timeoutMs: Int64 = Int64(Rns.pathRequestTimeout) * 1000) -> Promise<Bool> {
        if paths.has(dest) { return .completed(true) }
        let f = Promise<Bool>()
        let key = dest.hex
        lock.sync { pathWaiters[key, default: []].append(f) }
        let tag = Rns.randomBytes(Rns.hashLen)
        for id in tx.floodable() + paidTake(dest, .pathRequest, except: "") { sendPathRequest(dest, id, tag) }
        schedule(delayMs: timeoutMs) { [weak self] in
            guard let self else {
                f.complete(false)
                return
            }
            self.lock.sync { self.pathWaiters[key]?.removeAll { $0 === f } }
            f.complete(self.paths.has(dest))
        }
        return f
    }

    /// `requestPath`, awaited (Kotlin's requestPathBlocking).
    public func requestPathAwait(_ dest: [UInt8], timeoutMs: Int64 = Int64(Rns.pathRequestTimeout) * 1000) async -> Bool {
        (try? await requestPath(dest, timeoutMs: timeoutMs).wait(timeoutMs: timeoutMs + 2000)) ?? paths.has(dest)
    }
}
