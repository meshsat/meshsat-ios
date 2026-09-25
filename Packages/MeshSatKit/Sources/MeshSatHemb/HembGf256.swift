// Mirrors hemb/HembGf256.kt: GF(256) with the reducing polynomial 0x11B and generator 0x03,
// wire-compatible with the Bridge's internal/hemb/gf256.go. This is deliberately a different
// field from GaloisField256 (fec/, polynomial 0x11D, generator 0x02): mixing the two tables
// breaks decoding between the Bridge and the phone.

public enum HembGf256 {
    public static let polynomial: UInt16 = 0x11B
    public static let generator: UInt8 = 0x03

    /// exp table with 512 entries so that mul never needs a modulo.
    public static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 512)
        var x: UInt16 = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            // multiply by the generator 0x03: x * 3 = (x << 1) ^ x, reduced by 0x11B
            var doubled = x << 1
            if doubled & 0x100 != 0 { doubled ^= polynomial }
            x = doubled ^ x
        }
        for i in 255..<512 { table[i] = table[i - 255] }
        return table
    }()

    public static let log: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<255 { table[Int(exp[i])] = UInt8(i) }
        return table
    }()

    @inline(__always)
    public static func add(_ a: UInt8, _ b: UInt8) -> UInt8 { a ^ b }

    @inline(__always)
    public static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    /// Multiplicative inverse. Kotlin throws on zero; here it is 0, and every caller checks for
    /// a zero pivot first, so the two never diverge on a real matrix.
    @inline(__always)
    public static func inv(_ a: UInt8) -> UInt8 {
        if a == 0 { return 0 }
        return exp[255 - Int(log[Int(a)])]
    }

    @inline(__always)
    public static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        precondition(b != 0, "division by zero in GF(256)")
        if a == 0 { return 0 }
        return exp[Int(log[Int(a)]) + 255 - Int(log[Int(b)])]
    }
}
