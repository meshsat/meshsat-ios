// The certificate facts CredentialsScreen.kt reads off an imported PEM with CertificateFactory:
// the subject, the expiry day and a short SHA-256 fingerprint of the DER.
import Crypto
import Foundation
import X509

public struct PemCertificateInfo: Sendable, Equatable {
    /// The subject as RFC 4514 text, at most 100 characters.
    public let subject: String
    /// "yyyy-MM-dd" in UTC.
    public let notAfter: String
    /// The first 8 bytes of SHA-256 over the DER, "AB:CD:...", as Android shows it.
    public let fingerprint: String
}

public enum PemCertificate {
    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// The DER bytes of the first PEM block: the base64 between its BEGIN and END lines.
    public static func derBytes(_ pem: String) -> [UInt8] {
        var inside = false
        var b64 = ""
        for line in pem.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-----BEGIN") {
                inside = true
            } else if line.hasPrefix("-----END") {
                break
            } else if inside {
                b64 += line.trimmingCharacters(in: .whitespaces)
            }
        }
        return Data(base64Encoded: b64).map { Array($0) } ?? []
    }

    public static func parse(_ pem: String) throws -> PemCertificateInfo {
        let cert: Certificate
        do {
            cert = try Certificate(pemEncoded: pem)
        } catch {
            throw ParseError(description: "not an X.509 certificate in PEM form")
        }
        let der = derBytes(pem)
        let fp = SHA256.hash(data: der).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return PemCertificateInfo(
            subject: String(String(describing: cert.subject).prefix(100)), notAfter: f.string(from: cert.notValidAfter), fingerprint: fp)
    }
}
