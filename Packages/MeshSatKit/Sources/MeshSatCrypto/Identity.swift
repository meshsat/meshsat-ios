// Mirrors routing/Identity.kt: the routing identity, an Ed25519 signing key and an X25519
// encryption key, on swift-crypto (CryptoKit on the phone). Keys persist as hex of the raw
// 32-byte seeds under Android's key names; Android stores PKCS#8/X.509 DER there, which only
// matters if a store were ever copied between the two apps, and it is not.
import Crypto
import Foundation
import MeshSatWire

/// A key-value store for the identity's keys (Android: KeyValueStore in routing/Identity.kt).
public protocol IdentityStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

public final class Identity: Sendable {
    public static let destHashLen = 16
    static let keySigningPriv = "routing_signing_key_private"
    static let keySigningPub = "routing_signing_key_public"
    static let keyEncryptionPriv = "routing_encryption_key_private"
    static let keyEncryptionPub = "routing_encryption_key_public"

    // swift-crypto's key types are not Sendable; the raw 32-byte seeds are, and the keys are
    // rebuilt from them on each use (microseconds).
    private let signingSeed: [UInt8]
    private let encryptionSeed: [UInt8]
    private var signingPrivate: Curve25519.Signing.PrivateKey {
        // The seed came from a valid key, so this cannot fail.
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: signingSeed)) ?? Curve25519.Signing.PrivateKey()
    }
    private var encryptionPrivate: Curve25519.KeyAgreement.PrivateKey {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: encryptionSeed)) ?? Curve25519.KeyAgreement.PrivateKey()
    }
    /// Raw 32-byte Ed25519 public key (for the wire).
    public let signingPubRaw: [UInt8]
    /// Raw 32-byte X25519 public key (for the wire).
    public let encryptionPubRaw: [UInt8]
    /// 16-byte MeshSat destination hash: SHA-256(signingPub || encryptionPub)[:16].
    public let destHash: [UInt8]
    public var destHashHex: String { Hex.encode(destHash) }

    init(signing: Curve25519.Signing.PrivateKey, encryption: Curve25519.KeyAgreement.PrivateKey) {
        signingSeed = Array(signing.rawRepresentation)
        encryptionSeed = Array(encryption.rawRepresentation)
        signingPubRaw = Array(signing.publicKey.rawRepresentation)
        encryptionPubRaw = Array(encryption.publicKey.rawRepresentation)
        destHash = Identity.computeDestHash(signingPubRaw: signingPubRaw, encryptionPubRaw: encryptionPubRaw)
    }

    /// A fresh identity with new key pairs.
    public static func generate() -> Identity {
        Identity(signing: Curve25519.Signing.PrivateKey(), encryption: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Load the stored identity, or generate and persist a new one.
    public static func loadOrGenerate(store: any IdentityStore) -> Identity {
        if let sigHex = store.get(keySigningPriv), let encHex = store.get(keyEncryptionPriv),
            let sig = Hex.decode(sigHex), let enc = Hex.decode(encHex),
            let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: sig),
            let encryption = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: enc)
        {
            return Identity(signing: signing, encryption: encryption)
        }
        let id = generate()
        id.persist(store: store)
        return id
    }

    /// Persist the keys as hex.
    public func persist(store: any IdentityStore) {
        store.set(Self.keySigningPriv, Hex.encode(signingSeed))
        store.set(Self.keySigningPub, Hex.encode(signingPubRaw))
        store.set(Self.keyEncryptionPriv, Hex.encode(encryptionSeed))
        store.set(Self.keyEncryptionPub, Hex.encode(encryptionPubRaw))
    }

    /// Sign with Ed25519: a 64-byte signature.
    public func sign(_ data: [UInt8]) -> [UInt8] {
        Array((try? signingPrivate.signature(for: data)) ?? Data())
    }

    /// Verify an Ed25519 signature against this identity's key.
    public func verify(_ data: [UInt8], signature: [UInt8]) -> Bool {
        Identity.verifyWithRaw(signingPubRaw, data: data, signature: signature)
    }

    /// X25519 ECDH with a raw 32-byte remote public key: the 32-byte shared secret.
    public func sharedSecret(with remotePublicRaw: [UInt8]) -> [UInt8]? {
        Identity.ecdh(encryptionPrivate, remotePublicRaw: remotePublicRaw)
    }

    /// MeshSat's destination hash: SHA-256(signing_pub + encryption_pub)[:16] (Go's routing/identity.go).
    public static func computeDestHash(signingPubRaw: [UInt8], encryptionPubRaw: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: signingPubRaw + encryptionPubRaw).prefix(destHashLen))
    }

    /// Verify an Ed25519 signature with a raw 32-byte public key.
    public static func verifyWithRaw(_ pubKeyRaw: [UInt8], data: [UInt8], signature: [UInt8]) -> Bool {
        guard pubKeyRaw.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyRaw) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// X25519 ECDH between a private key and a raw remote public key.
    public static func ecdh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, remotePublicRaw: [UInt8]) -> [UInt8]? {
        guard remotePublicRaw.count == 32, let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicRaw),
            let shared = try? privateKey.sharedSecretFromKeyAgreement(with: remote)
        else { return nil }
        return shared.withUnsafeBytes { Array($0) }
    }
}
