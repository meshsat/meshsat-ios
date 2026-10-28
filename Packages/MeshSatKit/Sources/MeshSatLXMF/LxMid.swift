// Mirrors lxmf/LxMid.kt (the Bridge's internal/lxmf/mid.go): the HeMB-NG logical message id on
// LXMF (contract C2, S2-R7; the Hub's fixture lxmf_mid_field.json): FIELD_CUSTOM_TYPE (0xFB) =
// "meshsat.mid/1" and FIELD_CUSTOM_DATA (0xFC) = the 16-byte mid, so a receiver drops a repeat
// even after a restart. A message that already carries another custom type goes without it,
// and its receiver has no mid for it. [MESHSAT-1641]
import Foundation
import MeshSatRns
import MeshSatWire

public enum LxMid {
    public static let fieldCustomType: Int64 = 0xFB
    public static let fieldCustomData: Int64 = 0xFC
    public static let type = "meshsat.mid/1"
    public static let length = 16

    /// A new mid for a message this phone writes: a UUIDv7 (HubMsgIds.newV7), 16 raw bytes.
    public static func newMid(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [UInt8] {
        var b = Rns.randomBytes(length)
        let ms = UInt64(max(nowMs, 0))
        for i in 0..<6 { b[i] = UInt8((ms >> UInt64(8 * (5 - i))) & 0xFF) }
        b[6] = 0x70 | (b[6] & 0x0F)
        b[8] = 0x80 | (b[8] & 0x3F)
        return b
    }

    /// The fields of a message that carries `mid` and nothing else.
    public static func fields(_ mid: [UInt8]) -> [MpEntry] { withMid([], mid) }

    /// `fields` with the mid added; unchanged when they already name another custom type or
    /// carry custom data.
    public static func withMid(_ fields: [MpEntry], _ mid: [UInt8]) -> [MpEntry] {
        precondition(mid.count == length, "a mid is 16 bytes")
        let v = MpValue.map(fields)
        if v[fieldCustomType] != nil || v[fieldCustomData] != nil { return fields }
        return fields + [MpEntry(.int(fieldCustomType), .str(type)), MpEntry(.int(fieldCustomData), .bin(mid))]
    }

    /// A mid as UUID text, lower case, as the Bridge stores it (lxmf.FormatMid).
    public static func format(_ mid: [UInt8]) -> String {
        let h = Hex.encode(mid)
        guard h.count == 32 else { return h }
        let c = Array(h)
        let groups = [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]]
        return groups.map { String($0) }.joined(separator: "-")
    }

    /// A mid from its UUID text (an intent id), either case (lxmf.ParseMid); nil for anything else.
    public static func parse(_ s: String) -> [UInt8]? {
        let c = Array(s.utf8)
        guard c.count == 36, c[8] == 0x2D, c[13] == 0x2D, c[18] == 0x2D, c[23] == 0x2D else { return nil }
        let bytes = Hex.decode(s.replacingOccurrences(of: "-", with: ""))
        return bytes?.count == length ? bytes : nil
    }

    /// The mid a received message carries, or nil when it carries none (or another custom type).
    public static func midOf(_ fields: [MpEntry]) -> [UInt8]? {
        let v = MpValue.map(fields)
        guard case .str(let t)? = v[fieldCustomType], t == type else { return nil }
        guard case .bin(let data)? = v[fieldCustomData], data.count == length else { return nil }
        return data
    }
}
