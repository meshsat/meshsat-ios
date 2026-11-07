// Mirrors rns/Resource.kt: RNS Resource transfer over a link (RNS/Resource.py). The sender encrypts
// the whole payload once with the link key, splits the ciphertext into parts of SDU bytes,
// advertises hash, size and a map of 4-byte part hashes, and serves parts on request; the receiver
// requests windows of parts, reassembles, decrypts, verifies the hash and returns a proof. Single
// segment only (payloads up to 1 MiB), never compressed on send; a compressed resource is refused
// on receive (the delivery announce says so, LXMF then sends uncompressed).
import Foundation
import MeshSatNet

private let mapHashLen = 4
private let randomHashLen = 4
private let defaultWindow = 4
private let defaultWindowMin = 2
private let windowMaxSlow = 10
private let windowMaxFast = 75
private let windowFlex = 4
private let advOverhead = 134
private let maxAdvRetries = 4
private let maxRetries = 16
private let maxSize = 1 * 1024 * 1024 - 1
private let hashmapNotExhausted: UInt8 = 0x00
private let hashmapExhausted: UInt8 = 0xFF
private let processingGraceMs: Int64 = 1000
private let retryGraceMs: Int64 = 250
private let perRetryDelayMs: Int64 = 500
private let senderGraceMs: Int64 = 10_000
/// 74 at MTU 500.
private let hashmapMaxLen = (431 - advOverhead) / mapHashLen
private let collisionGuard = 2 * windowMaxFast + hashmapMaxLen

public struct ResourceResult: Sendable, Equatable {
    public let delivered: Bool
    public let error: String?

    public init(delivered: Bool, error: String? = nil) {
        self.delivered = delivered
        self.error = error
    }
}

/// A resource we are sending on a link.
public final class OutgoingResource: @unchecked Sendable {
    let link: Link
    let data: [UInt8]
    let dataSize: Int
    public internal(set) var hash: [UInt8] = []
    let mu = NSRecursiveLock()
    var parts: [[UInt8]] = []
    var mapHashes: [[UInt8]] = []
    var partSent: [Bool] = []
    var randomHash = [UInt8](repeating: 0, count: randomHashLen)
    var expectedProof: [UInt8] = []
    var sentParts = 0
    var advRetries = 0
    var advSentMs: Int64 = 0
    var lastActivityMs: Int64 = 0
    var rttMs: Int64 = 0
    /// 0 advertised, 1 transferring, 2 awaiting proof, 3 complete, 4 failed
    var state = 0
    var recvMinHeight = 0
    /// Set when the resource carries a link request or its response (ResourceAdvertisement q, u and p).
    var requestId: [UInt8]?
    var isResponse = false
    /// Resolves once the receiver proved the resource or the transfer failed.
    public let result = Promise<ResourceResult>()
    public var hashHex: String { hash.hex }

    init(link: Link, data: [UInt8], dataSize: Int) {
        self.link = link
        self.data = data
        self.dataSize = dataSize
    }
}

/// A resource being received on a link.
public final class IncomingResource: @unchecked Sendable {
    let link: Link
    public let hash: [UInt8]
    let size: Int
    public let dataSize: Int
    let totalParts: Int
    let mu = NSRecursiveLock()
    var parts: [[UInt8]?]
    var hashmap: [[UInt8]]
    var hashmapSet: [Bool]
    var hashHeight = 0
    var randomHash = [UInt8](repeating: 0, count: randomHashLen)
    var compressed = false
    var received = 0
    var outstanding = 0
    var window = defaultWindow
    var windowMax = windowMaxSlow
    var windowMin = defaultWindowMin
    var consecutive = -1
    var waitingHmu = false
    var retries = 0
    var lastActivityMs: Int64 = 0
    var reqSentMs: Int64 = 0
    /// 0 transferring, 1 assembling, 2 complete, 3 failed
    var state = 0
    /// The request this resource answers, when it is a response.
    public internal(set) var requestId: [UInt8]?
    public internal(set) var data: [UInt8]?
    public var hashHex: String { hash.hex }

