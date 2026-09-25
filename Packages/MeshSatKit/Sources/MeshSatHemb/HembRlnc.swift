// Mirrors hemb/HembRlnc.kt and the matrix half of hemb/HembGf256.kt: random linear network
// coding over GF(256) with polynomial 0x11B, wire-compatible with the Bridge's rlnc.go, and
// the Gaussian elimination it decodes with.
import Foundation

public enum HembRlncError: Error, Equatable {
    case badK(Int)
    case nLessThanK(n: Int, k: Int)
    case unequalSegments
}

public enum HembRlncEncoder {
    /// K source segments of equal length into N coded symbols with random coefficients.
    public static func encode(genId: Int, segments: [[UInt8]], n: Int) throws -> [HembCodedSymbol] {
        let k = segments.count
        guard (1...255).contains(k) else { throw HembRlncError.badK(k) }
        guard n >= k else { throw HembRlncError.nLessThanK(n: n, k: k) }
        let symSize = segments[0].count
        guard segments.allSatisfy({ $0.count == symSize }) else { throw HembRlncError.unequalSegments }
        return (0..<n).map { idx in
            var coeffs = [UInt8](repeating: 0, count: k)
            repeat {
                for i in 0..<k { coeffs[i] = UInt8.random(in: 0...255) }
            } while coeffs.allSatisfy({ $0 == 0 })
            var coded = [UInt8](repeating: 0, count: symSize)
            for j in 0..<k where coeffs[j] != 0 {
                let c = coeffs[j]
                let seg = segments[j]
                for b in 0..<symSize { coded[b] = HembGf256.add(coded[b], HembGf256.mul(c, seg[b])) }
            }
            return HembCodedSymbol(genId: genId, symbolIndex: idx, k: k, coefficients: coeffs, data: coded)
        }
    }

    /// K chunks of symSize bytes, the last zero-padded.
    public static func segmentPayload(_ payload: [UInt8], symSize: Int) -> [[UInt8]] {
        let k = (payload.count + symSize - 1) / symSize
        return (0..<k).map { i in
            let start = i * symSize
            let end = min(start + symSize, payload.count)
            return Array(payload[start..<end]) + [UInt8](repeating: 0, count: symSize - (end - start))
        }
    }
}

/// Progressive Gaussian elimination: feed symbols; at rank K, solve.
public final class HembRlncDecoder: @unchecked Sendable {
    public let k: Int
    public let symSize: Int
    private let lock = NSLock()
    private var matrix: [[UInt8]]
    private var pivotCols: [Int]
    private var rankValue = 0

    public init(k: Int, symSize: Int) {
        self.k = k
        self.symSize = symSize
        matrix = Array(repeating: [UInt8](repeating: 0, count: k + symSize), count: k)
        pivotCols = [Int](repeating: -1, count: k)
    }

    public var rank: Int {
        lock.lock()
        defer { lock.unlock() }
        return rankValue
    }

    public var isSolvable: Bool { rank >= k }

    /// True when the symbol was linearly independent and raised the rank.
    @discardableResult
    public func feed(_ sym: HembCodedSymbol) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard rankValue < k, sym.k == k, sym.data.count == symSize, sym.coefficients.count >= k else { return false }
        var row = Array(sym.coefficients.prefix(k)) + sym.data
        for r in 0..<rankValue {
            let pc = pivotCols[r]
            guard pc >= 0 else { continue }
            let factor = row[pc]
            if factor == 0 { continue }
            let pivot = matrix[r]
            for j in row.indices { row[j] = HembGf256.add(row[j], HembGf256.mul(factor, pivot[j])) }
        }
        guard let pivotCol = (0..<k).first(where: { row[$0] != 0 }) else { return false }
        let pivotInv = HembGf256.inv(row[pivotCol])
        for j in row.indices { row[j] = HembGf256.mul(row[j], pivotInv) }
        matrix[rankValue] = row
        pivotCols[rankValue] = pivotCol
        rankValue += 1
        return true
    }

    /// The K source segments, or nil below rank K.
    public func solve() -> [[UInt8]]? {
        lock.lock()
        defer { lock.unlock() }
        guard rankValue >= k else { return nil }
        for r in stride(from: rankValue - 1, through: 0, by: -1) {
            let pc = pivotCols[r]
            let pivot = matrix[r]
            for above in 0..<r {
                let factor = matrix[above][pc]
                if factor == 0 { continue }
                for j in matrix[above].indices { matrix[above][j] = HembGf256.add(matrix[above][j], HembGf256.mul(factor, pivot[j])) }
            }
        }
        var segments = Array(repeating: [UInt8](repeating: 0, count: symSize), count: k)
        for r in 0..<rankValue { segments[pivotCols[r]] = Array(matrix[r][k...]) }
        return segments
    }
}

