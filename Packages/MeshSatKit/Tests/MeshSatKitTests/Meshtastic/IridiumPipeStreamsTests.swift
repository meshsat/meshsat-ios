// Mirrors IridiumPipeStreamsTest.kt: the byte-stream side of the node's BLE Iridium pipe.
import MeshSatMeshtastic
import XCTest

final class IridiumPipeStreamsTests: XCTestCase {
    func testInputKeepsBinaryBytesInOrderAndCountsWhatDidNotFit() {
        let input = PipeInputBuffer(capacity: 4)
        XCTAssertEqual(input.offer([0x00, 0x0D, 0x0A]), 0)
        XCTAssertEqual(input.offer([0xFF, 0x94, 0xC3]), 2)
        XCTAssertEqual(input.available, 4)
        XCTAssertEqual(input.read(max: 8), [0x00, 0x0D, 0x0A, 0xFF])
        XCTAssertNil(input.read())
    }

    func testOutputIsSentInChunksOfTheLinkSizeEachAcknowledged() async throws {
        let sent = SentChunks()
        let out = PipeOutputChunker(chunkSize: { 20 }, canWrite: { true }, sendChunk: { await sent.add($0) })
        let payload = (0..<342).map { UInt8(truncatingIfNeeded: $0) }
        try await out.write(payload)
        let chunks = await sent.chunks
        XCTAssertEqual(chunks.count, 18)
        XCTAssertEqual(chunks.flatMap { $0 }, payload)
    }

    func testOutputRefusesToWriteWhileThePhoneDoesNotOwnTheModem() async {
        let out = PipeOutputChunker(chunkSize: { 244 }, canWrite: { false }, sendChunk: { _ in true })
        do {
            try await out.write(Array("AT+SBDIX\r".utf8))
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? PipeError, .notOwned)
        }
    }

    func testAFailedChunkWriteSurfacesAsWriteFailed() async {
        let out = PipeOutputChunker(chunkSize: { 244 }, canWrite: { true }, sendChunk: { _ in false })
        do {
            try await out.write(Array("AT\r".utf8))
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? PipeError, .writeFailed)
        }
    }

    func testSbdringIsSeenEvenWhenSplitAcrossNotifications() {
        let rings = Counter()
        let watcher = LineWatcher(line: "SBDRING") { rings.bump() }
        watcher.feed(Array("\r\nSBD".utf8))
        watcher.feed(Array("RI".utf8))
        watcher.feed(Array("NG\r\n".utf8))
        XCTAssertEqual(rings.value, 1)
        watcher.feed(Array("OK\r\nSSBDRING\r\n".utf8))
        XCTAssertEqual(rings.value, 2)
        watcher.feed(Array("+SBDRING: no\r\nSBDRIN\r\n".utf8))
        XCTAssertEqual(rings.value, 2)
    }
}

actor SentChunks {
    var chunks: [[UInt8]] = []
    func add(_ c: [UInt8]) -> Bool {
        chunks.append(c)
        return true
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
    func bump() {
        lock.lock()
        n += 1
        lock.unlock()
    }
}