    init(link: Link, hash: [UInt8], size: Int, dataSize: Int, totalParts: Int) {
        self.link = link
        self.hash = hash
        self.size = size
        self.dataSize = dataSize
        self.totalParts = totalParts
        parts = [[UInt8]?](repeating: nil, count: totalParts)
        hashmap = [[UInt8]](repeating: [], count: totalParts)
        hashmapSet = [Bool](repeating: false, count: totalParts)
    }
}

/// Per-link resource state.
final class LinkResources: @unchecked Sendable {
    let mu = NSRecursiveLock()
    var incoming: [String: IncomingResource] = [:]
    var outgoing: [String: OutgoingResource] = [:]
}

private func mapHash(_ part: [UInt8], _ random: [UInt8]) -> [UInt8] { Array(Rns.sha256(part, random).prefix(mapHashLen)) }

private func sduOf(_ l: Link) -> Int { l.mtu - Rns.headerMaxSize - Rns.ifacMinSize }

extension LinkManager {
    /// Advertises `payload` on the link and serves it; the result resolves when the receiver proves it.
    /// `requestId` marks a link request or, with `isResponse`, its response.
    @discardableResult
    public func sendResource(_ l: Link, _ payload: [UInt8], requestId: [UInt8]? = nil, isResponse: Bool = false) throws -> OutgoingResource
    {
        let st = l.state
        guard st == .active || st == .stale else { throw NodeError("link not active") }
        guard payload.count <= maxSize else { throw NodeError("resource larger than one segment (1 MiB)") }
        let plain = Rns.randomBytes(randomHashLen) + payload
        let enc = try l.encrypt(plain)
        let sdu = sduOf(l)
        let r = OutgoingResource(link: l, data: enc, dataSize: payload.count)
        r.requestId = requestId
        r.isResponse = isResponse
        r.rttMs = l.rttMs
        while true {
            r.randomHash = Rns.randomBytes(randomHashLen)
            r.hash = Rns.sha256(payload, r.randomHash)
            r.expectedProof = Rns.sha256(payload, r.hash)
            r.parts = []
            r.mapHashes = []
            var collision = false
            var guardSet = Set<String>()
            var i = 0
            while i < enc.count {
                let end = min(i + sdu, enc.count)
                let part = Array(enc[i..<end])
                let mh = mapHash(part, r.randomHash)
                if !guardSet.insert(mh.hex).inserted {
                    collision = true
                    break
                }
                r.parts.append(part)
                r.mapHashes.append(mh)
                i = end
            }
            if !collision { break }
        }
        r.partSent = [Bool](repeating: false, count: r.parts.count)
        let rs = l.res()
        rs.mu.sync { rs.outgoing[r.hashHex] = r }
        advertise(r)
        return r
    }

    private func advertisement(_ r: OutgoingResource, segment: Int) -> MpValue {
        let start = segment * hashmapMaxLen
        let end = min((segment + 1) * hashmapMaxLen, r.parts.count)
        var hm: [UInt8] = []
        for i in start..<max(start, end) { hm += r.mapHashes[i] }
        // encrypted, not compressed, not split, no metadata; the request (u, 0x08) or response (p, 0x10) flag
        let flags: Int64 = 0x01 | (r.requestId == nil ? 0 : (r.isResponse ? 0x10 : 0x08))
        return .map([
            MpEntry(.str("t"), .int(Int64(r.data.count))),
            MpEntry(.str("d"), .int(Int64(r.dataSize))),
            MpEntry(.str("n"), .int(Int64(r.parts.count))),
            MpEntry(.str("h"), .bin(r.hash)),
            MpEntry(.str("r"), .bin(r.randomHash)),
            MpEntry(.str("o"), .bin(r.hash)),
            MpEntry(.str("i"), .int(1)),
            MpEntry(.str("l"), .int(1)),
            MpEntry(.str("q"), r.requestId.map { MpValue.bin($0) } ?? MpValue.null),
            MpEntry(.str("f"), .int(flags)),
            MpEntry(.str("m"), .bin(hm)),
        ])
    }

