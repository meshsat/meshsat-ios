// Mirrors fec/FecHeader.kt, fec/ReedSolomon.kt and fec/FecTransform.kt: systematic
// Reed-Solomon over the 0x11D field with a Vandermonde matrix; a 4-byte header on every
// shard ([codec 0x01] [K] [M] [index]); any K of K+M shards give the data back.
import Foundation

public struct FecHeader: Sendable, Equatable {
    public static let codecReedSolomon = 0x01
    public static let headerSize = 4
    public var codecId = FecHeader.codecReedSolomon
    public var dataShards: Int
    public var parityShards: Int
    public var shardIndex: Int

    public init(codecId: Int = FecHeader.codecReedSolomon, dataShards: Int, parityShards: Int, shardIndex: Int) {
        self.codecId = codecId
        self.dataShards = dataShards
        self.parityShards = parityShards
        self.shardIndex = shardIndex
    }

    public static func unmarshal(_ data: [UInt8]) -> FecHeader? {
        guard data.count >= headerSize else { return nil }
        return FecHeader(codecId: Int(data[0]), dataShards: Int(data[1]), parityShards: Int(data[2]), shardIndex: Int(data[3]))
    }

    public func marshal() -> [UInt8] {
        [UInt8(codecId & 0xFF), UInt8(dataShards & 0xFF), UInt8(parityShards & 0xFF), UInt8(shardIndex & 0xFF)]
    }
    public var totalShards: Int { dataShards + parityShards }
    public var isDataShard: Bool { shardIndex < dataShards }
    public var isParityShard: Bool { shardIndex >= dataShards }
}

public enum ReedSolomon {
    public enum EncodeError: Error, Equatable { case badDataShards, badParityShards, tooManyShards }

    /// K data shards and M parity shards, each with its header; the data shards verbatim.
    public static func encode(_ data: [UInt8], dataShards: Int, parityShards: Int) throws -> [[UInt8]] {
        guard (1...255).contains(dataShards) else { throw EncodeError.badDataShards }
        guard (1...255).contains(parityShards) else { throw EncodeError.badParityShards }
        guard dataShards + parityShards <= 256 else { throw EncodeError.tooManyShards }
        let shardSize = (data.count + dataShards - 1) / dataShards
        let total = dataShards + parityShards
        var shards = Array(repeating: [UInt8](repeating: 0, count: shardSize), count: total)
        for i in 0..<dataShards {
            let offset = i * shardSize
            let len = min(shardSize, data.count - offset)
            if len > 0 { shards[i].replaceSubrange(0..<len, with: data[offset..<(offset + len)]) }
        }
        for p in 0..<parityShards {
            for bytePos in 0..<shardSize {
                var v: UInt8 = 0
                for d in 0..<dataShards {
                    // Vandermonde: alpha^(row x column) with the row number from 1.
                    let coeff = GaloisField256.pow(UInt8(p + 1), d)
                    v = GaloisField256.add(v, GaloisField256.mul(coeff, shards[d][bytePos]))
                }
                shards[dataShards + p][bytePos] = v
            }
        }
        return shards.enumerated().map { idx, shard in
            FecHeader(dataShards: dataShards, parityShards: parityShards, shardIndex: idx).marshal() + shard
        }
    }

    /// The original data from any K shards, or nil with fewer or a singular set.
    public static func decode(_ shards: [[UInt8]], originalSize: Int) -> [UInt8]? {
        guard !shards.isEmpty else { return nil }
        var headers: [FecHeader] = []
        for s in shards {
            guard let h = FecHeader.unmarshal(s) else { return nil }
            headers.append(h)
        }
        let k = headers[0].dataShards
        guard shards.count >= k, k > 0 else { return nil }
        let selected = Array(shards.prefix(k))
        let indices = headers.prefix(k).map(\.shardIndex)
        let shardData = selected.map { Array($0[FecHeader.headerSize...]) }
        let shardSize = shardData[0].count
        // Every data shard in hand: just concatenate.
        if (0..<k).allSatisfy({ indices.contains($0) }) {
            let sorted = zip(indices, shardData).sorted { $0.0 < $1.0 }.map(\.1)
            return assemble(sorted, originalSize: originalSize)
        }
        // Invert the rows that were received (identity for data, Vandermonde for parity).
        var augmented = Array(repeating: [UInt8](repeating: 0, count: 2 * k), count: k)
        for i in 0..<k {
            let idx = indices[i]
            if idx < k {
                augmented[i][idx] = 1
            } else {
                for j in 0..<k { augmented[i][j] = GaloisField256.pow(UInt8(idx - k + 1), j) }
            }
            augmented[i][k + i] = 1
        }
        for col in 0..<k {
            guard let pivotRow = (col..<k).first(where: { augmented[$0][col] != 0 }) else { return nil }
            augmented.swapAt(col, pivotRow)
            let pivotInv = GaloisField256.inv(augmented[col][col])
            for j in 0..<(2 * k) { augmented[col][j] = GaloisField256.mul(augmented[col][j], pivotInv) }
            for row in 0..<k where row != col {
                let factor = augmented[row][col]
                if factor == 0 { continue }
                for j in 0..<(2 * k) {
                    augmented[row][j] = GaloisField256.add(augmented[row][j], GaloisField256.mul(factor, augmented[col][j]))
                }
            }
        }
        var recovered = Array(repeating: [UInt8](repeating: 0, count: shardSize), count: k)
        for i in 0..<k {
            for bytePos in 0..<shardSize {
                var v: UInt8 = 0
                for j in 0..<k { v = GaloisField256.add(v, GaloisField256.mul(augmented[i][k + j], shardData[j][bytePos])) }
                recovered[i][bytePos] = v
            }
        }
        return assemble(recovered, originalSize: originalSize)
    }

    private static func assemble(_ shards: [[UInt8]], originalSize: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: originalSize)
        var offset = 0
        for shard in shards {
            let len = min(shard.count, originalSize - offset)
            if len > 0 { result.replaceSubrange(offset..<(offset + len), with: shard[0..<len]) }
            offset += shard.count
        }
        return result
    }
}

/// The FEC step of a transform chain: shards out, and shards collected by group until K are in.
public final class FecTransform: @unchecked Sendable {
    private struct Collector {
        let originalSize: Int
        var shards: [[UInt8]] = []
        let createdAtMs: Int64
    }

    private let lock = NSLock()
    private var collectors: [String: Collector] = [:]
    private let now: @Sendable () -> Int64

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.now = now }

    public func encodeToShards(_ data: [UInt8], dataShards: Int, parityShards: Int) throws -> [[UInt8]] {
        try ReedSolomon.encode(data, dataShards: dataShards, parityShards: parityShards)
    }

    /// A received shard; the payload once K of its group are in, nil until then.
    public func feedShard(groupKey: String, _ shard: [UInt8], originalSize: Int) -> [UInt8]? {
        guard let header = FecHeader.unmarshal(shard) else { return nil }
        lock.lock()
        var collector = collectors[groupKey] ?? Collector(originalSize: originalSize, createdAtMs: now())
        collector.shards.append(shard)
        if collector.shards.count >= header.dataShards {
            collectors[groupKey] = nil
            lock.unlock()
            return ReedSolomon.decode(collector.shards, originalSize: originalSize)
        }
        collectors[groupKey] = collector
        lock.unlock()
        return nil
    }

    /// Drops groups older than five minutes.
    public func pruneStale() {
        let cutoff = now() - 300_000
        lock.lock()
        collectors = collectors.filter { $0.value.createdAtMs >= cutoff }
        lock.unlock()
    }
}
