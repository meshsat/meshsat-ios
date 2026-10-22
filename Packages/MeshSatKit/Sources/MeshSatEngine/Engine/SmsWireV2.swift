// The MeshSat app SMS wire, version 2 (r40 review R40-R1; Android's sms/SmsWireV2.kt, the
// Bridge's codec/smswire.go, the Hub's). Version 1 put protocol byte 0x01 in front of a
// compressed or encrypted SMS and left the receiver to guess the codec, which no rule can do: the
// SMAZ2 of "sara" is the two bytes of "¡". Version 2 says which:
//
//   SMS text = base64( 0x02 | mode | payload )
//   mode 0x00, clear:    payload = codec | body
//   mode 0x01, AES-GCM:  payload = nonce(12) | AES-256-GCM(codec | body) | tag(16)
//   codec 0x00 UTF-8 text, 0x01 SMAZ2 with the default table, 0x02 MSVQ-SC
//
// With a key the codec is inside the ciphertext, so the tag authenticates how the body is read.
// A plain SMS (no key, no compression) stays the typed text. A frame whose mode or codec this app
// does not know is shown as it came, never guessed at. Version 1 and unversioned SMS are still
// read by the old rule (SmsWire.decode), whose ambiguity stays. Shared vectors: the Bridge's
// internal/engine/testdata/sms-wire-v2-vectors.json (Fixtures/smswire, under a lock).
import MeshSatWire

public enum SmsWireV2 {
    public static let version: UInt8 = 0x02
    public static let modeClear: UInt8 = 0x00
    public static let modeAesGcm: UInt8 = 0x01
    public static let codecText: UInt8 = 0x00
    public static let codecSmaz2: UInt8 = 0x01
    public static let codecMsvqsc: UInt8 = 0x02

    /// The frame of `text`, in SmsSender's order: SMAZ2 when `smaz2` is on and it is shorter, else
    /// the MSVQ-SC wire `msvqsc` makes (nil when it cannot encode), else the text.
    public static func frame(_ text: String, smaz2: Bool, msvqsc: (() -> [UInt8]?)? = nil) -> [UInt8] {
        let utf8 = Array(text.utf8)
        if smaz2 {
            let packed = Smaz2.compress(text)
            if !packed.isEmpty, packed.count < utf8.count { return [codecSmaz2] + packed }
        }
        if let wire = msvqsc?() { return [codecMsvqsc] + wire }
        return [codecText] + utf8
    }

    /// The wire bytes of `frame`, clear.
    public static func wire(_ frame: [UInt8]) -> [UInt8] { [version, modeClear] + frame }

    /// The wire bytes of `frame` sealed by `seal` (AES-256-GCM: nonce | ciphertext | tag).
    public static func wire(_ frame: [UInt8], seal: ([UInt8]) throws -> [UInt8]) rethrows -> [UInt8] {
        [version, modeAesGcm] + (try seal(frame))
    }

    /// What a v2 SMS reads as.
    public enum Read: Sendable, Equatable {
        /// Not v2: the version 1 rule reads it.
        case notV2
        /// v2 this app cannot read (an unknown mode or codec, no key that opens it): shown as it came.
        case kept(encrypted: Bool)
        case text(String, encrypted: Bool, codec: UInt8)
    }

    /// Reads decoded SMS bytes. `open` tries the sender's keys on a sealed payload (nil when none
    /// opens it); `msvqsc` decodes an MSVQ-SC body (nil without a codebook).
    public static func read(_ raw: [UInt8], open: ([UInt8]) -> [UInt8]?, msvqsc: (([UInt8]) -> String?)? = nil) -> Read {
        guard raw.count >= 3, raw[0] == version else { return .notV2 }
        let payload = Array(raw[2...])
        let frame: [UInt8]
        let encrypted: Bool
        switch raw[1] {
        case modeClear:
            (frame, encrypted) = (payload, false)
        case modeAesGcm:
            guard let clear = open(payload) else { return .kept(encrypted: false) }
            (frame, encrypted) = (clear, true)
        default:
            return .kept(encrypted: false)
        }
        guard let codec = frame.first else { return .kept(encrypted: encrypted) }
        let body = Array(frame.dropFirst())
        let text: String?
        switch codec {
        case codecText: text = strictUTF8(body)
        case codecSmaz2: text = (try? Smaz2Bytes.decompress(body, dict: .default)).flatMap(strictUTF8)
        case codecMsvqsc: text = msvqsc?(body)
        default: text = nil
        }
        guard let text else { return .kept(encrypted: encrypted) }
        return .text(text, encrypted: encrypted, codec: codec)
    }

    /// UTF-8 that decodes without a repair, else nil. Decoding repairs a bad sequence with U+FFFD,
    /// so the bytes change (String(validating:as:) would say it directly, but needs iOS 18).
    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        let s = String(decoding: bytes, as: UTF8.self)
        return Array(s.utf8) == bytes ? s : nil
    }
}
