// Mirrors hub/BirthSigner.kt: birth messages signed with ECDSA P-256 over SHA-256, so the Hub
// can tell a bridge from an impostor. The certificate (base64 of its PEM) goes in, the
// signature comes out, and what is signed is the canonical JSON: sorted keys, no whitespace,
// byte for byte what Go's json.Marshal of a map produces.
import Crypto
import Foundation
import Logging

public enum BirthSigner {
    private static let log = Logger(label: "BirthSigner")

    /// Sign `birth` in place: adds "certificate" and "signature". False, and the birth stays
    /// unsigned, when there is no key or it cannot be read.
    @discardableResult
    public static func sign(_ birth: inout JSONBody, certPem: String, keyPem: String) -> Bool {
        let cert = certPem.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyPem.trimmingCharacters(in: .whitespacesAndNewlines)
        if cert.isEmpty || key.isEmpty { return false }
        do {
            birth.put("certificate", Data(certPem.utf8).base64EncodedString())
            birth.remove("signature")
            let canonical = birth.text(sortedKeys: true)
            let privateKey = try P256.Signing.PrivateKey(pemRepresentation: key)
            let signature = try privateKey.signature(for: Data(canonical.utf8))
            birth.put("signature", signature.derRepresentation.base64EncodedString())
            log.info("Birth signed (\(signature.derRepresentation.count) bytes, canonical \(canonical.utf8.count) chars)")
            return true
        } catch {
            log.warning("Birth signing failed: \(error)")
            birth.remove("certificate")
            birth.remove("signature")
            return false
        }
    }

    /// The Hub's check, here for the tests: the signature over the canonical JSON without
    /// "signature", verified with the certificate's key... which needs X.509 parsing; the
    /// tests verify with the key pair directly.
    public static func verify(_ birth: JSONBody, publicKey: P256.Signing.PublicKey) -> Bool {
        guard let sigB64 = birth.string("signature"), let der = Data(base64Encoded: sigB64) else { return false }
        var unsigned = birth
        unsigned.remove("signature")
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else { return false }
        return publicKey.isValidSignature(signature, for: Data(unsigned.text(sortedKeys: true).utf8))
    }
}
