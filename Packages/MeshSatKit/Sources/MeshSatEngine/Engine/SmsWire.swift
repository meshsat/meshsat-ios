// Mirrors the wire pipeline of sms/SmsSender.kt and sms/SmsReceiver.kt (MESHSAT-447): what a
// MeshSat SMS carries when it is compressed or encrypted. Android sends from the SIM; iOS
// hands the same text to the Messages composer. Both ends of a kit conversation must agree
// byte for byte, so the steps are the Kotlin's:
//
//   send:    text -> frame (codec byte | smaz2 / MSVQ-SC / text) -> [AES-256-GCM] -> 0x02 mode -> base64
//   receive: base64 -> v2 sealed: decrypt -> the codec the frame names -> text
//                   -> v1: version byte off -> [decrypt] -> smaz2 if it round trips, else MSVQ-SC
//                   -> v2 clear, only when no key opened it the v1 way -> the codec it names
//
// Version 2 (SmsWireV2, r40 review R40-R1) is what this app sends; version 1 is still read.
import Foundation
import MeshSatMsvqsc
import MeshSatWire

public enum SmsWire {
    public struct Encoded: Sendable, Equatable {
        /// What goes in the SMS: the text itself, or base64 of the transformed bytes.
        public let body: String
        public let compressed: Bool
        public let encrypted: Bool
        public init(body: String, compressed: Bool, encrypted: Bool) {
            self.body = body
            self.compressed = compressed
            self.encrypted = encrypted
        }
    }

    /// SmsSender.send's steps, the app SMS wire v2. `smaz2` and `msvqscEncoder` are exclusive as
    /// on Android: smaz2 first, then MSVQ-SC only when smaz2 did nothing; a compressor that gains
    /// nothing is skipped; an MSVQ-SC encoder that fails leaves the text as it is. A plain SMS (no
    /// key, nothing compressed) goes as typed.
    public static func encode(
        _ text: String, encryptionKey: String? = nil, smaz2: Bool = false, msvqscEncoder: (any MsvqscEncoding)? = nil, msvqscStages: Int = 3
    ) -> Encoded {
        let frame = SmsWireV2.frame(text, smaz2: smaz2, msvqsc: msvqscEncoder.map { enc in { enc.encode(text, maxStages: msvqscStages) } })
        let compressed = frame[0] != SmsWireV2.codecText
        if let key = encryptionKey, !key.isEmpty,
            let sealed = try? SmsWireV2.wire(frame, seal: { try AesGcmCrypto.encrypt($0, hexKey: key) })
        {
            return Encoded(body: Base64Std.encode(sealed), compressed: compressed, encrypted: true)
        }
        guard compressed else { return Encoded(body: text, compressed: false, encrypted: false) }
        return Encoded(body: Base64Std.encode(SmsWireV2.wire(frame)), compressed: true, encrypted: false)
    }

    public struct Decoded: Sendable, Equatable {
        public let text: String
        /// The SMS as received when it was transformed; empty for plain text.
        public let rawText: String
        public let wasEncrypted: Bool
        public let wasCompressed: Bool
        public init(text: String, rawText: String, wasEncrypted: Bool, wasCompressed: Bool) {
            self.text = text
            self.rawText = rawText
            self.wasEncrypted = wasEncrypted
            self.wasCompressed = wasCompressed
        }
    }

