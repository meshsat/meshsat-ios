// Mirrors rns/LinkWire.kt (the Bridge's internal/reticulum/rnslink.go): the link handshake wire
// format of RNS/Link.py: the request, the proof, the signalling bytes, the RTT packet,
// identification and keepalives. Pinned to Python RNS 1.5.5 by the link.*, linkproof.* and rtt.*
// vectors of Fixtures/lxmf/golden.properties.
import Foundation
import MeshSatReticulum

public enum LinkWire {
    public static let linkIdLen = Rns.hashLen
    /// initiator x25519 pub (32) || ed25519 pub (32)
    public static let ecPubSize = 64
    /// The signalling bytes.
    public static let mtuSize = 3
    public static let mtuByteMask = 0x1F_FFFF
    public static let modeByteMask = 0xE0
    public static let modeAes128Cbc = 0x00
    /// The only mode RNS 1.5.x enables.
    public static let modeAes256Cbc = 0x01
    public static let modeDefault = modeAes256Cbc
    public static let keepaliveInitiator: UInt8 = 0xFF
    public static let keepaliveResponse: UInt8 = 0xFE

    /// Largest plaintext of one link packet at an MTU: floor((mtu - 1 - 19 - 48) / 16) * 16 - 1, 431 at 500.
    public static func mdu(_ mtu: Int) -> Int {
        ((mtu - Rns.ifacMinSize - Rns.headerMinSize - Rns.tokenOverhead) / Rns.aesBlock) * Rns.aesBlock - 1
    }

