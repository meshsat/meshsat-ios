// Mirrors engine/SatelliteChain.kt (MESHSAT-1623): the kits' encrypted satellite chain over IMT
// (HeMB-NG S3-2, the "H chain"), byte for byte as a MeshSat Bridge writes and reads it: the
// protocol version byte 0x01, then AES-256-GCM (12-byte nonce, ciphertext, 16-byte tag) of a
// smaz2g frame with the Meshtastic word table. No AAD and no base64. The version byte is outside
// the encryption and is added or taken off exactly once; the smaz2g mode byte is inside it. For
// n UTF-8 bytes and SMAZ2 output z the wire is 30 + min(n, z) bytes.
//
// It lives here, beside the TransformPipeline whose steps it runs and whose TransformError it
// throws, as Android's engine/ has it; the 9704 driver that carries the wire is in
// MeshSatMeshtastic, which this module does not depend on. [MESHSAT-1624]
import Foundation
import MeshSatWire

public enum SatelliteChain {
    public static let protocolVersion: UInt8 = 0x01

    /// The key the kits' chain names (encrypt key_ref): a key bundle's iridium entry for "shared".
    public static let keyRef = "iridium:shared"
    public static let keyAddress = "shared"

    /// Version byte, nonce, mode byte and tag: what the chain adds to the shorter of n and z.
    public static let overhead = 30

    /// One IMT message, and so the longest wire the chain may make: Iridium9704Driver.imtMaxSize,
    /// which the 9704 driver enforces (a test holds the two equal).
    public static let maxWireBytes = 100_000

    /// The setting's values: as the text is with nothing declared, the same declared, or the chain.
    public static let modeUndeclared = ""
    public static let modePlain = "plain"
    public static let modeSealed = "sealed"

    /// The chain's steps: smaz2g with the Meshtastic table, then encrypt with `keyHex`.
    public static func steps(keyHex: String) -> [TransformSpec] {
        [
            TransformSpec(type: "smaz2g", params: ["dict": "meshtastic"]),
            TransformSpec(type: "encrypt", params: ["key": keyHex]),
        ]
    }

    /// The wire for `payload`. Throws `TransformError` when it cannot be sealed (no key, a key
    /// that is not 32 bytes of hex): a message meant to be sealed is never sent as plaintext.
    public static func seal(_ payload: [UInt8], keyHex: String?, pipeline: TransformPipeline = TransformPipeline()) throws -> [UInt8] {
        let key = try checkKey(keyHex)
        let wire = [protocolVersion] + (try pipeline.applyEgress(payload, steps(keyHex: key)))
        if wire.count > maxWireBytes {
            throw TransformError("too long for one satellite message: \(wire.count) bytes sealed, \(maxWireBytes) at most")
        }
        return wire
    }

    /// The payload of `wire`. Throws `TransformError` when it does not open: no version byte, no
    /// key or a wrong one, changed or cut bytes, a malformed frame.
    public static func open(_ wire: [UInt8], keyHex: String?, pipeline: TransformPipeline = TransformPipeline()) throws -> [UInt8] {
        guard wire.first == protocolVersion else { throw TransformError("satellite chain: no protocol version byte") }
        let key = try checkKey(keyHex)
        return try pipeline.applyIngress(Array(wire.dropFirst()), steps(keyHex: key))
    }

    /// Exactly 64 ASCII hex digits. Character.isHexDigit also takes the fullwidth forms, so the
    /// bytes are checked instead.
    private static func checkKey(_ keyHex: String?) throws -> String {
        guard let keyHex, keyHex.utf8.count == 64,
            keyHex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) })
        else { throw TransformError("satellite chain: no key for \(keyRef)") }
        return keyHex
    }

    /// What an IMT message from the satellite is, once it is not a Reticulum packet (Android's
    /// SatelliteChain.Mt; type names are three characters at least here).
    public enum MtMessage: Sendable, Equatable {
        /// A text: `sealed` when it came through the chain and opened.
        case text(String, sealed: Bool)
        /// A MeshSat versioned payload that did not open: never shown as a guess.
        case unopened(reason: String)
    }

    /// Reads one IMT payload. One that starts with the version byte is MeshSat's and is opened
    /// with the chain, or reported `.unopened`; anything else is a plain text as before (a typed
    /// text never starts with byte 0x01).
    public static func readMt(_ payload: [UInt8], keyHex: String?, pipeline: TransformPipeline = TransformPipeline()) -> MtMessage {
        guard payload.first == protocolVersion else { return .text(String(decoding: payload, as: UTF8.self), sealed: false) }
        do {
            let text = try open(payload, keyHex: keyHex, pipeline: pipeline)
            return .text(String(decoding: text, as: UTF8.self), sealed: true)
        } catch {
            return .unopened(reason: (error as? TransformError)?.description ?? "does not open")
        }
    }

    /// Whether a delivery goes through the chain: a text. An SOS or a burst is a frame the Hub
    /// reads by its own magic before anything else, as the Bridge's own frames bypass its chain,
    /// so it goes as it is; so does any payload that is not UTF-8 text.
    public static func sealsDelivery(msgRef: String, payload: [UInt8]) -> Bool {
        !msgRef.hasPrefix("sos:") && !msgRef.hasPrefix("burst:") && isUtf8(payload)
    }

    /// Strict UTF-8, as Java's decoder with REPORT: a malformed or truncated sequence is not text.
    private static func isUtf8(_ bytes: [UInt8]) -> Bool {
        let failed = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true) { _ in }
        return !failed
    }

    /// What the Hub birth declares for the modem (egress_format): "sealed", "plain", or nil for
    /// nothing.
    public static func egressFormat(_ mode: String?) -> String? {
        if mode == modeSealed { return "sealed" }
        if mode == modePlain { return "plain" }
        return nil
    }
}
