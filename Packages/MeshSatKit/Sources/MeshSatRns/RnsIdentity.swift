// Mirrors rns/RnsIdentity.kt (the Bridge's internal/reticulum/identity.go and encrypt.go): an
// RNS identity (RNS/Identity.py), an X25519 encryption key and an Ed25519 signing key. Public
// key bytes are x25519 pub (32) || ed25519 pub (32); private bytes, as Identity.from_bytes takes
// them, x25519 private (32) || ed25519 seed (32).
//
// On swift-crypto (CryptoKit on the phone). The app's routing identity (MeshSatCrypto.Identity)
// converts with fromRouting, keeping the keys and so the hashes the phone already announces.
import Crypto
import Foundation
import MeshSatCrypto
import MeshSatReticulum
import MeshSatWire

public final class RnsIdentity: Sendable {
    // swift-crypto's key types are not Sendable; the raw 32-byte seeds are, and the keys are
    // rebuilt from them on each use (microseconds), as MeshSatCrypto.Identity does.
    private let encPriv: [UInt8]?
    private let sigSeed: [UInt8]?
    public let encPubRaw: [UInt8]
    public let sigPubRaw: [UInt8]

    /// The 64-byte announce public key.
    public var publicBytes: [UInt8] { encPubRaw + sigPubRaw }

    /// SHA-256(public key)[:16], the transport id of a node running on this identity.
    public let hash: [UInt8]
    public var hashHex: String { Hex.encode(hash) }

    public var hasPrivateKey: Bool { encPriv != nil && sigSeed != nil }

    private init(encPriv: [UInt8]?, encPub: [UInt8], sigSeed: [UInt8]?, sigPub: [UInt8]) {
        self.encPriv = encPriv
        self.sigSeed = sigSeed
        encPubRaw = encPub
        sigPubRaw = sigPub
        hash = Rns.identityHash(encPub: encPub, sigPub: sigPub)
    }

    /// x25519 private (32) || ed25519 seed (32), RNS Identity.get_private_key order.
    public func privateBytes() throws -> [UInt8] {
        guard let e = encPriv, let s = sigSeed else { throw WireError("identity holds no private key") }
        return e + s
    }