    func advertise(_ r: OutgoingResource) {
        let adv = Msgpack.pack(advertisement(r, segment: 0))
        guard let ct = try? r.link.encrypt(adv) else { return }
        sendContext(r.link, Rns.packetData, Rns.ctxResourceAdv, ct)
        r.mu.sync {
            r.advSentMs = n.now()
            r.lastActivityMs = r.advSentMs
        }
    }

    private func fail(_ r: OutgoingResource, _ err: String) {
        let already: Bool = r.mu.sync {
            if r.state >= 3 { return true }
            r.state = 4
            return false
        }
        if already { return }
        let rs = r.link.res()
        rs.mu.sync { rs.outgoing[r.hashHex] = nil }
        r.result.complete(ResourceResult(delivered: false, error: err))
    }

    /// Serves a RESOURCE_REQ (decrypted plaintext).
    func handleResourceRequest(_ l: Link, _ plain: [UInt8]) {
        guard plain.count >= 1 + Rns.fullHashLen else { return }
        let exhausted = plain[0] == hashmapExhausted
        var pad = 1
        var lastMap: [UInt8] = []
        if exhausted {
            guard plain.count >= 1 + mapHashLen + Rns.fullHashLen else { return }
            lastMap = Array(plain[1..<(1 + mapHashLen)])
            pad = 1 + mapHashLen
        }
        let hash = Array(plain[pad..<(pad + Rns.fullHashLen)])
        let rs = l.res()
        guard let r = rs.mu.sync({ rs.outgoing[hash.hex] }) else { return }
        var toSend: [[UInt8]] = []
        var hmu: [UInt8]?
        var failMsg: String?
        let nowMs = n.now()
        r.mu.sync {
            if r.rttMs == 0 { r.rttMs = nowMs - r.advSentMs }
            r.state = 1
            r.lastActivityMs = nowMs
            let wanted = Array(plain[(pad + Rns.fullHashLen)...])
            var want = Set<String>()
            var i = 0
            while i + mapHashLen <= wanted.count {
                want.insert(Array(wanted[i..<(i + mapHashLen)]).hex)
                i += mapHashLen
            }
            let start = r.recvMinHeight
            let end = min(start + collisionGuard, r.parts.count)
            for j in start..<max(start, end) where want.contains(r.mapHashes[j].hex) {
                toSend.append(r.parts[j])
                if !r.partSent[j] {
                    r.partSent[j] = true
                    r.sentParts += 1
                }
            }
            if exhausted {
                var idx = r.recvMinHeight
                for j in r.recvMinHeight..<max(r.recvMinHeight, end) {
                    idx += 1
                    if r.mapHashes[j] == lastMap { break }
                }
                r.recvMinHeight = max(idx - 1 - windowMaxFast, 0)
                if idx % hashmapMaxLen != 0 {
                    n.log("rns: resource sequencing error, cancelling")
                    failMsg = "resource sequencing error"
                    return
                }
                let segment = idx / hashmapMaxLen
                let hs = segment * hashmapMaxLen
                let he = min((segment + 1) * hashmapMaxLen, r.parts.count)
                var hm: [UInt8] = []
                for j in hs..<max(hs, he) { hm += r.mapHashes[j] }
                if hm.isEmpty {
                    failMsg = "resource HMU error"
                    return
                }
                hmu = r.hash + Msgpack.pack(.array([.int(Int64(segment)), .bin(hm)]))
            }
            if r.sentParts == r.parts.count { r.state = 2 }
        }
        if let failMsg {
            fail(r, failMsg)
            return
        }
        for p in toSend { sendContext(l, Rns.packetData, Rns.ctxResource, p) }
        if let hmu, let ct = try? l.encrypt(hmu) { sendContext(l, Rns.packetData, Rns.ctxResourceHmu, ct) }
    }

