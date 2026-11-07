// Mirrors rns/Requests.kt: link requests and responses, the requesting side (RNS/Link.py request,
// handle_response, RequestReceipt): a request is msgpack([time, truncated_hash(path), data]) sent as
// a link packet with context REQUEST, or as a resource when it is larger than the link MDU, and is
// identified by the truncated hash of that packet (of the packed request for a resource). The
// response is msgpack([request id, data]) with context RESPONSE, or a resource whose advertisement
// carries the request id and the response flag. The LXMF propagation node protocol is a client of
// this (MESHSAT-1553 P3b).
import Foundation
import MeshSatNet

public final class RequestReceipt: @unchecked Sendable {
    public let link: Link
    public let requestId: [UInt8]
    public let path: String
    var deadlineMs: Int64
    /// The response data (.null for None); fails with `RequestFailed` on failure or timeout.
    public let result = Promise<MpValue>()
    /// A response resource is being received: the deadline no longer applies, the resource's own does.
    var responseStarted = false
    public var requestIdHex: String { requestId.hex }

    init(link: Link, requestId: [UInt8], path: String, deadlineMs: Int64) {
        self.link = link
        self.requestId = requestId
        self.path = path
        self.deadlineMs = deadlineMs
    }
}

public struct RequestFailed: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Link.TRAFFIC_TIMEOUT_FACTOR
let trafficTimeoutFactor: Int64 = 6
/// Resource.RESPONSE_MAX_GRACE_TIME, in milliseconds
let responseMaxGraceTimeMs: Int64 = 10_000

extension LinkManager {
    /// Sends a request on an active link. `timeoutMs` 0 means upstream's default: rtt x 6 plus 11.25 s.
    public func request(_ l: Link, path: String, data: MpValue = .null, timeoutMs: Int64 = 0) throws -> RequestReceipt {
        let nowMs = n.now()
        let packed = Msgpack.pack(.array([.float(Double(nowMs) / 1000.0), .bin(Rns.truncatedHash(Array(path.utf8))), data]))
        let timeout = timeoutMs > 0 ? timeoutMs : l.rttMs * trafficTimeoutFactor + Int64(Double(responseMaxGraceTimeMs) * 1.125)
        let (r, asResource): (RequestReceipt, Bool) = try l.mu.sync {
            guard l.stateRaw == .active || l.stateRaw == .stale else { throw NodeError("link not active") }
            let asResource = packed.count > l.mduRawValue
            let r: RequestReceipt
            if !asResource {
                guard let token = l.token else { throw NodeError("link has no key yet") }
                let raw = sendLinkPacket(l, Rns.packetData, Rns.ctxRequest, try token.encrypt(packed))
                r = RequestReceipt(link: l, requestId: Header.truncatedPacketHash(raw), path: path, deadlineMs: nowMs + timeout)
            } else {
                r = RequestReceipt(link: l, requestId: Rns.truncatedHash(packed), path: path, deadlineMs: nowMs + timeout)
            }
            l.pendingRequests[r.requestIdHex] = r
            return (r, asResource)
        }
        if asResource {
            let res = try sendResource(l, packed, requestId: r.requestId, isResponse: false)
            res.result.onResult { [weak self] out in
                guard let self else { return }
                switch out {
                case .success(let o) where o.delivered: r.deadlineMs = self.n.now() + timeout
                case .success(let o): self.failRequest(r, "request resource failed: \(o.error ?? "")")
                case .failure(let e): self.failRequest(r, "request resource failed: \(e)")
                }
            }
        }
        let how = asResource ? ", as resource" : ""
        n.log("rns: request \(r.requestIdHex.prefix(8)) \(path) on \(l.idHex.prefix(8)) (\(packed.count) bytes\(how))")
        return r
    }

    /// A RESPONSE packet's plaintext: msgpack([request id, data]).
    func handleResponsePacket(_ l: Link, _ plain: [UInt8]) {
        guard let v = (try? Msgpack.unpack(plain))?.value.asArray, v.count >= 2, case .bin(let id) = v[0] else { return }
        completeRequest(l, id, v[1])
    }

    func completeRequest(_ l: Link, _ id: [UInt8], _ data: MpValue) {
        guard let r = l.mu.sync({ l.pendingRequests.removeValue(forKey: id.hex) }) else {
            n.log("rns: response for unknown request \(id.hex8) on \(l.idHex.prefix(8))")
            return
        }
        n.log("rns: response for \(r.requestIdHex.prefix(8)) \(r.path)")
        r.result.complete(data)
    }

    func failRequest(_ r: RequestReceipt, _ why: String) {
        let was = r.link.mu.sync { r.link.pendingRequests.removeValue(forKey: r.requestIdHex) }
        if was != nil { n.log("rns: request \(r.requestIdHex.prefix(8)) \(r.path) failed: \(why)") }
        r.result.fail(RequestFailed(why))
    }

    func pendingRequest(_ l: Link, _ id: [UInt8]) -> RequestReceipt? { l.mu.sync { l.pendingRequests[id.hex] } }

    /// Times out requests that never saw a response start.
    func requestWatchdog(_ nowMs: Int64) {
        for l in all() {
            let expired = l.mu.sync { l.pendingRequests.values.filter { !$0.responseStarted && nowMs > $0.deadlineMs } }
            for r in expired { failRequest(r, "request timed out") }
        }
    }

    func failRequestsOn(_ l: Link, _ why: String) {
        let rs = l.mu.sync { Array(l.pendingRequests.values) }
        for r in rs { failRequest(r, why) }
    }
}