    public func sign(_ data: [UInt8]) throws -> [UInt8] {
        guard let s = sigSeed, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: s) else {
            throw WireError("identity cannot sign")
        }
        return Array(try key.signature(for: data))
    }

    public func verify(_ data: [UInt8], signature: [UInt8]) -> Bool {
        RnsIdentity.verifySignature(sigPub: sigPubRaw, data: data, signature: signature)
    }

    public func destHash(_ name: String) -> [UInt8] { Rns.destHash(nameHash: Rns.nameHash(name), identityHash: hash) }

    /// The data field of an encrypted single packet to this identity: ephemeral x25519 pub (32)
    /// || Token(HKDF(64, shared, salt = identity hash)). With `ratchetPub` the ECDH runs against
    /// the destination's latest announced ratchet instead of its identity key (Identity.encrypt).
    public func encrypt(_ plaintext: [UInt8], ratchetPub: [UInt8]? = nil) throws -> [UInt8] {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let target = ratchetPub ?? encPubRaw
        guard let shared = Identity.ecdh(eph, remotePublicRaw: target) else { throw WireError("bad x25519 public key") }
        let tok = try Token(key: RnsHkdf.derive(length: Rns.derivedKeyLen, from: shared, salt: hash))
        return Array(eph.publicKey.rawRepresentation) + (try tok.encrypt(plaintext))
    }

    /// Reverses `encrypt`. `ratchetPrivs` are this identity's own ratchet private keys, newest
    /// first, tried before the identity key. Returns the plaintext and the index of the ratchet
    /// that worked (-1 for the identity key), or nil when nothing does.
    public func decrypt(_ data: [UInt8], ratchetPrivs: [[UInt8]] = []) throws -> (plaintext: [UInt8], ratchet: Int)? {
        guard let e = encPriv else { throw WireError("identity cannot decrypt") }
        guard data.count > Rns.pubLen else { return nil }
        let peerPub = Array(data[0..<Rns.pubLen])
        let ct = Array(data[Rns.pubLen...])
        func attempt(_ prv: [UInt8]) -> [UInt8]? {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: prv),
                let shared = Identity.ecdh(key, remotePublicRaw: peerPub),
                let tok = try? Token(key: RnsHkdf.derive(length: Rns.derivedKeyLen, from: shared, salt: hash))
            else { return nil }
            return try? tok.decrypt(ct)
        }
        for (i, r) in ratchetPrivs.enumerated() where r.count == Rns.ratchetLen {
            if let plain = attempt(r) { return (plain, i) }
        }
        if let plain = attempt(e) { return (plain, -1) }
        return nil
    }

    // MARK: construction

    public static func generate() -> RnsIdentity {
        let e = Curve25519.KeyAgreement.PrivateKey()
        let s = Curve25519.Signing.PrivateKey()
        return RnsIdentity(
            encPriv: Array(e.rawRepresentation), encPub: Array(e.publicKey.rawRepresentation),
            sigSeed: Array(s.rawRepresentation), sigPub: Array(s.publicKey.rawRepresentation))
    }

    /// RNS Identity.from_bytes: x25519 private (32) || ed25519 seed (32).
    public static func fromPrivateBytes(_ prv: [UInt8]) throws -> RnsIdentity {
        guard prv.count == Rns.keyLen else { throw WireError("private key must be 64 bytes, got \(prv.count)") }
        guard let e = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Array(prv[0..<Rns.pubLen])),
            let s = try? Curve25519.Signing.PrivateKey(rawRepresentation: Array(prv[Rns.pubLen...]))
        else { throw WireError("private key bytes are not valid keys") }
        return RnsIdentity(
            encPriv: Array(e.rawRepresentation), encPub: Array(e.publicKey.rawRepresentation),
            sigSeed: Array(s.rawRepresentation), sigPub: Array(s.publicKey.rawRepresentation))
    }

    /// A public-only identity from the 64-byte announce key: encrypts to and verifies, never signs or decrypts.
    public static func fromPublicBytes(_ pub: [UInt8]) throws -> RnsIdentity {
        guard pub.count == Rns.keyLen else { throw WireError("public key must be 64 bytes, got \(pub.count)") }
        let encPub = Array(pub[0..<Rns.pubLen])
        let sigPub = Array(pub[Rns.pubLen...])
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encPub)) != nil,
            (try? Curve25519.Signing.PublicKey(rawRepresentation: sigPub)) != nil
        else { throw WireError("public key bytes are not valid keys") }
        return RnsIdentity(encPriv: nil, encPub: encPub, sigSeed: nil, sigPub: sigPub)
    }

    public static func fromPublicBytesOrNil(_ pub: [UInt8]) -> RnsIdentity? { try? fromPublicBytes(pub) }

    /// The app's routing identity as an RNS identity: same keys, so the same hashes.
    public static func fromRouting(_ identity: Identity) -> RnsIdentity {
        RnsIdentity(
            encPriv: identity.encryptionPrivateRaw, encPub: identity.encryptionPubRaw, sigSeed: identity.signingSeedRaw,
            sigPub: identity.signingPubRaw)
    }

    public static func verifySignature(sigPub: [UInt8], data: [UInt8], signature: [UInt8]) -> Bool {
        guard sigPub.count == Rns.pubLen, signature.count == Rns.sigLen else { return false }
        return Identity.verifyWithRaw(sigPub, data: data, signature: signature)
    }

    // MARK: raw key helpers for ratchets and link handshakes

    /// A fresh x25519 private key (32 bytes): a ratchet, or a link's ephemeral key.
    public static func generateX25519() -> [UInt8] { Array(Curve25519.KeyAgreement.PrivateKey().rawRepresentation) }

    public static func generateRatchet() -> [UInt8] { generateX25519() }

    /// The public key of a raw x25519 private key.
    public static func ratchetPublic(_ prv: [UInt8]) -> [UInt8]? {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: prv)).map { Array($0.publicKey.rawRepresentation) }
    }

    /// X25519 ECDH on raw keys.
    public static func x25519Agree(prv: [UInt8], pub: [UInt8]) -> [UInt8]? {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: prv) else { return nil }
        return Identity.ecdh(key, remotePublicRaw: pub)
    }

    /// A fresh ed25519 seed (32 bytes) for a link's ephemeral signing key.
    public static func generateSigningSeed() -> [UInt8] { Array(Curve25519.Signing.PrivateKey().rawRepresentation) }

    public static func signingPublicOfSeed(_ seed: [UInt8]) -> [UInt8]? {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)).map { Array($0.publicKey.rawRepresentation) }
    }

    public static func signWithSeed(_ seed: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        return (try? key.signature(for: data)).map { Array($0) }
    }
}
