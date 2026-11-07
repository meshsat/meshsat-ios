// Mirrors rns/PaidLinks.kt (the Bridge's MESHSAT-1547/1548, for the phone MESHSAT-1553 P6).
//
// A paid bearer (Iridium, SMS) never appears in `Transmitter.floodable()`, so no announce, path
// request or pathless packet is ever broadcast on it. That keeps a mesh from spending satellite
// messages on background traffic, but a destination behind the satellite can then never be
// learned. A `PaidPolicy` opens one paid interface for a short list of destinations: their
// announces, path requests and path responses cross it, each at most once per `minIntervalMs`
// per destination. Both ends should list the same destinations.
//
// `extraHops` is added to the hop count of EVERY packet that arrives on the interface, on top of
// the usual one: the slow hop counts as several. A stock client times a link setup out at its
// first-hop timeout plus 6 s per hop, far below a satellite round trip; counting the hop as N
// gives it the time the link takes (6 x (hops + 3) >= 2 x the one-way delay).
import Foundation
import MeshSatWire

public struct PaidPolicy: Sendable, Equatable {
    public static let defaultMinIntervalMs: Int64 = 5 * 60 * 1000
    /// Keeps an inflated path well inside PATHFINDER_M.
    public static let maxExtraHops = 32

    public let dests: [[UInt8]]
    public let minIntervalMs: Int64
    /// Bit rate for the announce cap when the transmitter reports none; 0 leaves the cap off.
    public let bitrate: Int
    public let extraHops: Int

    public init(dests: [[UInt8]], minIntervalMs: Int64 = PaidPolicy.defaultMinIntervalMs, bitrate: Int = 0, extraHops: Int = 0) {
        precondition((0...PaidPolicy.maxExtraHops).contains(extraHops), "extra hops must be 0..\(PaidPolicy.maxExtraHops)")
        self.dests = dests
        self.minIntervalMs = minIntervalMs
        self.bitrate = bitrate
        self.extraHops = extraHops
    }

    public func allows(_ dest: [UInt8]) -> Bool { dests.contains(dest) }

    /// `dest1,dest2|minIntervalSec|bitrate|extraHops`, for settings.
    public func serialize() -> String {
        dests.map(\.hex).joined(separator: ",") + "|\(minIntervalMs / 1000)|\(bitrate)|\(extraHops)"
    }

    public static func parse(_ s: String) -> PaidPolicy? {
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        var seen = Set<String>()
        var dests: [[UInt8]] = []
        for h in parts[0].split(separator: ",").map(String.init) where h.count == 2 * Rns.hashLen {
            guard let b = Hex.decode(h), seen.insert(h).inserted else { continue }
            dests.append(b)
        }
        guard let sec = Int64(parts[1]), let br = Int(parts[2]), let eh = Int(parts[3]) else { return nil }
        guard sec >= 0, br >= 0, (0...maxExtraHops).contains(eh) else { return nil }
        return PaidPolicy(dests: dests, minIntervalMs: sec == 0 ? defaultMinIntervalMs : sec * 1000, bitrate: br, extraHops: eh)
    }
}

enum PaidKind: Hashable, Sendable {
    case announce
    case pathRequest
}

struct PaidKey: Hashable, Sendable {
    let iface: String
    let dest: String
    let kind: PaidKind
}

struct CrossingKey: Hashable, Sendable {
    let iface: String
    let dest: String
    let inbound: Bool
}

/// One data packet that crossed a paid link with a policy.
public struct PaidCrossing: Sendable, Equatable {
    public let iface: String
    public let inbound: Bool
    public let dest: [UInt8]
    public let bytes: Int
}

private let crossingGapMs: Int64 = 60_000

extension Node {
    /// Installs (or with nil or an empty list removes) the policy for one paid interface, which must stay out of floodable().
    public func setPaidPolicy(_ ifaceId: String, _ p: PaidPolicy?) {
        lock.sync {
            if let p, !p.dests.isEmpty { paid[ifaceId] = p } else { paid[ifaceId] = nil }
        }
    }

    public func paidPolicies() -> [String: PaidPolicy] { lock.sync { paid } }

    /// The paid interfaces, other than `except`, that `dest` may cross now; books the send on each.
    func paidTake(_ dest: [UInt8], _ kind: PaidKind, except: String) -> [String] {
        let ids: [String] = lock.sync {
            paid.isEmpty ? [] : paid.filter { $0.key != except && $0.value.allows(dest) }.map(\.key).sorted()
        }
        if ids.isEmpty { return ids }
        let nowMs = now()
        return ids.filter { tx.online(ifaceId: $0) && paidBook($0, dest, kind, nowMs) }
    }

    /// One send on a named interface: true without a policy, otherwise only for a listed destination whose interval passed (then booked).
    func paidGate(_ ifaceId: String, _ dest: [UInt8], _ kind: PaidKind) -> Bool {
        guard let p = lock.sync({ paid[ifaceId] }) else { return true }
        if !p.allows(dest) {
            count { $0.paidSuppressed += 1 }
            return false
        }
        return paidBook(ifaceId, dest, kind, now())
    }

    func paidBook(_ ifaceId: String, _ dest: [UInt8], _ kind: PaidKind, _ nowMs: Int64) -> Bool {
        lock.sync {
            guard let p = paid[ifaceId] else { return false }
            let k = PaidKey(iface: ifaceId, dest: dest.hex, kind: kind)
            if let last = paidLast[k], nowMs - last < p.minIntervalMs {
                statsRaw.paidSuppressed += 1
                return false
            }
            paidLast[k] = nowMs
            statsRaw.paidTx += 1
            return true
        }
    }

    /// The bit rate the announce cap uses on an interface.
    func announceBitrate(_ ifaceId: String) -> Int {
        let b = tx.bitrate(ifaceId: ifaceId)
        if b > 0 { return b }
        return lock.sync { paid[ifaceId]?.bitrate ?? 0 }
    }

    /// The hop count added to packets arriving on an interface.
    func paidExtraHops(_ ifaceId: String) -> Int { lock.sync { paid[ifaceId]?.extraHops ?? 0 } }

    /// Whether the known path to `dest` leaves this node on a paid interface with a policy, i.e. over the satellite.
    public func crossesPaidLink(_ dest: [UInt8]) -> Bool {
        let iface = nextHopInterface(dest)
        if iface.isEmpty { return false }
        return lock.sync { paid[iface] != nil }
    }

    /// Reports a DATA packet with no special context on a paid interface that has a policy, once a minute per interface, destination and direction.
    func noteCrossing(_ ifaceId: String, _ raw: [UInt8], inbound: Bool) {
        guard let cb = onPaidCrossing else { return }
        guard lock.sync({ paid[ifaceId] != nil }) else { return }
        guard let h = Header.unpackOrNil(raw), h.packetType == Rns.packetData, h.context == Rns.ctxNone else { return }
        let k = CrossingKey(iface: ifaceId, dest: h.destHash.hex, inbound: inbound)
        let nowMs = now()
        let report: Bool = lock.sync {
            if let last = crossings[k], nowMs - last < crossingGapMs { return false }
            crossings[k] = nowMs
            return true
        }
        if report { cb(PaidCrossing(iface: ifaceId, inbound: inbound, dest: h.destHash, bytes: raw.count)) }
    }
}
