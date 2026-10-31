// Mirrors rlnc/ (GF256Vector.kt, RlncCodedPacket.kt, RlncEncoder.kt, RlncDecoder.kt): the
// standalone RLNC over the Reed-Solomon field (0x11D), with its own packet format:
//   [0:2] generation id (uint16 BE)  [2] K  [3:3+K] coefficients  [3+K:] coded data
import Foundation

public enum GF256Vector {
    public static func dot(_ a: [UInt8], _ b: [UInt8]) -> UInt8 {
        precondition(a.count == b.count, "vectors must have the same length")
        var result: UInt8 = 0
        for i in a.indices { result = GaloisField256.add(result, GaloisField256.mul(a[i], b[i])) }
        return result
    }

    public static func scalarMul(_ c: UInt8, _ v: [UInt8]) -> [UInt8] { v.map { GaloisField256.mul(c, $0) } }

    public static func add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        precondition(a.count == b.count, "vectors must have the same length")
        return zip(a, b).map { $0 ^ $1 }
    }

    /// K random non-zero coefficients.
    public static func randomCoefficients(_ k: Int) -> [UInt8] { (0..<k).map { _ in UInt8.random(in: 1...255) } }
}

public struct RlncCodedPacket: Sendable, Equatable {
    public static let headerSize = 3
    public var generationId: Int
    public var segmentCount: Int
    public var coefficients: [UInt8]
    public var codedData: [UInt8]

    public init(generationId: Int, segmentCount: Int, coefficients: [UInt8], codedData: [UInt8]) {
        self.generationId = generationId
        self.segmentCount = segmentCount
        self.coefficients = coefficients
        self.codedData = codedData
    }

    public static func unmarshal(_ data: [UInt8]) -> RlncCodedPacket? {
        guard data.count >= headerSize else { return nil }
        let genId = (Int(data[0]) << 8) | Int(data[1])
        let k = Int(data[2])
        guard data.count >= headerSize + k else { return nil }
        return RlncCodedPacket(
            generationId: genId, segmentCount: k, coefficients: Array(data[headerSize..<(headerSize + k)]),
            codedData: Array(data[(headerSize + k)...]))
    }

    public func marshal() -> [UInt8] {
        [UInt8((generationId >> 8) & 0xFF), UInt8(generationId & 0xFF), UInt8(segmentCount & 0xFF)] + coefficients + codedData
    }
}

public enum RlncEncoder {
    public enum EncodeError: Error, Equatable { case noSegments, tooManySegments, unequalSegments }

    /// K segments of equal length into N coded packets (N defaults to K + 1).
    public static func encode(_ segments: [[UInt8]], generationId: Int, codedCount: Int? = nil) throws -> [RlncCodedPacket] {
        guard !segments.isEmpty else { throw EncodeError.noSegments }
        guard segments.count <= 255 else { throw EncodeError.tooManySegments }
        let k = segments.count
        let segSize = segments[0].count
        guard segments.allSatisfy({ $0.count == segSize }) else { throw EncodeError.unequalSegments }
        return (0..<(codedCount ?? k + 1)).map { _ in
            let coeffs = GF256Vector.randomCoefficients(k)
            var coded = [UInt8](repeating: 0, count: segSize)
            for j in 0..<k {
                let c = coeffs[j]
                for b in 0..<segSize { coded[b] = GaloisField256.add(coded[b], GaloisField256.mul(c, segments[j][b])) }
            }
            return RlncCodedPacket(generationId: generationId, segmentCount: k, coefficients: coeffs, codedData: coded)
        }
    }

    /// K equal segments, the last zero-padded.
    public static func segmentPayload(_ data: [UInt8], k: Int) -> [[UInt8]] {
        let segSize = (data.count + k - 1) / k
        return (0..<k).map { i in
            let offset = i * segSize
            let len = max(0, min(segSize, data.count - offset))
            return (len > 0 ? Array(data[offset..<(offset + len)]) : []) + [UInt8](repeating: 0, count: segSize - len)
        }
    }
}

/// Progressive Gaussian elimination over the 0x11D field; packets from any path count as long
/// as they share the generation id.
public final class RlncDecoder: @unchecked Sendable {
    public let segmentCount: Int
    public let segmentSize: Int
    private let lock = NSLock()
    private var matrix: [[UInt8]]
    private var pivotCols: [Int]
    private var rankValue = 0

    public init(segmentCount: Int, segmentSize: Int) {
        self.segmentCount = segmentCount
        self.segmentSize = segmentSize
        matrix = Array(repeating: [UInt8](repeating: 0, count: segmentCount + segmentSize), count: segmentCount)
        pivotCols = [Int](repeating: -1, count: segmentCount)
    }

    public var rank: Int {
        lock.lock()
        defer { lock.unlock() }
        return rankValue
    }

    public var isSolvable: Bool { rank >= segmentCount }

    public enum FeedError: Error, Equatable { case segmentCountMismatch, segmentSizeMismatch }

    /// True when the packet raised the rank.
    @discardableResult
    public func feed(_ packet: RlncCodedPacket) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if rankValue >= segmentCount { return false }
        guard packet.segmentCount == segmentCount else { throw FeedError.segmentCountMismatch }
        guard packet.codedData.count == segmentSize else { throw FeedError.segmentSizeMismatch }
        var row = packet.coefficients + packet.codedData
        for r in 0..<rankValue {
            let pc = pivotCols[r]
            guard pc >= 0 else { continue }
            let factor = row[pc]
            if factor == 0 { continue }
            let pivot = matrix[r]
            for j in row.indices { row[j] = GaloisField256.add(row[j], GaloisField256.mul(factor, pivot[j])) }
        }
        guard let pivotCol = (0..<segmentCount).first(where: { row[$0] != 0 }) else { return false }
        let pivotInv = GaloisField256.inv(row[pivotCol])
        for j in row.indices { row[j] = GaloisField256.mul(row[j], pivotInv) }
        matrix[rankValue] = row
        pivotCols[rankValue] = pivotCol
        rankValue += 1
        return true
    }

    public func solve() -> [[UInt8]]? {
        lock.lock()
        defer { lock.unlock() }
        guard rankValue >= segmentCount else { return nil }
        for r in stride(from: rankValue - 1, through: 0, by: -1) {
            let pc = pivotCols[r]
            let pivot = matrix[r]
            for above in 0..<r {
                let factor = matrix[above][pc]
                if factor == 0 { continue }
                for j in matrix[above].indices {
                    matrix[above][j] = GaloisField256.add(matrix[above][j], GaloisField256.mul(factor, pivot[j]))
                }
            }
        }
        var segments = Array(repeating: [UInt8](repeating: 0, count: segmentSize), count: segmentCount)
        for r in 0..<rankValue { segments[pivotCols[r]] = Array(matrix[r][segmentCount...]) }
        return segments
    }
}
