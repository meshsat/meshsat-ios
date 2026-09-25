// Mirrors RlncDecoderTest.kt, GaloisField256Test.kt and ReedSolomonTest.kt.
import XCTest

@testable import MeshSatHemb

final class RlncDecoderTests: XCTestCase {
    /// Fresh coefficients until the first K packets are mutually innovative (MESHSAT-1269).
    private func encodeInnovative(_ segments: [[UInt8]], generationId: Int, codedCount: Int, attempts: Int = 10) throws -> [RlncCodedPacket]
    {
        let k = segments.count
        for _ in 0..<attempts {
            let coded = try RlncEncoder.encode(segments, generationId: generationId, codedCount: codedCount)
            let probe = RlncDecoder(segmentCount: k, segmentSize: segments[0].count)
            for p in coded.prefix(k) { _ = try? probe.feed(p) }
            if probe.rank == k { return coded }
        }
        throw XCTSkip("no full-rank encoding of K=\(k) in \(attempts) attempts")
    }

    private func reconstruct(_ segments: [[UInt8]], size: Int) -> [UInt8] { Array(segments.flatMap { $0 }.prefix(size)) }

    func testEncodeAndDecodeWithExactK() throws {
        let data = Array("Hello RLNC World!".utf8)
        let segments = RlncEncoder.segmentPayload(data, k: 4)
        let coded = try encodeInnovative(segments, generationId: 1, codedCount: 4)
        let decoder = RlncDecoder(segmentCount: 4, segmentSize: segments[0].count)
        for p in coded { try decoder.feed(p) }
        XCTAssertTrue(decoder.isSolvable)
        XCTAssertEqual(reconstruct(try XCTUnwrap(decoder.solve()), size: data.count), data)
    }

    func testDecodeWithExtraPackets() throws {
        let data = (0..<50).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        let segments = RlncEncoder.segmentPayload(data, k: 5)
        let coded = try encodeInnovative(segments, generationId: 2, codedCount: 7)
        let decoder = RlncDecoder(segmentCount: 5, segmentSize: segments[0].count)
        for p in coded.prefix(5) { try decoder.feed(p) }
        XCTAssertTrue(decoder.isSolvable)
        XCTAssertEqual(reconstruct(try XCTUnwrap(decoder.solve()), size: data.count), data)
    }

    func testProgressiveRank() throws {
        let segments: [[UInt8]] = [[1, 2], [3, 4], [5, 6]]
        let coded = try encodeInnovative(segments, generationId: 3, codedCount: 4)
        let decoder = RlncDecoder(segmentCount: 3, segmentSize: 2)
        XCTAssertEqual(decoder.rank, 0)
        XCTAssertFalse(decoder.isSolvable)
        for (i, p) in coded.prefix(3).enumerated() {
            try decoder.feed(p)
            XCTAssertEqual(decoder.rank, i + 1)
        }
        XCTAssertTrue(decoder.isSolvable)
    }

    func testEncodingSurvivesADependentDraw() throws {
        let segments = RlncEncoder.segmentPayload((0..<50).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }, k: 5)
        for _ in 0..<300 {
            let coded = try encodeInnovative(segments, generationId: 9, codedCount: 7)
            let decoder = RlncDecoder(segmentCount: 5, segmentSize: segments[0].count)
            for p in coded.prefix(5) { try decoder.feed(p) }
            XCTAssertTrue(decoder.isSolvable)
        }
    }

    func testDuplicateDoesNotIncreaseRank() throws {
        let coded = try RlncEncoder.encode([[10, 20], [30, 40]], generationId: 4, codedCount: 3)
        let decoder = RlncDecoder(segmentCount: 2, segmentSize: 2)
        XCTAssertTrue(try decoder.feed(coded[0]))
        XCTAssertFalse(try decoder.feed(coded[0]))
        XCTAssertEqual(decoder.rank, 1)
        XCTAssertThrowsError(
            try decoder.feed(RlncCodedPacket(generationId: 4, segmentCount: 3, coefficients: [1, 1, 1], codedData: [1, 2])))
        XCTAssertThrowsError(try decoder.feed(RlncCodedPacket(generationId: 4, segmentCount: 2, coefficients: [1, 1], codedData: [1])))
    }

    func testWireFormatRoundTrip() throws {
        let pkt = try RlncEncoder.encode([[1, 2, 3]], generationId: 0x1234, codedCount: 1)[0]
        let wire = pkt.marshal()
        XCTAssertEqual(Array(wire.prefix(3)), [0x12, 0x34, 1])
        XCTAssertEqual(RlncCodedPacket.unmarshal(wire), pkt)
        XCTAssertNil(RlncCodedPacket.unmarshal([0, 1]))
        XCTAssertNil(RlncCodedPacket.unmarshal([0, 1, 5, 1]))
        XCTAssertEqual(RlncEncoder.segmentPayload([1, 2, 3, 4, 5], k: 2), [[1, 2, 3], [4, 5, 0]])
        XCTAssertEqual(GF256Vector.add([1, 2], [3, 4]), [2, 6])
        XCTAssertEqual(GF256Vector.dot([1, 0], [5, 9]), 5)
        XCTAssertFalse(GF256Vector.randomCoefficients(50).contains(0))
    }
}

