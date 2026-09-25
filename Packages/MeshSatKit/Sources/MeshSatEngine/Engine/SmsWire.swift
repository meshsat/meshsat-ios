// Mirrors the wire pipeline of sms/SmsSender.kt and sms/SmsReceiver.kt (MESHSAT-447): what a
// MeshSat SMS carries when it is compressed or encrypted. Android sends from the SIM; iOS
// hands the same text to the Messages composer. Both ends of a kit conversation must agree
// byte for byte, so the steps are the Kotlin's:
//
//   send:    text -> [smaz2 | MSVQ-SC] -> [AES-256-GCM] -> version byte -> base64
//   receive: base64 -> version byte off -> [decrypt] -> smaz2 if printable, else MSVQ-SC -> text
import Foundation
import MeshSatMsvqsc
import MeshSatWire

public enum SmsWire {
    public struct Encoded: Sendable, Equatable {
        /// What goes in the SMS: the text itself, or base64 of the transformed bytes.
        public let body: String
        public let compressed: Bool
        public let encrypted: Bool
    }

    /// SmsSender.send's steps 0 to 4. `smaz2` and `msvqscEncoder` are exclusive as on Android:
    /// smaz2 first, then MSVQ-SC only when smaz2 did nothing; a compressor that gains nothing is
    /// skipped; an MSVQ-SC encoder that fails leaves the text as it is.
    public static func encode(
        _ text: String, encryptionKey: String? = nil, smaz2: Bool = false, msvqscEncoder: (any MsvqscEncoding)? = nil, msvqscStages: Int = 3
    ) -> Encoded {
        var payload = Array(text.utf8)
        var compressed = false
        if smaz2 {
            let packed = Smaz2.compress(text)
            if packed.count < payload.count {
                payload = packed
                compressed = true
            }
        }
        if let encoder = msvqscEncoder, !compressed, let wire = encoder.encode(text, maxStages: msvqscStages) {
            payload = wire
            compressed = true
        }
        let key = (encryptionKey ?? "").isEmpty ? nil : encryptionKey
        var encrypted = false
        if let key {
            if let sealed = try? AesGcmCrypto.encrypt(payload, hexKey: key) {
                payload = sealed
                encrypted = true
            }
        }
        guard compressed || encrypted else { return Encoded(body: text, compressed: false, encrypted: false) }
        payload = ProtocolVersion.prependVersionByte(payload)
        return Encoded(body: Base64Std.encode(payload), compressed: compressed, encrypted: encrypted)
    }

    public struct Decoded: Sendable, Equatable {
        public let text: String
        /// The SMS as received when it was transformed; empty for plain text.
        public let rawText: String
        public let wasEncrypted: Bool
        public let wasCompressed: Bool
    }

    /// SmsReceiver.processIncoming's steps. `keys` in the order to try (per sender, the Hub
    /// wildcard, the global key); the first that decrypts wins.
    public static func decode(_ text: String, keys: [String] = [], codebook: MsvqscCodebook? = nil, autoDecrypt: Bool = true) -> Decoded {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawBytes = Base64Std.decode(trimmed), rawBytes.count >= 2 else {
            return Decoded(text: text, rawText: "", wasEncrypted: false, wasCompressed: false)
        }
        var payload = ProtocolVersion.stripVersionByte(rawBytes).data
        var wasEncrypted = false
        if autoDecrypt, AesGcmCrypto.looksEncrypted(trimmed) {
            for key in keys where !key.isEmpty {
                if let clear = try? AesGcmCrypto.decrypt(payload, hexKey: key) {
                    payload = clear
                    wasEncrypted = true
                    break
                }
            }
        }
        if wasEncrypted || payload != rawBytes {
            if let smaz = Smaz2.decompress(payload), Self.isPrintable(smaz) {
                return Decoded(text: smaz, rawText: text, wasEncrypted: wasEncrypted, wasCompressed: true)
            }
        }
        if let codebook, MsvqscWire.looksLikeMsvqsc(payload), let decoded = try? codebook.decode(payload) {
            return Decoded(text: decoded, rawText: text, wasEncrypted: wasEncrypted, wasCompressed: true)
        }
        if wasEncrypted {
            return Decoded(text: String(decoding: payload, as: UTF8.self), rawText: text, wasEncrypted: true, wasCompressed: false)
        }
        return Decoded(text: text, rawText: "", wasEncrypted: false, wasCompressed: false)
    }

    /// Printable ASCII, tab, CR and LF: what a smaz2 result must be to count as text.
    static func isPrintable(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) || $0 == "\n" || $0 == "\r" || $0 == "\t" }
    }
}