    /// big-endian uint32((mtu & 0x1FFFFF) | (((mode << 5) & 0xE0) << 16))[1:].
    public static func signalling(mtu: Int, mode: Int) -> [UInt8] {
        let v = (mtu & mtuByteMask) | (((mode << 5) & modeByteMask) << 16)
        return [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// (mtu, mode) from signalling bytes; (500, default) when absent.
    public static func parseSignalling(_ s: [UInt8], offset: Int = 0) -> (mtu: Int, mode: Int) {
        guard s.count >= offset + mtuSize else { return (Rns.mtu, modeDefault) }
        let b0 = Int(s[offset])
        let mtu = ((b0 << 16) | (Int(s[offset + 1]) << 8) | Int(s[offset + 2])) & mtuByteMask
        return (mtu, (b0 & modeByteMask) >> 5)
    }

    /// The data of a LINKREQUEST packet: eph x25519 pub || eph ed25519 pub || [signalling].
    public struct Request: Sendable, Equatable {
        public let ephPub: [UInt8]
        public let ephSigPub: [UInt8]
        public let mtu: Int
        public let mode: Int
        public let signalled: Bool

        public init(ephPub: [UInt8], ephSigPub: [UInt8], mtu: Int = Rns.mtu, mode: Int = LinkWire.modeDefault, signalled: Bool = true) {
            self.ephPub = ephPub
            self.ephSigPub = ephSigPub
            self.mtu = mtu
            self.mode = mode
            self.signalled = signalled
        }

        public func pack() -> [UInt8] { ephPub + ephSigPub + LinkWire.signalling(mtu: mtu, mode: mode) }

        public static func unpack(_ data: [UInt8]) throws -> Request {
            guard data.count == ecPubSize || data.count == ecPubSize + mtuSize else {
                throw WireError("link request must be 64 or 67 bytes, got \(data.count)")
            }
            let eph = Array(data[0..<Rns.pubLen])
            let sig = Array(data[Rns.pubLen..<ecPubSize])
            var mtu = Rns.mtu
            var mode = modeDefault
            var signalled = false
            if data.count == ecPubSize + mtuSize {
                (mtu, mode) = parseSignalling(data, offset: ecPubSize)
                signalled = true
            }
            guard mode == modeAes256Cbc else { throw WireError("link mode \(mode) not enabled") }
            return Request(ephPub: eph, ephSigPub: sig, mtu: mtu, mode: mode, signalled: signalled)
        }
    }

    /// The link id: the truncated hash of the request packet's hashable part with the
    /// signalling bytes removed (Link.link_id_from_lr_packet).
    public static func linkIdFromRequestPacket(_ raw: [UInt8]) throws -> [UInt8] {
        let h = try Header.unpack(raw)
        var hashable = Header.hashablePart(raw)
        let diff = h.data.count - ecPubSize
        if diff > 0 { hashable.removeLast(diff) }
        return Array(Rns.sha256(hashable).prefix(linkIdLen))
    }

    /// The data of the LRPROOF packet: signature (64) || responder eph x25519 pub (32) || [signalling].
    public struct ProofData: Sendable, Equatable {
        public let signature: [UInt8]
        public let ephPub: [UInt8]
        public let mtu: Int
        public let mode: Int
        public let signalled: Bool

        public init(signature: [UInt8], ephPub: [UInt8], mtu: Int = Rns.mtu, mode: Int = LinkWire.modeDefault, signalled: Bool = true) {
            self.signature = signature
            self.ephPub = ephPub
            self.mtu = mtu
            self.mode = mode
            self.signalled = signalled
        }

        public func pack() -> [UInt8] { signature + ephPub + LinkWire.signalling(mtu: mtu, mode: mode) }

        public static func unpack(_ data: [UInt8]) throws -> ProofData {
            let base = Rns.sigLen + Rns.pubLen
            guard data.count == base || data.count == base + mtuSize else {
                throw WireError("link proof must be 96 or 99 bytes, got \(data.count)")
            }
            let sig = Array(data[0..<Rns.sigLen])
            let eph = Array(data[Rns.sigLen..<base])
            var mtu = Rns.mtu
            var mode = modeDefault
            var signalled = false
            if data.count == base + mtuSize {
                (mtu, mode) = parseSignalling(data, offset: base)
                signalled = true
            }
            return ProofData(signature: sig, ephPub: eph, mtu: mtu, mode: mode, signalled: signalled)
        }
    }

    /// What the responder's identity signs: link id || responder eph pub || responder identity ed25519 pub || signalling.
    public static func proofSignedData(
        linkId: [UInt8], ephPub: [UInt8], identitySigPub: [UInt8], mtu: Int, mode: Int, signalled: Bool = true
    ) -> [UInt8] {
        let base = linkId + ephPub + identitySigPub
        return signalled ? base + signalling(mtu: mtu, mode: mode) : base
    }

    /// The link key: HKDF(64, shared, salt = link id).
    public static func deriveLinkKey(shared: [UInt8], linkId: [UInt8]) -> [UInt8] {
        RnsHkdf.derive(length: Rns.derivedKeyLen, from: shared, salt: linkId)
    }

    /// The LRRTT plaintext: the RTT in seconds as msgpack float64.
    public static func rttData(_ rttSeconds: Double) -> [UInt8] { Msgpack.pack(.float(rttSeconds)) }

    public static func parseRttData(_ b: [UInt8]) -> Double? {
        guard let v = try? Msgpack.unpack(b).value else { return nil }
        switch v {
        case .float(let f): return f
        case .int(let i): return Double(i)
        case .uint64(let u): return Double(u)
        default: return nil
        }
    }

    /// The LINKIDENTIFY plaintext: public key (64) || sign(link id || public key).
    public static func identifyData(identity: RnsIdentity, linkId: [UInt8]) throws -> [UInt8] {
        let pub = identity.publicBytes
        return pub + (try identity.sign(linkId + pub))
    }

    /// Verifies a LINKIDENTIFY plaintext and returns the identified 64-byte public key, or nil.
    public static func parseIdentify(_ data: [UInt8], linkId: [UInt8]) -> [UInt8]? {
        guard data.count == Rns.keyLen + Rns.sigLen else { return nil }
        let pub = Array(data[0..<Rns.keyLen])
        let sigPub = Array(pub[Rns.pubLen..<Rns.keyLen])
        guard RnsIdentity.verifySignature(sigPub: sigPub, data: linkId + pub, signature: Array(data[Rns.keyLen...])) else { return nil }
        return pub
    }
}
