// Mirrors engine/SatelliteChain.kt (MESHSAT-1623): the kits' encrypted satellite chains over
// IMT, byte for byte as a MeshSat Bridge writes and reads them, behind the protocol version byte
// 0x01 that is added or taken off exactly once:
//
// - the H chain (HeMB-NG S3-2): AES-256-GCM (12-byte nonce, ciphertext, 16-byte tag) of a smaz2g
//   frame with the Meshtastic word table. No AAD and no base64; the smaz2g mode byte is inside the
//   encryption. For n UTF-8 bytes and SMAZ2 output z the wire is 30 + min(n, z) bytes.
// - the legacy chain, the kits' chain before it and the agreed rollback (r33 review R33-R2), as
//   parallax's iridium_imt_0 runs it: smaz2 with the default table (the step names no dict),
//   AES-256-GCM, then base64.
//
// It lives here, beside the TransformPipeline whose steps it runs and whose TransformError it
// throws, as Android's engine/ has it; the 9704 driver that carries the wire is in
// MeshSatMeshtastic, which this module does not depend on. [MESHSAT-1624]
import Foundation
import MeshSatWire

public enum SatelliteChain {
    public static let protocolVersion: UInt8 = 0x01

    /// The key the kits' chains name (encrypt key_ref), stored under exactly this channel:address.
    /// Never looked up by the address alone: another channel's key may be called "shared" too (r33
    /// review R33-R3).
    public static let keyRef = "iridium:shared"

    /// H chain: version byte, nonce, mode byte and tag, added to the shorter of n and z.
    public static let overhead = 30

    /// One IMT message, and so the longest wire the chain may make: Iridium9704Driver.imtMaxSize,
    /// which the 9704 driver enforces (a test holds the two equal).
    public static let maxWireBytes = 100_000

    /// The setting's values: as the text is with nothing declared, the same declared, the H chain,
    /// or the legacy chain. Both encrypted chains declare sealed.
    public static let modeUndeclared = ""
    public static let modePlain = "plain"
    public static let modeSealed = "sealed"
    public static let modeLegacy = "legacy"

    public enum Chain: Sendable, Equatable, CaseIterable {
        case h
        case legacy

        public func steps(keyHex: String) -> [TransformSpec] {
            switch self {
            case .h:
                [TransformSpec(type: "smaz2g", params: ["dict": "meshtastic"]), TransformSpec(type: "encrypt", params: ["key": keyHex])]
            case .legacy:
                [TransformSpec(type: "smaz2"), TransformSpec(type: "encrypt", params: ["key": keyHex]), TransformSpec(type: "base64")]
            }
        }

        public var other: Chain { self == .h ? .legacy : .h }
    }

    /// The chain a setting sends with, or nil when it sends the text as it is.
    public static func chainOf(_ mode: String?) -> Chain? {
        if mode == modeSealed { return .h }
        if mode == modeLegacy { return .legacy }
        return nil
    }

    /// The H chain's steps, as the Bridge's vectors name them.
    public static func steps(keyHex: String) -> [TransformSpec] { Chain.h.steps(keyHex: keyHex) }

    /// The wire for `payload` on `chain`. Throws `TransformError` when it cannot be sealed (no key,
    /// a key that is not 32 bytes of hex, too long): a message meant to be sealed is never sent as
    /// plaintext.
    public static func seal(
        _ payload: [UInt8], keyHex: String?, pipeline: TransformPipeline = TransformPipeline(), chain: Chain = .h
    ) throws -> [UInt8] {
        let key = try checkKey(keyHex)
        let wire = [protocolVersion] + (try pipeline.applyEgress(payload, chain.steps(keyHex: key)))
        if wire.count > maxWireBytes {
            throw TransformError("too long for one satellite message: \(wire.count) bytes sealed, \(maxWireBytes) at most")
        }
        return wire
    }

    /// The payload of `wire` on `chain`. Throws `TransformError` when it does not open: no version
    /// byte, no key or a wrong one, changed or cut bytes, a malformed frame.
    public static func open(
        _ wire: [UInt8], keyHex: String?, pipeline: TransformPipeline = TransformPipeline(), chain: Chain = .h
    ) throws -> [UInt8] {
        guard wire.first == protocolVersion else { throw TransformError("satellite chain: no protocol version byte") }
        let key = try checkKey(keyHex)
        return try pipeline.applyIngress(Array(wire.dropFirst()), chain.steps(keyHex: key))
    }

    /// Exactly 64 ASCII hex digits. Character.isHexDigit also takes the fullwidth forms, so the
    /// bytes are checked instead.
    private static func isHexKey(_ keyHex: String) -> Bool {
        keyHex.utf8.count == 64
            && keyHex.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func checkKey(_ keyHex: String?) throws -> String {
        guard let keyHex, isHexKey(keyHex) else { throw TransformError("satellite chain: no key for \(keyRef)") }
        return keyHex
    }

    /// The kits' key: the one `lookup` finds under `keyRef` exactly, never another channel's
    /// "shared". Nil when there is none or it is not a key, and the send fails rather than seal with
    /// a wrong one.
    public static func key(_ lookup: (String) async -> String?) async -> String? {
        guard let key = await lookup(keyRef), isHexKey(key) else { return nil }
        return key
    }

    /// What an IMT message from the satellite is, once it is not a Reticulum packet (Android's
    /// SatelliteChain.Mt; type names are three characters at least here).
    public enum MtMessage: Sendable, Equatable {
        /// A text: `sealed` when it came through a chain and opened, on `chain`.
        case text(String, sealed: Bool, chain: Chain? = nil)
        /// A MeshSat versioned payload that did not open: never shown as a guess.
        case unopened(reason: String)
    }

    /// Reads one IMT payload. One that starts with the version byte is MeshSat's: it is opened with
    /// `preferred`, the chain this phone is set to, and while the two ends switch chains with the
    /// other one, each authenticated by its AES-GCM tag, so nothing that did not come from the
    /// key's holder ever reads as text. One that opens with neither is `.unopened`. Anything else is
    /// a plain text as before (a typed text never starts with byte 0x01).
    public static func readMt(
        _ payload: [UInt8], keyHex: String?, pipeline: TransformPipeline = TransformPipeline(), preferred: Chain = .h
    ) -> MtMessage {
        guard payload.first == protocolVersion else { return .text(String(decoding: payload, as: UTF8.self), sealed: false) }
        let firstError: Error
        do {
            let text = try open(payload, keyHex: keyHex, pipeline: pipeline, chain: preferred)
            return .text(String(decoding: text, as: UTF8.self), sealed: true, chain: preferred)
        } catch {
            firstError = error
        }
        do {
            let text = try open(payload, keyHex: keyHex, pipeline: pipeline, chain: preferred.other)
            return .text(String(decoding: text, as: UTF8.self), sealed: true, chain: preferred.other)
        } catch {
            return .unopened(reason: (firstError as? TransformError)?.description ?? "does not open")
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

    /// What the Hub birth declares for the modem (egress_format): "sealed" for either encrypted
    /// chain, "plain", or nil for nothing.
    public static func egressFormat(_ mode: String?) -> String? {
        if mode == modeSealed || mode == modeLegacy { return "sealed" }
        if mode == modePlain { return "plain" }
        return nil
    }
}