    /// Validates a RESOURCE_PRF for an outgoing resource.
    func handleResourceProof(_ l: Link, _ data: [UInt8]) {
        guard data.count == 2 * Rns.fullHashLen else { return }
        let hash = Array(data[0..<Rns.fullHashLen])
        let rs = l.res()
        guard let r = rs.mu.sync({ rs.outgoing[hash.hex] }) else { return }
        guard Array(data[Rns.fullHashLen...]) == r.expectedProof else { return }
        r.mu.sync { r.state = 3 }
        rs.mu.sync { rs.outgoing[r.hashHex] = nil }
        l.noteProof(n.now())
        r.result.complete(ResourceResult(delivered: true))
    }

    /// Accepts an advertisement (decrypted) when the link allows resources, then requests the first window.
    func handleResourceAdv(_ l: Link, _ plain: [UInt8]) {
        guard let v = (try? Msgpack.unpack(plain))?.value, v.asMap != nil else { return }
        guard let t = v["t"]?.asInt, let d = v["d"]?.asInt, let nParts = v["n"]?.asInt else { return }
        let f = v["f"]?.asInt ?? 0
        let segs = v["l"]?.asInt ?? 1
        guard case .bin(let h)? = v["h"], case .bin(let rb)? = v["r"] else { return }
        var hm: [UInt8] = []
        if case .bin(let m)? = v["m"] { hm = m }
        guard h.count == Rns.fullHashLen, rb.count == randomHashLen, nParts > 0, t > 0, t <= 3 * Int64(maxSize) else { return }
        if segs > 1 || (f & 0x20) != 0 {
            n.log("rns: multi-segment or metadata resource not supported, rejecting")
            rejectResource(l, h)
            return
        }
        if (f & 0x02) != 0 {
            n.log("rns: compressed resource not supported, rejecting")
            rejectResource(l, h)
            return
        }
        var q: [UInt8]?
        if case .bin(let qq)? = v["q"] { q = qq }
        var pendingReq: RequestReceipt?
        if let q, (f & 0x10) != 0 {
            // A response to one of our requests: accepted whatever the link's resource policy says (Link.receive).
            pendingReq = pendingRequest(l, q)
            if pendingReq == nil {
                n.log("rns: response resource for unknown request \(q.hex8), rejecting")
                rejectResource(l, h)
                return
            }
        } else if q != nil, (f & 0x08) != 0 {
            n.log("rns: request resource on \(l.idHex.prefix(8)), no request handlers, rejecting")
            rejectResource(l, h)
            return
        } else {
            guard let accept = l.acceptResources, accept(Int(d)) else {
                rejectResource(l, h)
                return
            }
        }
        let sdu = sduOf(l)
        var totalParts = Int((t + Int64(sdu) - 1) / Int64(sdu))
        if Int(nParts) != totalParts { totalParts = Int(nParts) }
        let r = IncomingResource(link: l, hash: h, size: Int(t), dataSize: Int(d), totalParts: totalParts)
        r.randomHash = rb
        r.requestId = pendingReq?.requestId
        pendingReq?.responseStarted = true
        r.lastActivityMs = n.now()
        let rs = l.res()
        let dup: Bool = rs.mu.sync {
            if rs.incoming[r.hashHex] != nil { return true }
            rs.incoming[r.hashHex] = r
            return false
        }
        if dup { return }
        n.log("rns: accepting resource on \(l.idHex.prefix(8)) size=\(r.size) parts=\(r.totalParts)")
        hashmapUpdate(r, segment: 0, hm)
        requestNext(r)
    }

    func rejectResource(_ l: Link, _ hash: [UInt8]) {
        guard let ct = try? l.encrypt(hash) else { return }
        sendContext(l, Rns.packetData, Rns.ctxResourceRcl, ct)
    }

    private func hashmapUpdate(_ r: IncomingResource, segment: Int, _ hm: [UInt8]) {
        r.mu.sync {
            let count = hm.count / mapHashLen
            for i in 0..<count {
                let idx = i + segment * hashmapMaxLen
                if idx >= r.totalParts { break }
                if !r.hashmapSet[idx] { r.hashHeight += 1 }
                r.hashmap[idx] = Array(hm[(i * mapHashLen)..<((i + 1) * mapHashLen)])
                r.hashmapSet[idx] = true
            }
            r.waitingHmu = false
        }
    }

