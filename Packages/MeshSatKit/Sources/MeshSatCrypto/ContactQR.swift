// Mirrors pair/ContactQR.kt (MESHSAT-566, MESHSAT-575): a person's card, handed over face to
// face by QR code. The card carries the ways to reach someone and the Ed25519 key of the phone
// that made it, signed by that same key. The signature proves the card was made by the holder
// of that key and has not been altered since; it cannot prove who that person is, which is
// what the fingerprint on screen is for: both sides read it aloud, and it matches or it does not.
//
// Wire format, one line, printable:
//
//     meshsat:contact:1:<base64url payload>.<base64url signature>
//
// The payload is a fixed order of fields joined by a unit separator (0x1F), never JSON: it has
// to hash to the same bytes on both sides for the signature to mean anything, and a field that
// happens to contain a separator would otherwise change the shape of the record. Separators
// are therefore rejected on the way in rather than escaped.
import Crypto
import Foundation

public enum ContactQR {
    public static let prefix = "meshsat:contact:1:"
    /// Field separator inside the signed payload.
    static let sep: Character = "\u{1F}"
    /// Keeps a card inside a QR code that a phone camera can read at arm's length.
    public static let maxName = 48

    /// How the card reached this phone, which is all the trust there is to record. `scanned`
    /// came off a screen through this phone's camera, so someone was standing there; `imported`
    /// arrived as text through any other route and could have been forwarded by anyone.
    public enum Trust: String, Sendable {
        case scanned = "SCANNED"
        case imported = "IMPORTED"
    }

    public struct Card: Sendable, Equatable {
        public let name: String
        /// Raw 32-byte Ed25519 public key of the phone that made the card.
        public let signingPubRaw: [UInt8]
        /// Meshtastic node id, e.g. !bf6ee7bc, or blank.
        public let meshNodeId: String
        /// The Hub bridge id, or blank.
        public let bridgeId: String
        /// Seconds since the epoch, so an old card is recognisable as old.
        public let issuedAtSec: Int64

        public init(name: String, signingPubRaw: [UInt8], meshNodeId: String = "", bridgeId: String = "", issuedAtSec: Int64 = 0) {
            self.name = name
            self.signingPubRaw = signingPubRaw
            self.meshNodeId = meshNodeId
            self.bridgeId = bridgeId
            self.issuedAtSec = issuedAtSec
        }

        /// Eight bytes of SHA-256 over the key, as four groups. Short enough to read out over a
        /// noisy channel, long enough that forging a collision is not worth anyone's afternoon.
        public var fingerprint: String { ContactQR.fingerprintOf(signingPubRaw) }
    }

    /// What came of reading a card. Every failure says which, so the screen can say why.
    public enum Result: Sendable, Equatable {
        case ok(Card)
        /// Not a MeshSat card at all, or a version this app does not know.
        case notACard
        /// A card, but malformed: wrong field count, bad base64, wrong key length.
        case malformed
        /// The signature does not match the key in the card: altered in transit, or forged.
        case badSignature
    }

    public struct EncodeError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    public static func fingerprintOf(_ signingPubRaw: [UInt8]) -> String {
        let hex = SHA256.hash(data: signingPubRaw).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    /// The bytes that are signed. Anything that is part of the card goes in here, in this order,
    /// or it is not covered by the signature and can be changed by whoever passes the card on.
    static func payloadOf(_ card: Card) -> [UInt8] {
        let s = [card.name, b64(card.signingPubRaw), card.meshNodeId, card.bridgeId, String(card.issuedAtSec)].joined(
            separator: String(sep))
        return Array(s.utf8)
    }

    /// The card as one line of text, signed by `identity`. The identity must be the one whose
    /// public key the card carries; signing someone else's card would produce something that
    /// fails `decode` on every phone that reads it.
    public static func encode(_ card: Card, identity: Identity) throws -> String {
        guard !card.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw EncodeError(description: "a card needs a name") }
        guard card.name.count <= maxName else { throw EncodeError(description: "name over \(maxName) characters") }
        guard !card.name.contains(sep), !card.meshNodeId.contains(sep), !card.bridgeId.contains(sep) else {
            throw EncodeError(description: "a field may not contain the separator")
        }
        let payload = payloadOf(card)
        return prefix + b64(payload) + "." + b64(identity.sign(payload))
    }

    /// Read a card and check its signature. Never throws: every way in is someone else's input.
    public static func decode(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return .notACard }
        let body = String(trimmed.dropFirst(prefix.count))
        guard let dot = body.firstIndex(of: "."), dot != body.startIndex, body.index(after: dot) != body.endIndex else { return .malformed }
        guard let payload = unB64(String(body[..<dot])), let signature = unB64(String(body[body.index(after: dot)...])) else {
            return .malformed
        }
        guard let payloadText = String(bytes: payload, encoding: .utf8) else { return .malformed }
        let fields = payloadText.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { return .malformed }
        guard let pub = unB64(fields[1]), pub.count == 32 else { return .malformed }
        guard let issuedAt = Int64(fields[4]) else { return .malformed }
        guard !fields[0].trimmingCharacters(in: .whitespaces).isEmpty else { return .malformed }
        guard Identity.verifyWithRaw(pub, data: payload, signature: signature) else { return .badSignature }
        return .ok(Card(name: fields[0], signingPubRaw: pub, meshNodeId: fields[2], bridgeId: fields[3], issuedAtSec: issuedAt))
    }

    /// base64url without padding, as java.util.Base64's URL encoder writes it.
    public static func b64(_ data: [UInt8]) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func unB64(_ text: String) -> [UInt8]? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s) else { return nil }
        return Array(d)
    }
}
