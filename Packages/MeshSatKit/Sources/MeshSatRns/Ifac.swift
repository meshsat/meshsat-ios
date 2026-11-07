// Mirrors the Ifac class of rns/Wire.kt (RNS/Transport.py's interface access codes): two peers
// with the same network name and/or passphrase derive one 64-byte key whose second half seeds
// an Ed25519 signing key. Every packet carries the last `size` bytes of the signature over the
// clean packet after the hops byte, and everything but the tag is XOR-masked with
// HKDF(tag, salt = key). Bit 7 of the flags marks an IFAC packet. Pinned by the ifac.* vectors;
// the Hub's Private networks are the user of it.
import Foundation
import MeshSatReticulum
import MeshSatWire

public final class Ifac: Sendable {
    public static let defaultSize = 16
    public static let salt: [UInt8] = Hex.decode("adf54d882c9a9b80771eb4995d702d4a3e733391b2a0f53f416d9f907e55cff8") ?? []

    public let key: [UInt8]
    public let size: Int
    private let signer: RnsIdentity

    public init(netname: String, netkey: String, size: Int = Ifac.defaultSize) throws {
        guard !netname.isEmpty || !netkey.isEmpty else { throw WireError("IFAC needs a network name or passphrase") }
        guard (Rns.ifacMinSize...64).contains(size) else { throw WireError("IFAC size must be 1..64") }
        self.size = size
        key = Self.ifacKey(netname: netname, netkey: netkey)
        signer = try RnsIdentity.fromPrivateBytes(key)
    }

    public static func ifacKey(netname: String, netkey: String) -> [UInt8] {
        var origin: [UInt8] = []
        if !netname.isEmpty { origin += Rns.sha256(Array(netname.utf8)) }
        if !netkey.isEmpty { origin += Rns.sha256(Array(netkey.utf8)) }
        return RnsHkdf.derive(length: 64, from: Rns.sha256(origin), salt: salt)
    }

    public static func hasFlag(_ raw: [UInt8]) -> Bool { !raw.isEmpty && raw[0] & 0x80 != 0 }

    /// The packet with the access code: flag set, tag after the hops byte, the rest masked.
    public func wrap(_ raw: [UInt8]) throws -> [UInt8] {
        guard raw.count >= 2 else { return raw }
        let sig = try signer.sign(raw)
        let tag = Array(sig[(sig.count - size)...])
        let mask = RnsHkdf.derive(length: raw.count + size, from: tag, salt: key)
        var out = [UInt8](repeating: 0, count: raw.count + size)
        out[0] = raw[0] | 0x80
        out[1] = raw[1]
        out.replaceSubrange(2..<(2 + size), with: tag)
        out.replaceSubrange((2 + size)..., with: raw[2...])
        for i in out.indices where i < 2 || i >= 2 + size { out[i] ^= mask[i] }
        out[0] |= 0x80
        return out
    }

    /// Verifies and strips the access code, or throws `WireError`.
    public func unwrap(_ raw: [UInt8]) throws -> [UInt8] {
        guard raw.count > 2 + size else { throw WireError("IFAC packet too short") }
        guard raw[0] & 0x80 != 0 else { throw WireError("IFAC flag missing") }
        let tag = Array(raw[2..<(2 + size)])
        let mask = RnsHkdf.derive(length: raw.count, from: tag, salt: key)
        var unmasked = raw
        for i in raw.indices where i < 2 || i >= 2 + size { unmasked[i] = raw[i] ^ mask[i] }
        var clean = [UInt8](repeating: 0, count: raw.count - size)
        clean[0] = unmasked[0] & 0x7F
        clean[1] = unmasked[1]
        clean.replaceSubrange(2..., with: unmasked[(2 + size)...])
        let sig = try signer.sign(clean)
        guard constantTimeEqual(Array(sig[(sig.count - size)...]), tag) else { throw WireError("IFAC tag invalid") }
        return clean
    }

    private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