    /// SmsReceiver.processIncoming's steps. `keys` in the order to try (per sender, the Hub
    /// wildcard, the global key); the first that decrypts wins.
    public static func decode(_ text: String, keys: [String] = [], codebook: MsvqscCodebook? = nil, autoDecrypt: Bool = true) -> Decoded {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawBytes = Base64Std.decode(trimmed), rawBytes.count >= 2 else {
            return Decoded(text: text, rawText: "", wasEncrypted: false, wasCompressed: false)
        }
        let usable = autoDecrypt ? keys.filter { !$0.isEmpty } : []
        // The app SMS wire v2: the frame names its codec, so nothing is guessed. What a key opens is
        // read first: a sealed v2 frame here, version 1 or unversioned below. Only then a clear v2
        // frame, which nothing authenticates: an old sender's random nonce, or a Bridge chain's, can
        // start 02 00 with a rest that reads, and the key that opens it must win (r41 review V2). A
        // frame whose mode or codec this app does not read, or that no key opens, is shown as it came.
        let v2 = SmsWireV2.read(
            rawBytes,
            open: { sealed in usable.lazy.compactMap { try? AesGcmCrypto.decrypt(sealed, hexKey: $0) }.first },
            msvqsc: codebook.map { cb in { try? cb.decode($0) } })
        if case .text(let clear, encrypted: true, let codec) = v2 {
            return Decoded(text: clear, rawText: text, wasEncrypted: true, wasCompressed: codec != SmsWireV2.codecText)
        }
        // Version 1 or unversioned.
        var payload = ProtocolVersion.stripVersionByte(rawBytes).data
        var wasEncrypted = false
        if autoDecrypt, AesGcmCrypto.looksEncrypted(trimmed) {
            for key in usable {
                if let clear = try? AesGcmCrypto.decrypt(payload, hexKey: key) {
                    payload = clear
                    wasEncrypted = true
                    break
                }
            }
        }
        if case .text(let clear, encrypted: false, let codec) = v2, !wasEncrypted {
            return Decoded(text: clear, rawText: text, wasEncrypted: false, wasCompressed: codec != SmsWireV2.codecText)
        }
        if case .kept(let encrypted) = v2, !wasEncrypted {
            return Decoded(text: text, rawText: "", wasEncrypted: encrypted, wasCompressed: false)
        }
        if wasEncrypted || payload != rawBytes {
            // Compressed only if compressing the text again gives these very bytes: the senders
            // (both apps, the Bridge, the Hub) compress byte for byte alike and only when it
            // gains. An uncompressed payload read as SMAZ2 turns each byte above 0x7F into a
            // bigram, so an encrypted Greek SMS, never compressed, came out as ASCII gibberish
            // that passed any printable check. [MESHSAT-1628]
            // A payload that is itself readable UTF-8 with a character above ASCII is the text: read
            // as SMAZ2, a word like "Καλημέρα" is all bigrams whose letters compress back to the
            // same bytes, which the round trip cannot tell. [MESHSAT-1646]
            if !Self.isPlainNonASCII(payload), let smaz = Smaz2.decompress(payload), Self.isPrintable(smaz),
                Smaz2.compress(smaz) == payload
            {
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
    /// Readable UTF-8 text with at least one character above ASCII: an uncompressed Greek,
    /// accented or emoji text, never a compressed payload in practice (its verbatim counts and
    /// word codes are control bytes, its bigram codes mostly stray bytes above 0x7F). [MESHSAT-1646]
    static func isPlainNonASCII(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(where: { $0 >= 0x80 }) else { return false }
        // Valid UTF-8 only: decoding repairs a bad sequence with U+FFFD, so the bytes change.
        // (String(validating:as:) would say it directly, but needs iOS 18; the app runs on 17.)
        let s = String(decoding: bytes, as: UTF8.self)
        return Array(s.utf8) == bytes && isPrintable(s)
    }

    /// Readable text, as Android's `SmsReceiver.smaz2Text`: tab, CR, LF and every scalar from U+0020
    /// up except DEL, the C1 controls and U+FFFD (broken UTF-8). Greek, accented and emoji text pass;
    /// what decodes to control bytes is not taken as compressed. It took ASCII only. [MESHSAT-1628]
    static func isPrintable(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { c in
            c == "\n" || c == "\r" || c == "\t"
                || (c.value >= 0x20 && c.value != 0x7F && !(0x80...0x9F).contains(c.value) && c.value != 0xFFFD)
        }
    }
}
