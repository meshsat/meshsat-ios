// Mirrors BurstQueueTest.kt (Phase D: opportunistic satellite burst).
import XCTest

@testable import MeshSatEngine

final class BurstQueueTests: XCTestCase {
    private func queue(maxSize: Int = 10) -> BurstQueue { BurstQueue(maxSize: maxSize, maxAgeMs: 5 * 60_000, now: { 1_000_000 }) }

    func testEmptyQueueFlushReturnsNil() {
        let (payload, count) = queue().flush()
        XCTAssertNil(payload)
        XCTAssertEqual(count, 0)
    }

    func testEnqueueAndFlushSingleMessage() throws {
        let bq = queue()
        try bq.enqueue(BurstMessage(payload: Array("hello".utf8), interfaceId: "iridium_0"))
        XCTAssertEqual(bq.pending(), 1)
        let (payload, count) = bq.flush()
        XCTAssertNotNil(payload)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bq.pending(), 0)
        XCTAssertEqual(payload?[0], BurstQueue.burstTypeByte)
        XCTAssertEqual(payload, [0x42, 1, 0, 5, 0] + Array("hello".utf8))
    }

    func testPackAndUnpackRoundTrip() throws {
        let messages = ["alpha", "bravo", "charlie"].map { BurstMessage(payload: Array($0.utf8), interfaceId: "iridium_0") }
        let (wire, count) = BurstQueue.packBurst(messages, mtu: 340)
        XCTAssertEqual(count, 3)
        let unpacked = try BurstQueue.unpackBurst(wire)
        XCTAssertEqual(unpacked.map { String(decoding: $0, as: UTF8.self) }, ["alpha", "bravo", "charlie"])
    }

    func testPriorityOrderingHigherFirst() throws {
        let bq = queue()
        try bq.enqueue(BurstMessage(payload: Array("low".utf8), priority: 0, interfaceId: "iridium_0"))
        try bq.enqueue(BurstMessage(payload: Array("high".utf8), priority: 10, interfaceId: "iridium_0"))
        try bq.enqueue(BurstMessage(payload: Array("mid".utf8), priority: 5, interfaceId: "iridium_0"))
        let (payload, count) = bq.flush()
        XCTAssertEqual(count, 3)
        let unpacked = try BurstQueue.unpackBurst(try XCTUnwrap(payload))
        XCTAssertEqual(unpacked.map { String(decoding: $0, as: UTF8.self) }, ["high", "mid", "low"])
    }

    func testShouldFlushWhenMaxSizeReached() throws {
        let bq = queue(maxSize: 2)
        XCTAssertFalse(bq.shouldFlush())
        try bq.enqueue(BurstMessage(payload: [0x61], queuedAt: 1_000_000, interfaceId: "iridium_0"))
        XCTAssertFalse(bq.shouldFlush())
        try bq.enqueue(BurstMessage(payload: [0x62], queuedAt: 1_000_000, interfaceId: "iridium_0"))
        XCTAssertTrue(bq.shouldFlush())
    }

    func testShouldFlushWhenOldestExceedsMaxAge() throws {
        let bq = queue()
        try bq.enqueue(BurstMessage(payload: [0x61], queuedAt: 1_000_000 - 5 * 60_000 + 1, interfaceId: "iridium_0"))
        XCTAssertFalse(bq.shouldFlush())
        try bq.enqueue(BurstMessage(payload: [0x62], queuedAt: 1_000_000 - 5 * 60_000, interfaceId: "iridium_0"))
        XCTAssertTrue(bq.shouldFlush())
    }

    func testMtuLimitRespected() throws {
        let bq = queue(maxSize: 100)
        let large = [UInt8](repeating: 0x42, count: 200)
        try bq.enqueue(BurstMessage(payload: large, interfaceId: "iridium_0"))
        try bq.enqueue(BurstMessage(payload: large, interfaceId: "iridium_0"))
        let (payload, count) = bq.flush()
        XCTAssertLessThanOrEqual(try XCTUnwrap(payload).count, 340)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bq.pending(), 1)
    }

    func testEnqueueRejectsEmptyAndOversized() {
        let bq = queue()
        XCTAssertThrowsError(try bq.enqueue(BurstMessage(payload: [])))
        XCTAssertThrowsError(try bq.enqueue(BurstMessage(payload: [UInt8](repeating: 1, count: BurstQueue.maxPayload + 1))))
        XCTAssertNoThrow(try bq.enqueue(BurstMessage(payload: [UInt8](repeating: 1, count: BurstQueue.maxPayload))))
    }

    func testUnpackRejectsMalformed() {
        XCTAssertThrowsError(try BurstQueue.unpackBurst([0x42, 0]))
        XCTAssertThrowsError(try BurstQueue.unpackBurst([0x41, 0, 0]))
        XCTAssertThrowsError(try BurstQueue.unpackBurst([0x42, 1, 0, 5, 0, 1, 2]))
        XCTAssertThrowsError(try BurstQueue.unpackBurst([0x42, 1, 0, 5]))
        XCTAssertEqual(try BurstQueue.unpackBurst([0x42, 0, 0]), [])
    }
}
