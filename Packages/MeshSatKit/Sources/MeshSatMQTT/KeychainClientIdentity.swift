// The Hub's client certificate on the phone (MESHSAT-1324). The public broker sits behind TLS
// that NATS itself terminates with `verify: true` against the bridge CA, so a bridge that shows
// no certificate is dropped in the handshake; username and password are checked on top.
// Network.framework takes a client certificate only as a SecIdentity, and iOS has no call that
// makes one from a key and a certificate: both go into the Keychain (this device only, after
// first unlock) and the identity is read back from there. The bundle's `ca` is the CA that signs
// bridge certificates, never a server trust root; the server is a public certificate and the
// system roots check it.
#if canImport(Security)
import CryptoKit
import Foundation
import Logging
import Security

public enum KeychainClientIdentity {
    private static let log = Logger(label: "KeychainClientIdentity")
    static let label = "net.meshsat.ios.hub-client"

    public struct IdentityError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// The SecIdentity for this PEM certificate and PEM private key (SEC1 "EC PRIVATE KEY" or
    /// PKCS#8 "PRIVATE KEY", P-256 as the Hub issues). Replaces what an earlier provisioning left.
    public static func make(certPem: String, keyPem: String) throws -> SecIdentity {
        let der = derBytes(certPem)
        guard !der.isEmpty, let cert = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw IdentityError(description: "the client certificate is not a PEM certificate")
        }
        let p256: P256.Signing.PrivateKey
        do {
            p256 = try P256.Signing.PrivateKey(pemRepresentation: keyPem.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw IdentityError(description: "the client key is not a P-256 PEM key: \(error)")
        }
        var cfError: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateWithData(p256.x963Representation as CFData, attrs as CFDictionary, &cfError) else {
            throw IdentityError(
                description: "the client key was refused: \(cfError?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        remove()
        let keyStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassKey, kSecValueRef as String: key, kSecAttrLabel as String: label,
                kSecAttrApplicationTag as String: Data(label.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw IdentityError(description: "Keychain refused the client key (\(keyStatus))")
        }
        let certStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert, kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw IdentityError(description: "Keychain refused the client certificate (\(certStatus))")
        }
        // The identity is the pair the Keychain matched by the public key; pick ours by its DER.
        // Right after the two adds the Keychain can still answer "not found" (-25300, the first
        // connect after launch on 25 Sep 2026), so ask a few times.
        var found: CFTypeRef?
        var status = errSecItemNotFound
        let query =
            [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            as CFDictionary
        for attempt in 0..<10 {
            if attempt > 0 { usleep(100_000) }
            status = SecItemCopyMatching(query, &found)
            if status != errSecItemNotFound { break }
        }
        guard status == errSecSuccess, let items = found as? [SecIdentity] else {
            throw IdentityError(description: "no identity for the client certificate (\(status))")
        }
        for identity in items {
            var c: SecCertificate?
            if SecIdentityCopyCertificate(identity, &c) == errSecSuccess, let c, SecCertificateCopyData(c) as Data == Data(der) {
                log.info("Client identity ready for the Hub")
                return identity
            }
        }
        throw IdentityError(description: "the client key does not belong to the client certificate")
    }

    /// Forget the stored key and certificate (a new provisioning, or the Hub switched off).
    public static func remove() {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(label.utf8)] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
    }

    static func derBytes(_ pem: String) -> [UInt8] {
        var inside = false
        var b64 = ""
        for line in pem.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                inside = true
            } else if line.hasPrefix("-----END") {
                if inside { break }
            } else if inside {
                b64 += line.trimmingCharacters(in: .whitespaces)
            }
        }
        return Data(base64Encoded: b64).map { Array($0) } ?? []
    }
}
#endif
