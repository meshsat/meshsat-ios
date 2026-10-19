// Mirrors hubmsg/HubMsgIds.kt: the identities of the Hub app route hub_msg (HeMB-NG stage 2,
// contract C1e, MESHSAT-1584) and the content digest (C1d). A UUIDv7 for every operation, message
// and event; a UUIDv5 under the pinned namespace only for the two documented exceptions. The same
// rules as the Bridge's and the Hub's internal/hubmsg; the shared vectors are fixtures-v1.1.
import Crypto
import Foundation

public enum HubMsgIds {
    /// UUIDv5(NAMESPACE_URL, "https://meshsat.net/ns/hemb-ng/v1").
    public static let namespace = "a389cf74-e475-53d9-b656-d994a485fe0a"

    /// What the two UUIDv5 exceptions are checked against. runStartMs < 0 means absent.
    public struct Context: Sendable {
        public var sender = ""
        public var name = ""
        public var bridgeId = ""
        public var runStartMs: Int64 = -1

        public init(sender: String = "", name: String = "", bridgeId: String = "", runStartMs: Int64 = -1) {
            self.sender = sender
            self.name = name
            self.bridgeId = bridgeId
            self.runStartMs = runStartMs
        }
    }

    /// The 16 bytes of a UUID in its canonical text (lower case, 8-4-4-4-12), or nil.
    public static func parseCanonical(_ s: String) -> [UInt8]? {
        let c = Array(s.utf8)
        guard c.count == 36, c[8] == 0x2D, c[13] == 0x2D, c[18] == 0x2D, c[23] == 0x2D else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        var hi: UInt8?
        for (i, ch) in c.enumerated() where i != 8 && i != 13 && i != 18 && i != 23 {
            let v: UInt8
            switch ch {
            case 0x30...0x39: v = ch - 0x30
            case 0x61...0x66: v = ch - 0x61 + 10
            default: return nil
            }
            if let h = hi {
                out.append(h << 4 | v)
                hi = nil
            } else {
                hi = v
            }
        }
        return out
    }

    public static func format(_ b: [UInt8]) -> String {
        let h = b.map { String(format: "%02x", $0) }.joined()
        let a = Array(h)
        return String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-"
            + String(a[20..<32])
    }

    private static func rfcVariant(_ b: [UInt8]) -> Bool { b[8] >> 6 == 0b10 }
    private static func version(_ b: [UInt8]) -> UInt8 { b[6] >> 4 }

    /// Whether s is a UUIDv7 in canonical text with the RFC variant.
    public static func validV7(_ s: String) -> Bool {
        guard let b = parseCanonical(s) else { return false }
        return rfcVariant(b) && version(b) == 7
    }

    /// C1e: v7 everywhere; v5 only for a Hub-derived mid (C1c) or an old-format SOS id (C10).
    public static func idValid(_ s: String, field: String, context c: Context = Context()) -> Bool {
        guard let b = parseCanonical(s), rfcVariant(b) else { return false }
        switch version(b) {
        case 7: return true
        case 5:
            if field == "mid" && c.sender == "hub" && !c.name.isEmpty { return uuidV5(c.name) == s }
            if field == "sos_id" && !c.bridgeId.isEmpty && c.runStartMs >= 0 { return uuidV5("\(c.bridgeId):\(c.runStartMs)") == s }
            return false
        default: return false
        }
    }

    /// The UUIDv5 of name under the namespace (RFC 9562 5.5: SHA-1, not a security use).
    public static func uuidV5(_ name: String) -> String {
        var h = Insecure.SHA1()
        h.update(data: parseCanonical(namespace) ?? [])
        h.update(data: Array(name.utf8))
        var b = Array(h.finalize().prefix(16))
        b[6] = 0x50 | (b[6] & 0x0F)
        b[8] = 0x80 | (b[8] & 0x3F)
        return format(b)
    }

    /// A UUIDv7 for nowMs (RFC 9562 5.7): the time in its first 48 bits, the rest random.
    public static func newV7(_ nowMs: Int64) -> String {
        var g = SystemRandomNumberGenerator()
        var b = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
        let ms = UInt64(max(nowMs, 0))
        for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: ms >> (8 * UInt64(5 - i))) }
        b[6] = 0x70 | (b[6] & 0x0F)
        b[8] = 0x80 | (b[8] & 0x3F)
        return format(b)
    }
}

/// The content digest (C1d): SHA-256 over each field as a 4-byte big-endian length and its bytes,
/// in this order: the tag, the mid's 16 raw bytes, the recipient principal, the content type,
/// mid_expires_at (unix ms, 8 bytes big-endian), the body. Every hop recomputes it from the
/// delivered fields; a carried value is only compared, never trusted.
public enum HubMsgDigest {
    public static let tag = "meshsat.content/1"

    /// The preimage, or nil for fields it cannot be computed over (a bad mid, a negative deadline).
    public static func preimage(mid: String, recipient: String, contentType: String, midExpiresAt: Int64, body: [UInt8]) -> [UInt8]? {
        guard let m = HubMsgIds.parseCanonical(mid), midExpiresAt >= 0 else { return nil }
        let exp = (0..<8).map { UInt8(truncatingIfNeeded: UInt64(midExpiresAt) >> (8 * UInt64(7 - $0))) }
        var out: [UInt8] = []
        for f in [Array(tag.utf8), m, Array(recipient.utf8), Array(contentType.utf8), exp, body] {
            let n = UInt32(f.count)
            out += [UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            out += f
        }
        return out
    }

    /// The digest in lower-case hex, or nil where the preimage is.
    public static func sha256Hex(mid: String, recipient: String, contentType: String, midExpiresAt: Int64, body: [UInt8]) -> String? {
        guard let p = preimage(mid: mid, recipient: recipient, contentType: contentType, midExpiresAt: midExpiresAt, body: body) else {
            return nil
        }
        return SHA256.hash(data: p).map { String(format: "%02x", $0) }.joined()
    }
}