final class GaloisField256Tests: XCTestCase {
    func testField() {
        XCTAssertEqual(GaloisField256.add(42, 42), 0)
        XCTAssertEqual(GaloisField256.add(42, 17), 42 ^ 17)
        for a in 0...255 {
            XCTAssertEqual(GaloisField256.mul(UInt8(a), 1), UInt8(a))
            XCTAssertEqual(GaloisField256.mul(UInt8(a), 0), 0)
        }
        for a in 1...255 {
            XCTAssertEqual(GaloisField256.mul(UInt8(a), GaloisField256.inv(UInt8(a))), 1, "\(a)")
            for b in 1...10 { XCTAssertEqual(GaloisField256.div(GaloisField256.mul(UInt8(a), UInt8(b)), UInt8(b)), UInt8(a)) }
        }
        XCTAssertEqual(GaloisField256.mul(GaloisField256.mul(42, 17), 99), GaloisField256.mul(42, GaloisField256.mul(17, 99)))
        XCTAssertEqual(GaloisField256.pow(42, 0), 1)
        XCTAssertEqual(GaloisField256.pow(42, 1), 42)
        XCTAssertEqual(GaloisField256.pow(2, 8), 0x1D)
        XCTAssertEqual(GaloisField256.pow(0, 3), 0)
    }
}

final class ReedSolomonTests: XCTestCase {
    func testEncodeProducesShardsWithHeaders() throws {
        let shards = try ReedSolomon.encode(Array("Hello, MeshSat FEC!".utf8), dataShards: 4, parityShards: 2)
        XCTAssertEqual(shards.count, 6)
        let data = (0..<100).map { UInt8($0) }
        for (i, shard) in try ReedSolomon.encode(data, dataShards: 5, parityShards: 2).enumerated() {
            let header = try XCTUnwrap(FecHeader.unmarshal(shard))
            XCTAssertEqual(header.dataShards, 5)
            XCTAssertEqual(header.parityShards, 2)
            XCTAssertEqual(header.shardIndex, i)
            XCTAssertEqual(header.isDataShard, i < 5)
            XCTAssertEqual(header.totalShards, 7)
        }
        XCTAssertThrowsError(try ReedSolomon.encode([1], dataShards: 0, parityShards: 1))
        XCTAssertThrowsError(try ReedSolomon.encode([1], dataShards: 200, parityShards: 100))
    }

    func testDecodeVariants() throws {
        let text = Array("Hello, World! This is a FEC test payload.".utf8)
        let shards = try ReedSolomon.encode(text, dataShards: 4, parityShards: 2)
        XCTAssertEqual(ReedSolomon.decode(Array(shards.prefix(4)), originalSize: text.count), text)
        let data = (0..<40).map { UInt8(truncatingIfNeeded: $0 * 3 + 7) }
        let s2 = try ReedSolomon.encode(data, dataShards: 4, parityShards: 2)
        XCTAssertEqual(ReedSolomon.decode([s2[0], s2[1], s2[3], s2[4]], originalSize: data.count), data)
        let data3 = (0..<50).map { UInt8(truncatingIfNeeded: $0 * 7 + 13) }
        let s3 = try ReedSolomon.encode(data3, dataShards: 5, parityShards: 2)
        XCTAssertEqual(ReedSolomon.decode([s3[0], s3[2], s3[4], s3[5], s3[6]], originalSize: data3.count), data3)
        XCTAssertNil(ReedSolomon.decode(Array(s2.prefix(3)), originalSize: data.count))
        XCTAssertNil(ReedSolomon.decode([], originalSize: 1))
        let single = try ReedSolomon.encode([42], dataShards: 1, parityShards: 1)
        XCTAssertEqual(single.count, 2)
        XCTAssertEqual(ReedSolomon.decode([single[1]], originalSize: 1), [42])
    }

    func testFecTransformCollectsShards() throws {
        let clock = TestClock()
        let fec = FecTransform(now: { clock.now })
        let data = (0..<30).map { UInt8($0) }
        let shards = try fec.encodeToShards(data, dataShards: 3, parityShards: 1)
        XCTAssertNil(fec.feedShard(groupKey: "g", shards[3], originalSize: data.count))
        XCTAssertNil(fec.feedShard(groupKey: "g", shards[1], originalSize: data.count))
        XCTAssertEqual(fec.feedShard(groupKey: "g", shards[0], originalSize: data.count), data)
        XCTAssertNil(fec.feedShard(groupKey: "old", shards[0], originalSize: data.count))
        clock.now += 300_001
        fec.pruneStale()
        XCTAssertNil(
            fec.feedShard(groupKey: "old", shards[1], originalSize: data.count),
            "the stale group was dropped, so this is the first shard again")
        XCTAssertNil(fec.feedShard(groupKey: "x", [1], originalSize: 1))
    }
}