/// N symbols into K segments in one go (the Bridge's TryDecode).
public func hembTryDecode(_ symbols: [HembCodedSymbol], k: Int) -> [[UInt8]]? {
    guard !symbols.isEmpty, symbols.count >= k else { return nil }
    var coeffs = HembGfMatrix(rows: symbols.count, cols: k)
    for i in symbols.indices {
        for j in 0..<k { coeffs[i, j] = symbols[i].coefficients[j] }
    }
    return hembGaussianEliminate(coeffs, payloads: symbols.map(\.data))
}

/// A row-major matrix over GF(256).
public struct HembGfMatrix: Sendable, Equatable {
    public let rows: Int
    public let cols: Int
    public var data: [UInt8]
    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        data = [UInt8](repeating: 0, count: rows * cols)
    }
    public subscript(row: Int, col: Int) -> UInt8 {
        get { data[row * cols + col] }
        set { data[row * cols + col] = newValue }
    }
}

/// Solves coeffs x X = payloads (N x K, N >= K) with partial pivoting: the K payloads, or nil
/// below rank K.
public func hembGaussianEliminate(_ coeffs: HembGfMatrix, payloads: [[UInt8]]) -> [[UInt8]]? {
    let n = coeffs.rows
    let k = coeffs.cols
    guard n >= k, payloads.count == n else { return nil }
    if k == 0 { return [] }
    let payloadLen = payloads[0].count
    guard payloads.allSatisfy({ $0.count == payloadLen }) else { return nil }
    var mat = coeffs
    var pld = payloads
    for col in 0..<k {
        guard let pivotRow = (col..<n).first(where: { mat[$0, col] != 0 }) else { return nil }
        if pivotRow != col {
            for c in 0..<k {
                let tmp = mat[col, c]
                mat[col, c] = mat[pivotRow, c]
                mat[pivotRow, c] = tmp
            }
            pld.swapAt(col, pivotRow)
        }
        let inv = HembGf256.inv(mat[col, col])
        for c in 0..<k { mat[col, c] = HembGf256.mul(mat[col, c], inv) }
        for j in 0..<payloadLen { pld[col][j] = HembGf256.mul(pld[col][j], inv) }
        for row in 0..<n where row != col {
            let factor = mat[row, col]
            if factor == 0 { continue }
            for c in 0..<k { mat[row, c] = HembGf256.add(mat[row, c], HembGf256.mul(factor, mat[col, c])) }
            for j in 0..<payloadLen { pld[row][j] = HembGf256.add(pld[row][j], HembGf256.mul(factor, pld[col][j])) }
        }
    }
    return Array(pld[0..<k])
}

/// The rank of an N x K coefficient matrix.
public func hembComputeRank(_ rows: [[UInt8]], k: Int) -> Int {
    let n = rows.count
    if n == 0 || k == 0 { return 0 }
    var mat = HembGfMatrix(rows: n, cols: k)
    for i in 0..<n {
        for j in 0..<min(k, rows[i].count) { mat[i, j] = rows[i][j] }
    }
    var rank = 0
    for col in 0..<k {
        guard let pivotRow = (rank..<n).first(where: { mat[$0, col] != 0 }) else { continue }
        if pivotRow != rank {
            for c in 0..<k {
                let tmp = mat[rank, c]
                mat[rank, c] = mat[pivotRow, c]
                mat[pivotRow, c] = tmp
            }
        }
        let inv = HembGf256.inv(mat[rank, col])
        for c in 0..<k { mat[rank, c] = HembGf256.mul(mat[rank, c], inv) }
        for row in (rank + 1)..<max(rank + 1, n) {
            let factor = mat[row, col]
            if factor == 0 { continue }
            for c in 0..<k { mat[row, c] = HembGf256.add(mat[row, c], HembGf256.mul(factor, mat[rank, c])) }
        }
        rank += 1
    }
    return rank
}
