// Mirrors fec/GaloisField256.kt: the Reed-Solomon field, polynomial 0x11D with generator 0x02.
// Not the HeMB field (see HembGf256).

public enum GaloisField256 {
    public static let polynomial: UInt16 = 0x11D
    public static let generator: UInt8 = 0x02

    public static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 512)
        var x: UInt16 = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= polynomial }
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

    /// a to the power n, n >= 0.
    public static func pow(_ a: UInt8, _ n: Int) -> UInt8 {
        if n == 0 { return 1 }
        if a == 0 { return 0 }
        return exp[(Int(log[Int(a)]) * n) % 255]
    }
}
