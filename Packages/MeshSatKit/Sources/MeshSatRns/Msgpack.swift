// Mirrors rns/Msgpack.kt (the Bridge's internal/msgpack): a msgpack codec byte-identical to
// RNS.vendor.umsgpack for the value shapes Reticulum and LXMF use. LXMF hashes the RE-ENCODING
// of a decoded payload, so the encoder must write exactly what umsgpack writes: positive fixint /
// uint8..64 for non-negative integers, negative fixint / int8..64 for negative ones, float64 for
// every float, str for text, bin for bytes, maps in insertion order.
import Foundation

/// One map entry; a map is its entries in insertion order.
public struct MpEntry: Sendable, Equatable {
    public let key: MpValue
    public let value: MpValue
    public init(_ key: MpValue, _ value: MpValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum MpValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A signed integer, or a non-negative one that fits Int64.
    case int(Int64)
    /// A value decoded from a uint64 above Int64.max; it re-encodes as that (Kotlin's uint64 flag).
    case uint64(UInt64)
    case float(Double)
    case str(String)
    case bin([UInt8])
    case array([MpValue])
    case map([MpEntry])
    /// An ext value, kept as its raw bytes and re-emitted verbatim.
    case ext([UInt8])

    /// The integer of either sign kind; nil for a uint64 above Int64.max or a non-integer.
    public var asInt: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// The bytes of a bin, or the UTF-8 of a str (LXMF titles and contents arrive as either).
    public var asBytes: [UInt8]? {
        switch self {
        case .bin(let b): return b
        case .str(let s): return Array(s.utf8)
        default: return nil
        }
    }

    /// The entries of a map; nil for anything else.
    public var asMap: [MpEntry]? {
        if case .map(let entries) = self { return entries }
        return nil
    }

    /// The elements of an array; nil for anything else.
    public var asArray: [MpValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// A map entry by integer key (LXMF fields are keyed by field number).
    public subscript(key: Int64) -> MpValue? {
        asMap?.first { $0.key.asInt == key }?.value
    }

    /// A map entry by string key.
    public subscript(key: String) -> MpValue? {
        asMap?.first { if case .str(let s) = $0.key { return s == key } else { return false } }?.value
    }

    /// A map from integer keys, convenient for callers (LxMessage.fieldsOf).
    public static func fields(_ entries: [(Int64, MpValue)]) -> [MpEntry] {
        entries.map { MpEntry(.int($0.0), $0.1) }
    }
}

public struct MsgpackError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Msgpack {
    public static func pack(_ v: MpValue) -> [UInt8] {
        var out = [UInt8]()
        write(&out, v)
        return out
    }

    /// Decodes one value; returns it with the number of bytes consumed from `offset`.
    public static func unpack(_ b: [UInt8], offset: Int = 0) throws -> (value: MpValue, consumed: Int) {
        var d = Decoder(b: b, pos: offset)
        let v = try d.value()
        return (v, d.pos - offset)
    }

    // MARK: encoder

    private static func u16(_ out: inout [UInt8], _ v: Int) { out += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    private static func u32(_ out: inout [UInt8], _ v: UInt64) {
        for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8((v >> UInt64(s)) & 0xFF)) }
    }

    private static func u64(_ out: inout [UInt8], _ v: UInt64) {
        for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(s)) & 0xFF)) }
    }

    private static func write(_ out: inout [UInt8], _ v: MpValue) {
        switch v {
        case .null: out.append(0xC0)
        case .bool(let b): out.append(b ? 0xC3 : 0xC2)
        case .int(let i): writeInt(&out, i)
        case .uint64(let u):
            out.append(0xCF)
            u64(&out, u)
        case .float(let f):
            out.append(0xCB)
            u64(&out, f.bitPattern)
        case .str(let s): writeStr(&out, Array(s.utf8))
        case .bin(let b): writeBin(&out, b)
        case .array(let items):
            writeLength(&out, items.count, fix: 0x90, b16: 0xDC, b32: 0xDD)
            for e in items { write(&out, e) }
        case .map(let entries):
            writeLength(&out, entries.count, fix: 0x80, b16: 0xDE, b32: 0xDF)
            for e in entries {
                write(&out, e.key)
                write(&out, e.value)
            }
        case .ext(let raw): out += raw
        }
    }

    private static func writeInt(_ out: inout [UInt8], _ i: Int64) {
        if i >= 0 {
            let u = UInt64(i)
            switch u {
            case ..<128: out.append(UInt8(u))
            case ..<(1 << 8): out += [0xCC, UInt8(u)]
            case ..<(1 << 16):
                out.append(0xCD)
                u16(&out, Int(u))
            case ..<(1 << 32):
                out.append(0xCE)
                u32(&out, u)
            default:
                out.append(0xCF)
                u64(&out, u)
            }
            return
        }
        switch i {
        case (-32)...: out.append(UInt8(truncatingIfNeeded: i))
        case Int64(Int8.min)...: out += [0xD0, UInt8(truncatingIfNeeded: i)]
        case Int64(Int16.min)...:
            out.append(0xD1)
            u16(&out, Int(UInt16(truncatingIfNeeded: i)))
        case Int64(Int32.min)...:
            out.append(0xD2)
            u32(&out, UInt64(UInt32(truncatingIfNeeded: i)))
        default:
            out.append(0xD3)
            u64(&out, UInt64(bitPattern: i))
        }
    }

    private static func writeStr(_ out: inout [UInt8], _ b: [UInt8]) {
        switch b.count {
        case ..<32: out.append(0xA0 | UInt8(b.count))
        case ..<(1 << 8): out += [0xD9, UInt8(b.count)]
        case ..<(1 << 16):
            out.append(0xDA)
            u16(&out, b.count)
        default:
            out.append(0xDB)
            u32(&out, UInt64(b.count))
        }
        out += b
    }

    private static func writeBin(_ out: inout [UInt8], _ b: [UInt8]) {
        switch b.count {
        case ..<(1 << 8): out += [0xC4, UInt8(b.count)]
        case ..<(1 << 16):
            out.append(0xC5)
            u16(&out, b.count)
        default:
            out.append(0xC6)
            u32(&out, UInt64(b.count))
        }
        out += b
    }

    private static func writeLength(_ out: inout [UInt8], _ n: Int, fix: UInt8, b16: UInt8, b32: UInt8) {
        switch n {
        case ..<16: out.append(fix | UInt8(n))
        case ..<(1 << 16):
            out.append(b16)
            u16(&out, n)
        default:
            out.append(b32)
            u32(&out, UInt64(n))
        }
    }

    // MARK: decoder

    private struct Decoder {
        let b: [UInt8]
        var pos: Int

        mutating func need(_ n: Int) throws -> Int {
            guard n >= 0, pos + n <= b.count else { throw MsgpackError("truncated msgpack") }
            let start = pos
            pos += n
            return start
        }

        mutating func u8() throws -> Int { Int(b[try need(1)]) }

        mutating func uint(_ n: Int) throws -> UInt64 {
            let s = try need(n)
            var u: UInt64 = 0
            for i in 0..<n { u = (u << 8) | UInt64(b[s + i]) }
            return u
        }

        mutating func length(_ sizeExp: Int) throws -> Int {
            let u = try uint(1 << sizeExp)
            guard u <= (1 << 31) else { throw MsgpackError("length too large") }
            return Int(u)
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            let s = try need(n)
            return Array(b[s..<s + n])
        }

        mutating func value() throws -> MpValue {
            let h = try u8()
            switch h {
            case 0x00...0x7F: return .int(Int64(h))
            case 0xE0...0xFF: return .int(Int64(Int8(truncatingIfNeeded: h)))
            case 0xA0...0xBF: return .str(String(decoding: try bytes(h & 0x1F), as: UTF8.self))
            case 0x90...0x9F: return try array(h & 0x0F)
            case 0x80...0x8F: return try map(h & 0x0F)
            case 0xC0: return .null
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4...0xC6: return .bin(try bytes(try length(h - 0xC4)))
            case 0xD9...0xDB: return .str(String(decoding: try bytes(try length(h - 0xD9)), as: UTF8.self))
            case 0xDC, 0xDD: return try array(try length(h - 0xDC + 1))
            case 0xDE, 0xDF: return try map(try length(h - 0xDE + 1))
            default: return try numberOrExt(h)
            }
        }

        mutating func numberOrExt(_ h: Int) throws -> MpValue {
            switch h {
            case 0xCA: return .float(Double(Float(bitPattern: UInt32(try uint(4)))))
            case 0xCB: return .float(Double(bitPattern: try uint(8)))
            case 0xCC...0xCE: return .int(Int64(try uint(1 << (h - 0xCC))))
            case 0xCF:
                let u = try uint(8)
                return u > UInt64(Int64.max) ? .uint64(u) : .int(Int64(u))
            case 0xD0...0xD3:
                let n = 1 << (h - 0xD0)
                let u = try uint(n)
                let shift = UInt64(64 - 8 * n)
                return .int(Int64(bitPattern: u << shift) >> Int64(shift))
            case 0xD4...0xD8:
                let start = pos - 1
                _ = try need(1 + (1 << (h - 0xD4)))
                return .ext(Array(b[start..<pos]))
            case 0xC7...0xC9:
                let start = pos - 1
                let n = try length(h - 0xC7)
                _ = try need(1 + n)
                return .ext(Array(b[start..<pos]))
            default: throw MsgpackError(String(format: "unsupported type byte 0x%02x", UInt32(truncatingIfNeeded: h)))
            }
        }

        mutating func array(_ n: Int) throws -> MpValue {
            var items = [MpValue]()
            items.reserveCapacity(min(n, 1024))
            for _ in 0..<n { items.append(try value()) }
            return .array(items)
        }

        mutating func map(_ n: Int) throws -> MpValue {
            var entries = [MpEntry]()
            entries.reserveCapacity(min(n, 1024))
            for _ in 0..<n {
                let k = try value()
                let v = try value()
                entries.append(MpEntry(k, v))
            }
            return .map(entries)
        }
    }
}
