// Byte helpers shared by every wire module. Android uses android.util.Base64 with
// DEFAULT (tolerant of line breaks), NO_WRAP and URL_SAFE|NO_PADDING; the three
// variants map to the functions below.
import Foundation

public enum Hex {
    /// Lower-case hex, no separators, like Kotlin's joinToString("") { "%02x".format(it) }.
    public static func encode(_ bytes: [UInt8]) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: bytes.count * 2)
        for (i, b) in bytes.enumerated() {
            out[i * 2] = digits[Int(b >> 4)]
            out[i * 2 + 1] = digits[Int(b & 0x0F)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Accepts upper or lower case; nil for an odd length or a non-hex character.
    public static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}

public enum Base64Std {
    /// android.util.Base64.NO_WRAP: standard alphabet, padding, no line breaks.
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    /// android.util.Base64.DEFAULT is tolerant of whitespace and line breaks, so decoding
    /// ignores unknown characters the same way.
    public static func decode(_ text: String) -> [UInt8]? {
        Data(base64Encoded: text, options: .ignoreUnknownCharacters).map { [UInt8]($0) }
    }
}

public enum Base64Url {
    /// android.util.Base64.URL_SAFE | NO_PADDING | NO_WRAP.
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts both alphabets and missing padding.
    public static func decode(_ text: String) -> [UInt8]? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem != 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters).map { [UInt8]($0) }
    }
}

public extension Array where Element == UInt8 {
    /// Big-endian UInt16 at an offset, or nil when out of range.
    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    /// Little-endian UInt16 at an offset, or nil when out of range.
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    /// Big-endian UInt32 at an offset, or nil when out of range.
    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}

public extension UInt16 {
    var bytesBE: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
    var bytesLE: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8)] }
}

public extension UInt32 {
    var bytesBE: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}
