// MeshSatCrypto: mirrors routing/Identity.kt, reticulum/RnsHkdf.kt, mqtt/CertificatePinner.kt
// (SPKI hashing) and hub/relay/RelayTls.kt (PEM parsing) on swift-crypto and swift-certificates,
// so that the same code runs on Linux in tests and on CryptoKit on the phone.
import Crypto
import Foundation

public enum MeshSatCrypto {
    public static let module = "MeshSatCrypto"

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }
}
