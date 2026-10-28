// Mirrors rns/Wire.kt (object Rns): the Reticulum protocol constants and hash helpers, as the
// Bridge's internal/reticulum/constants.go and identity.go hold them.
import Crypto
import Foundation

public enum Rns {
    public static let mtu = 500
    public static let headerMinSize = 19  // flags + hops + dest(16) + context
    public static let headerMaxSize = 35  // flags + hops + transport(16) + dest(16) + context
    public static let ifacMinSize = 1
    public static let mdu = mtu - headerMaxSize - ifacMinSize  // 464

    public static let hashLen = 16  // truncated hash (destinations, link ids, transport ids)
    public static let fullHashLen = 32
    public static let nameHashLen = 10
    public static let sigLen = 64
    public static let pubLen = 32  // one x25519 or ed25519 public key
    public static let keyLen = 64  // announce public key: x25519 pub || ed25519 pub
    public static let ratchetLen = 32
    public static let randomHashLen = 10  // 5 random + 5 timestamp (big endian seconds)
    public static let pathfinderM = 128  // maximum hops
    public static let announceCap = 2  // percent of an interface's time
    public static let tokenOverhead = 48  // iv(16) + hmac(32)
    public static let aesBlock = 16
    public static let derivedKeyLen = 64

    /// Largest plaintext of one encrypted single packet at MTU 500 (RNS/Packet.py ENCRYPTED_MDU).
    public static let encryptedMdu = ((mdu - tokenOverhead - pubLen) / aesBlock) * aesBlock - 1  // 383

    /// Largest plaintext of one packet on a link (RNS/Link.py MDU): 431 at MTU 500. Mirrors
    /// rns/LinkWire.kt mdu(mtu).
    public static func linkMdu(mtu: Int = Rns.mtu) -> Int {
        ((mtu - ifacMinSize - headerMinSize - tokenOverhead) / aesBlock) * aesBlock - 1
    }

    // Packet types (flags bits 1..0)
    public static let packetData = 0x00
    public static let packetAnnounce = 0x01
    public static let packetLinkRequest = 0x02
    public static let packetProof = 0x03

    // Destination types (flags bits 3..2)
    public static let destSingle = 0x00
    public static let destGroup = 0x01
    public static let destPlain = 0x02
    public static let destLink = 0x03

    // Transport types (flags bit 4)
    public static let transportBroadcast = 0x00
    public static let transportTransport = 0x01

    // Header types (flags bit 6)
    public static let header1 = 0x00
    public static let header2 = 0x01

    // Context byte
    public static let ctxNone = 0x00
    public static let ctxResource = 0x01
    public static let ctxResourceAdv = 0x02
    public static let ctxResourceReq = 0x03
    public static let ctxResourceHmu = 0x04
    public static let ctxResourcePrf = 0x05
    public static let ctxResourceIcl = 0x06
    public static let ctxResourceRcl = 0x07
    public static let ctxCacheRequest = 0x08
    public static let ctxRequest = 0x09
    public static let ctxResponse = 0x0A
    public static let ctxPathResponse = 0x0B
    public static let ctxCommand = 0x0C
    public static let ctxCommandStatus = 0x0D
    public static let ctxChannel = 0x0E
    public static let ctxKeepalive = 0xFA
    public static let ctxLinkIdentify = 0xFB
    public static let ctxLinkClose = 0xFC
    public static let ctxLinkProof = 0xFD
    public static let ctxLrrtt = 0xFE
    public static let ctxLrProof = 0xFF

    // Transport timing (RNS/Transport.py, RNS/Link.py), seconds unless named otherwise
    public static let pathfinderR = 1  // announce rebroadcast retries
    public static let pathfinderG = 5.0  // grace before a rebroadcast
    public static let pathfinderRW = 0.5  // random window on top of it
    public static let pathfinderE: Int64 = 60 * 60 * 24 * 7  // path expiry, one week
    public static let localRebroadcastsMax = 2
    public static let pathRequestTimeout = 15
    public static let pathRequestGrace = 0.4
    public static let reverseTimeout = 8 * 60
    public static let linkTimeout = 60 * 60 * 2
    public static let perHopTimeout = 6
    public static let keepaliveMax = 360
    public static let keepaliveMin = 5
    public static let staleGrace = 5

    /// The PLAIN destination every transport node listens on for path requests.
    public static let pathRequestDestName = "rnstransport.path.request"
    public static var pathRequestDestHash: [UInt8] { plainDestHash(pathRequestDestName) }

    public static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    public static func truncatedHash(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Array(h.finalize().prefix(hashLen))
    }

    /// SHA-256("app.aspect1.aspect2")[:10].
    public static func nameHash(_ name: String) -> [UInt8] { Array(sha256(Array(name.utf8)).prefix(nameHashLen)) }

    /// SHA-256(x25519 pub || ed25519 pub)[:16].
    public static func identityHash(encPub: [UInt8], sigPub: [UInt8]) -> [UInt8] { truncatedHash(encPub, sigPub) }

    /// SHA-256(name hash || identity hash)[:16].
    public static func destHash(nameHash: [UInt8], identityHash: [UInt8]) -> [UInt8] { truncatedHash(nameHash, identityHash) }

    /// A PLAIN destination's hash: SHA-256(name hash)[:16], no identity.
    public static func plainDestHash(_ name: String) -> [UInt8] { truncatedHash(nameHash(name)) }

    public static func randomBytes(_ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        for i in out.indices { out[i] = UInt8.random(in: 0...255) }
        return out
    }
}

/// Thrown for bytes that do not parse as the wire format says (rns/Wire.kt WireException).
public struct WireError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
