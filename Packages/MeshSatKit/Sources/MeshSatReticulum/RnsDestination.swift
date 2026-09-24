// Mirrors reticulum/RnsDestination.kt: Reticulum-compatible destination hash computation.
//
//   name_hash     = SHA-256(app_name.aspect1.aspect2...)[:10]   (80 bits)
//   identity_hash = SHA-256(encryption_pub + signing_pub)[:16]  (128 bits)
//   dest_hash     = SHA-256(name_hash + identity_hash)[:16]     (128 bits)
//
// Reticulum orders the keys (X25519 encryption, Ed25519 signing) in the identity hash, which
// differs from the original MeshSat order (signing, encryption) in routing/Identity.kt.
import Crypto
import Foundation

public enum RnsDestination {
    /// Default MeshSat application name for Reticulum destinations.
    public static let appName = "meshsat"
    /// Standard aspect for MeshSat node destinations.
    public static let aspectNode = "node"

    public static func fullHash(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }

    /// SHA-256(data)[:16].
    public static func truncatedHash(_ data: [UInt8]) -> [UInt8] { Array(fullHash(data).prefix(RnsConstants.destHashLen)) }

    /// name_hash = SHA-256("appname.aspect1.aspect2")[:10]
    public static func nameHash(_ appName: String, _ aspects: String...) -> [UInt8] {
        nameHash(appName, aspects: aspects)
    }

    public static func nameHash(_ appName: String, aspects: [String]) -> [UInt8] {
        Array(fullHash(Array(expandName(appName, aspects: aspects).utf8)).prefix(RnsConstants.nameHashLen))
    }

    /// expandName("meshsat", "node") is "meshsat.node".
    public static func expandName(_ appName: String, _ aspects: String...) -> String { expandName(appName, aspects: aspects) }

    public static func expandName(_ appName: String, aspects: [String]) -> String {
        aspects.isEmpty ? appName : appName + "." + aspects.joined(separator: ".")
    }

    /// identity_hash = SHA-256(encryption_pub + signing_pub)[:16], encryption key first.
    public static func identityHash(encryptionPub: [UInt8], signingPub: [UInt8]) -> [UInt8] {
        Array(fullHash(encryptionPub + signingPub).prefix(RnsConstants.identityHashLen))
    }

    /// dest_hash = SHA-256(name_hash + identity_hash)[:16]: the primary addressing mechanism.
    public static func computeDestHash(
        encryptionPub: [UInt8], signingPub: [UInt8], appName: String = RnsDestination.appName,
        aspects: [String] = [RnsDestination.aspectNode]
    ) -> [UInt8] {
        truncatedHash(nameHash(appName, aspects: aspects) + identityHash(encryptionPub: encryptionPub, signingPub: signingPub))
    }

    /// A PLAIN destination (no identity): dest_hash = SHA-256(name_hash)[:16].
    public static func computePlainDestHash(_ appName: String, _ aspects: String...) -> [UInt8] {
        truncatedHash(nameHash(appName, aspects: aspects))
    }

    /// random_hash = SHA-256(random_bytes)[:16], for announce dedup, nonces and the like.
    public static func randomHash() -> [UInt8] {
        var random = [UInt8](repeating: 0, count: RnsConstants.destHashLen)
        for i in random.indices { random[i] = UInt8.random(in: 0...255) }
        return truncatedHash(random)
    }

    /// ratchet_id = SHA-256(ratchet_pub)[:10]
    public static func ratchetId(_ ratchetPub: [UInt8]) -> [UInt8] { Array(fullHash(ratchetPub).prefix(RnsConstants.ratchetIdLen)) }
}