    func handleResourceHmu(_ l: Link, _ plain: [UInt8]) {
        guard plain.count > Rns.fullHashLen else { return }
        let hash = Array(plain[0..<Rns.fullHashLen])
        let rs = l.res()
        guard let r = rs.mu.sync({ rs.incoming[hash.hex] }) else { return }
        guard let v = (try? Msgpack.unpack(plain, offset: Rns.fullHashLen))?.value.asArray, v.count == 2 else { return }
        guard let seg = v[0].asInt, case .bin(let hm) = v[1] else { return }
        hashmapUpdate(r, segment: Int(seg), hm)
        requestNext(r)
    }

    func handleResourceCancel(_ l: Link, _ plain: [UInt8]) {
        guard plain.count == Rns.fullHashLen else { return }
        let rs = l.res()
        let key = plain.hex
        let inc = rs.mu.sync { rs.incoming[key] }
        let out = rs.mu.sync { rs.outgoing[key] }
        if let inc { concludeIncoming(inc, nil, "cancelled by sender") }
        if let out { fail(out, "rejected by receiver") }
    }

    /// Asks for the next window of parts (Resource.request_next).
    func requestNext(_ r: IncomingResource) {
        let l = r.link
        let data: [UInt8]? = r.mu.sync {
            if r.state >= 1 || r.waitingHmu { return nil }
            r.outstanding = 0
            var exhausted = false
            var req: [UInt8] = []
            var pn = r.consecutive + 1
            var i = 0
            while pn < r.totalParts, i < r.window {
                if r.parts[pn] == nil {
                    if !r.hashmapSet[pn] {
                        exhausted = true
                        break
                    }
                    req += r.hashmap[pn]
                    r.outstanding += 1
                    i += 1
                }
                pn += 1
            }
            let out: [UInt8]
            if exhausted {
                r.waitingHmu = true
                out = [hashmapExhausted] + r.hashmap[max(0, r.hashHeight - 1)] + r.hash + req
            } else {
                out = [hashmapNotExhausted] + r.hash + req
            }
            r.lastActivityMs = n.now()
            r.reqSentMs = r.lastActivityMs
            return out
        }
        guard let data, let ct = try? l.encrypt(data) else { return }
        sendContext(l, Rns.packetData, Rns.ctxResourceReq, ct)
    }

    /// Stores a RESOURCE part.
    func receivePart(_ l: Link, _ part: [UInt8]) {
        let rs = l.res()
        let cands = rs.mu.sync { Array(rs.incoming.values) }
        for r in cands {
            enum Next {
                case none
                case assemble
                case request
                case matched
            }
            let next: Next = r.mu.sync {
                if r.state >= 1 { return .none }
                let mh = mapHash(part, r.randomHash)
                let start = r.consecutive + 1
                var matched = false
                var idx = start
                while idx < start + r.window, idx < r.totalParts {
                    if r.hashmapSet[idx], r.hashmap[idx] == mh, r.parts[idx] == nil {
                        r.parts[idx] = part
                        r.received += 1
                        r.outstanding -= 1
                        var cp = r.consecutive + 1
                        while cp < r.totalParts, r.parts[cp] != nil {
                            r.consecutive = cp
                            cp += 1
                        }
                        matched = true
                        break
                    }
                    idx += 1
                }
                if !matched { return .none }
                r.lastActivityMs = n.now()
                r.retries = 0
                if r.received == r.totalParts {
                    r.state = 1
                    return .assemble
                }
                if r.outstanding <= 0 {
                    if r.window < r.windowMax {
                        r.window += 1
                        if r.window - r.windowMin > windowFlex - 1 { r.windowMin += 1 }
                    }
                    return .request
                }
                return .matched
            }
            switch next {
            case .none: continue
            case .assemble:
                assemble(r)
                return
            case .request:
                requestNext(r)
                return
            case .matched:
                return
            }
        }
    }

