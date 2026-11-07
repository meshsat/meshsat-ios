// Mirrors the platform-free half of rns/AutoInterface.kt (RNS/Interfaces/AutoInterface.py, the
// Bridge's routing/auto_interface.go; MESHSAT-1553 P4, here MESHSAT-1735): the discovery group of
// a group id, the discovery token, the address text rules the token hashes, the peer table with
// its 22 s timeout and reverse peering, and the dedup of a datagram seen on several interfaces.
// The sockets (IPv6 link-local multicast on 29716, UDP data on 42671) are the app's and wait for
// Apple's multicast entitlement (MESHSAT-1828).
import Foundation

public enum AutoInterfaceCore {
    public static let hwMtu = 1196
    public static let discoveryPort = 29716
    public static let dataPort = 42671
    public static let defaultGroup = "reticulum"
    public static let peeringTimeoutMs: Int64 = 22_000
    public static let announceIntervalMs: Int64 = 1_600
    public static let peerJobIntervalMs: Int64 = 4_000
    public static let reversePeeringMs: Int64 = 5_200
    public static let dedupLen = 48
    public static let dedupTtlMs: Int64 = 750

    /// The text of an IPv6 address as inet_ntop prints it (RFC 5952): lowercase, no leading zeros,
    /// the longest run of two or more zero words as "::", the leftmost on a tie. Tokens hash this
    /// text, so it must match what Python's socket gives.
    public static func compress(_ addr: [UInt8]) -> String {
        precondition(addr.count == 16, "not an IPv6 address")
        let words = (0..<8).map { Int(addr[2 * $0]) << 8 | Int(addr[2 * $0 + 1]) }
        var bestStart = -1
        var bestLen = 0
        var i = 0
        while i < 8 {
            guard words[i] == 0 else {
                i += 1
                continue
            }
            var j = i
            while j < 8, words[j] == 0 { j += 1 }
            if j - i > bestLen {
                bestLen = j - i
                bestStart = i
            }
            i = j
        }
        if bestLen < 2 { bestStart = -1 }
        var out = ""
        i = 0
        while i < 8 {
            if i == bestStart {
                out += "::"
                i += bestLen
                continue
            }
            if !out.isEmpty, !out.hasSuffix(":") { out += ":" }
            out += String(words[i], radix: 16)
            i += 1
        }
        return out
    }

    /// As upstream normalises a link-local address: no %scope, and "fe80:<digits>::" collapsed to "fe80::".
    public static func descope(_ addr: String) -> String {
        let bare = String(addr.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard bare.hasPrefix("fe80:"), let end = bare.range(of: "::") else { return bare }
        let start = bare.index(bare.startIndex, offsetBy: 5)
        // "fe80::..." already has no scope digits (its "::" starts inside the prefix).
        guard end.lowerBound >= start else { return bare }
        let middle = bare[start..<end.lowerBound]
        guard middle.allSatisfy({ $0.isHexDigit }) else { return bare }
        return "fe80::" + bare[end.upperBound...]
    }

    /// The discovery token: SHA-256(group id || link-local address text).
    public static func token(groupId: String, linkLocalText: String) -> [UInt8] {
        Rns.sha256(Array(groupId.utf8), Array(linkLocalText.utf8))
    }

    /// The link-local multicast discovery group of a group id: ff12:0:<six words of SHA-256(group id)[2..13]>.
    public static func multicastGroup(_ groupId: String) -> [UInt8] {
        let g = Rns.sha256(Array(groupId.utf8))
        var out = [UInt8](repeating: 0, count: 16)
        out[0] = 0xFF
        out[1] = 0x12
        for k in 0..<6 {
            out[4 + 2 * k] = g[2 + 2 * k]
            out[5 + 2 * k] = g[3 + 2 * k]
        }
        return out
    }

    /// Whether a discovery datagram from `sourceText` carries that address's token.
    public static func verifies(_ datagram: [UInt8], groupId: String, sourceText: String) -> Bool {
        datagram.count >= Rns.fullHashLen && Array(datagram.prefix(Rns.fullHashLen)) == token(groupId: groupId, linkLocalText: sourceText)
    }
}

/// AutoInterface's peers and dedup, behind one lock; the sockets ask it what to do.
public final class AutoPeerTable: @unchecked Sendable {
    public struct Peer: Sendable, Equatable {
        public let address: String
        public let device: String
        public var lastHeardMs: Int64
        public var lastOutMs: Int64
    }

    /// What `jobs(nowMs:)` decided: peers gone silent, peers owed a reverse-peering token.
    public struct Jobs: Sendable, Equatable {
        public let timedOut: [String]
        public let reverse: [Peer]
    }

    private let lock = NSLock()
    private var peers: [String: Peer] = [:]
    private var ownAddresses: Set<String>
    private var dedup: [(hash: [UInt8], atMs: Int64)] = []

    public init(ownAddresses: Set<String> = []) { self.ownAddresses = ownAddresses }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func setOwnAddresses(_ addresses: Set<String>) { locked { ownAddresses = addresses } }
    public var count: Int { locked { peers.count } }
    public func all() -> [Peer] { locked { Array(peers.values).sorted { $0.address < $1.address } } }

    /// A verified token from `address` on `device`. True when it is a new peer; our own multicast
    /// echoed back, or a known peer, only refreshes.
    @discardableResult
    public func heard(address: String, device: String, nowMs: Int64) -> Bool {
        locked {
            if ownAddresses.contains(address) { return false }
            if peers[address] != nil {
                peers[address]?.lastHeardMs = nowMs
                return false
            }
            peers[address] = Peer(address: address, device: device, lastHeardMs: nowMs, lastOutMs: 0)
            return true
        }
    }

    /// A data datagram from `address`: delivered only from a known peer, which it also refreshes.
    public func dataFrom(address: String, nowMs: Int64) -> Bool {
        locked {
            guard peers[address] != nil else { return false }
            peers[address]?.lastHeardMs = nowMs
            return true
        }
    }

    /// The peer job: drop the silent, pick the ones owed a reverse-peering token.
    public func jobs(nowMs: Int64) -> Jobs {
        locked {
            var gone: [String] = []
            var reverse: [Peer] = []
            for (k, p) in peers {
                if nowMs - p.lastHeardMs > AutoInterfaceCore.peeringTimeoutMs {
                    gone.append(k)
                } else if nowMs - p.lastOutMs > AutoInterfaceCore.reversePeeringMs {
                    peers[k]?.lastOutMs = nowMs
                    reverse.append(peers[k] ?? p)
                }
            }
            for k in gone { peers.removeValue(forKey: k) }
            return Jobs(timedOut: gone.sorted(), reverse: reverse.sorted { $0.address < $1.address })
        }
    }

    /// True when the same datagram already came in the last 750 ms (on another adopted interface).
    public func isDuplicate(_ data: [UInt8], nowMs: Int64) -> Bool {
        let h = Rns.sha256(data)
        return locked {
            while let first = dedup.first, nowMs - first.atMs > AutoInterfaceCore.dedupTtlMs { dedup.removeFirst() }
            if dedup.contains(where: { $0.hash == h }) { return true }
            dedup.append((h, nowMs))
            if dedup.count > AutoInterfaceCore.dedupLen { dedup.removeFirst(dedup.count - AutoInterfaceCore.dedupLen) }
            return false
        }
    }

    public func clear() {
        locked {
            peers.removeAll()
            dedup.removeAll()
        }
    }
}
