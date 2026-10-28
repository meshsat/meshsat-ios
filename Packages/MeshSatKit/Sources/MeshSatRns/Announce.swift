// Mirrors rns/Announce.kt (the Bridge's internal/reticulum/announce.go): an announce
// (RNS/Destination.py announce, RNS/Identity.py validate_announce). Data field: public key (64)
// || name hash (10) || random hash (10) || [ratchet (32), when the header's context flag is set]
// || signature (64) || app data. The signature covers dest hash || public key || name hash ||
// random hash || [ratchet] || app data. The random hash is 5 random bytes and a 5-byte big-endian
// emission time, which transport nodes compare to decide whether a re-announce is newer than the
// path they hold.
import Foundation

public struct Announce: Sendable, Equatable {
    public let destHash: [UInt8]
    public var hops: Int
    public let contextFlag: Int
    public var context: Int
    public let publicKey: [UInt8]
    public let nameHash: [UInt8]
    public let random: [UInt8]
    public let ratchet: [UInt8]?
    public var signature: [UInt8]
    public let appData: [UInt8]

    /// pubkey(64) + name(10) + random(10) + signature(64).
    public static let minPayload = Rns.keyLen + Rns.nameHashLen + Rns.randomHashLen + Rns.sigLen  // 148
    public static let ratchetPayload = minPayload + Rns.ratchetLen  // 180

    public init(
        destHash: [UInt8], hops: Int, contextFlag: Int, context: Int, publicKey: [UInt8], nameHash: [UInt8], random: [UInt8],
        ratchet: [UInt8]?, signature: [UInt8], appData: [UInt8]
    ) {
        self.destHash = destHash
        self.hops = hops
        self.contextFlag = contextFlag
        self.context = context
        self.publicKey = publicKey
        self.nameHash = nameHash
        self.random = random
        self.ratchet = ratchet
        self.signature = signature
        self.appData = appData
    }

    public var encPub: [UInt8] { Array(publicKey.prefix(Rns.pubLen)) }
    public var sigPub: [UInt8] { Array(publicKey.dropFirst(Rns.pubLen).prefix(Rns.pubLen)) }

    /// The announced identity, public only; nil when the key bytes are not valid keys.
    public var identity: RnsIdentity? { RnsIdentity.fromPublicBytesOrNil(publicKey) }

    public func payload() -> [UInt8] {
        var out = publicKey + nameHash + random
        if contextFlag != 0 { out += ratchet ?? [UInt8](repeating: 0, count: Rns.ratchetLen) }
        return out + signature + appData
    }

    /// The packet as the originator emits it: HEADER_1, broadcast.
    public func packet() throws -> [UInt8] {
        try Header(
            headerType: Rns.header1, contextFlag: contextFlag, transportType: Rns.transportBroadcast, destType: Rns.destSingle,
            packetType: Rns.packetAnnounce, hops: hops, destHash: destHash, context: context, data: payload()
        ).pack()
    }

    /// The packet as a transport node rebroadcasts it: HEADER_2 with the transport's IDENTITY
    /// hash, transport type TRANSPORT, the given hops and context (NONE, or PATH_RESPONSE when it
    /// answers a path request).
    public func transportPacket(transportId: [UInt8], hops: Int, context: Int) throws -> [UInt8] {
        try Header(
            headerType: Rns.header2, contextFlag: contextFlag, transportType: Rns.transportTransport, destType: Rns.destSingle,
            packetType: Rns.packetAnnounce, hops: hops, transportId: transportId, destHash: destHash, context: context,
            data: payload()
        ).pack()
    }

    /// Emission time in unix seconds from the random hash, or 0 when it is not a plausible timestamp.
    public func emittedAt() -> Int64 {
        let ts = Announce.blobTimestamp(random)
        return (ts < 1_600_000_000 || ts > 4_000_000_000) ? 0 : ts
    }

    public func signableBody() -> [UInt8] {
        var out = destHash + publicKey + nameHash + random
        if contextFlag != 0 { out += ratchet ?? [UInt8](repeating: 0, count: Rns.ratchetLen) }
        return out + appData
    }

    /// Nil when valid, otherwise why not.
    public func verify() -> String? {
        guard publicKey.count == Rns.keyLen else { return "public key is \(publicKey.count) bytes" }
        let computed = Rns.destHash(nameHash: nameHash, identityHash: Rns.identityHash(encPub: encPub, sigPub: sigPub))
        guard computed == destHash else { return "destination hash mismatch" }
        guard RnsIdentity.verifySignature(sigPub: sigPub, data: signableBody(), signature: signature) else {
            return "invalid announce signature"
        }
        return nil
    }

    /// The 5-byte big-endian timestamp at the end of a 10-byte random hash.
    public static func blobTimestamp(_ blob: [UInt8]) -> Int64 {
        guard blob.count >= Rns.randomHashLen else { return 0 }
        var ts: Int64 = 0
        for i in 5..<10 { ts = (ts << 8) | Int64(blob[i]) }
        return ts
    }

    /// A signed announce for `name` on `identity`, with the ratchet public key when the
    /// destination runs ratchets (Destination.announce).
    public static func create(
        identity: RnsIdentity, name: String, appData: [UInt8]?, ratchetPub: [UInt8]? = nil,
        nowSec: Int64 = Int64(Date().timeIntervalSince1970), pathResponse: Bool = false
    ) throws -> Announce {
        var random = Rns.randomBytes(5)
        for i in 0..<5 { random.append(UInt8((nowSec >> Int64(8 * (4 - i))) & 0xFF)) }
        var a = Announce(
            destHash: identity.destHash(name), hops: 0, contextFlag: ratchetPub != nil ? 1 : 0,
            context: pathResponse ? Rns.ctxPathResponse : Rns.ctxNone, publicKey: identity.publicBytes,
            nameHash: Rns.nameHash(name), random: random, ratchet: ratchetPub, signature: [], appData: appData ?? [])
        a.signature = try identity.sign(a.signableBody())
        return a
    }

    /// Parses the data field of an announce packet whose header is already parsed.
    public static func unpackPayload(
        _ data: [UInt8], destHash: [UInt8], hops: Int, contextFlag: Int, context: Int = Rns.ctxNone
    ) throws -> Announce {
        let min = contextFlag != 0 ? ratchetPayload : minPayload
        guard data.count >= min else { throw WireError("announce payload \(data.count) bytes, need \(min)") }
        var pos = 0
        func take(_ n: Int) -> [UInt8] {
            defer { pos += n }
            return Array(data[pos..<pos + n])
        }
        let pub = take(Rns.keyLen)
        let name = take(Rns.nameHashLen)
        let random = take(Rns.randomHashLen)
        let ratchet: [UInt8]? = contextFlag != 0 ? take(Rns.ratchetLen) : nil
        let sig = take(Rns.sigLen)
        let app = Array(data[pos...])
        return Announce(
            destHash: destHash, hops: hops, contextFlag: contextFlag, context: context, publicKey: pub, nameHash: name,
            random: random, ratchet: ratchet, signature: sig, appData: app)
    }

    public static func unpackPacket(_ raw: [UInt8]) throws -> Announce {
        let h = try Header.unpack(raw)
        guard h.packetType == Rns.packetAnnounce else { throw WireError("not an announce") }
        return try unpackPayload(h.data, destHash: h.destHash, hops: h.hops, contextFlag: h.contextFlag, context: h.context)
    }
}