    private func assemble(_ r: IncomingResource) {
        var stream: [UInt8] = []
        for p in r.parts { stream += p ?? [] }
        guard let plain = r.link.decrypt(stream), plain.count >= randomHashLen else {
            concludeIncoming(r, nil, "resource decrypt failed")
            return
        }
        let data = Array(plain[randomHashLen...])
        if r.compressed {
            concludeIncoming(r, nil, "compressed resource unsupported")
            return
        }
        guard Rns.sha256(data, r.randomHash) == r.hash else {
            concludeIncoming(r, nil, "resource hash mismatch")
            return
        }
        let proof = Rns.sha256(data, r.hash)
        sendContext(r.link, Rns.packetProof, Rns.ctxResourcePrf, r.hash + proof)
        concludeIncoming(r, data, nil)
    }

    private func concludeIncoming(_ r: IncomingResource, _ data: [UInt8]?, _ err: String?) {
        r.mu.sync {
            if err == nil {
                r.state = 2
                r.data = data
            } else {
                r.state = 3
            }
        }
        let rs = r.link.res()
        rs.mu.sync { rs.incoming[r.hashHex] = nil }
        let reqId = r.requestId
        if let err {
            n.log("rns: incoming resource on \(r.link.idHex.prefix(8)) failed: \(err)")
            if let reqId, let pr = pendingRequest(r.link, reqId) { failRequest(pr, "response resource failed: \(err)") }
            return
        }
        guard let data else { return }
        n.log("rns: resource received on \(r.link.idHex.prefix(8)), \(data.count) bytes")
        if let reqId {
            // A response resource: msgpack([request id, data]) (Link.response_resource_concluded).
            let v = (try? Msgpack.unpack(data))?.value.asArray
            if let v, v.count >= 2, case .bin(let id) = v[0] {
                completeRequest(r.link, id, v[1])
            } else if let pr = pendingRequest(r.link, reqId) {
                failRequest(pr, "malformed response resource")
            }
            return
        }
        r.link.onResource?(r.link, data)
        r.link.local?.onLinkResource?(r.link, data)
    }

    /// Retries requests and advertisements and times transfers out.
    func resourceWatchdog(_ nowMs: Int64) {
        for l in all() {
            let rs = l.res()
            let inc = rs.mu.sync { Array(rs.incoming.values) }
            let out = rs.mu.sync { Array(rs.outgoing.values) }
            var rtt = l.rttMs
            if rtt < 100 { rtt = 100 }
            for r in inc {
                enum Act {
                    case none
                    case retry
                    case timedOut
                }
                let act: Act = r.mu.sync {
                    var wait = 4 * rtt + retryGraceMs + Int64(r.retries) * perRetryDelayMs
                    if wait < 2000 { wait = 2000 }
                    guard r.state == 0, nowMs > r.lastActivityMs + wait else { return .none }
                    if r.retries >= maxRetries { return .timedOut }
                    r.retries += 1
                    if r.window > r.windowMin { r.window -= 1 }
                    r.waitingHmu = false
                    r.lastActivityMs = nowMs
                    return .retry
                }
                switch act {
                case .none: break
                case .timedOut: concludeIncoming(r, nil, "timed out waiting for parts")
                case .retry: requestNext(r)
                }
            }
            for r in out {
                var readvertise = false
                var failMsg: String?
                r.mu.sync {
                    switch r.state {
                    case 0:
                        if nowMs > r.advSentMs + 6 * rtt + processingGraceMs {
                            if r.advRetries >= maxAdvRetries {
                                failMsg = "no part requests after advertisement"
                            } else {
                                r.advRetries += 1
                                readvertise = true
                            }
                        }
                    case 1, 2:
                        if nowMs > r.lastActivityMs + 6 * rtt * Int64(maxRetries) + senderGraceMs {
                            failMsg = "timed out waiting for the receiver"
                        }
                    default:
                        break
                    }
                }
                if let failMsg { fail(r, failMsg) }
                if readvertise { advertise(r) }
            }
        }
    }
}
