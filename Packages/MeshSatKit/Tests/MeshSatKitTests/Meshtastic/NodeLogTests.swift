// Mirrors NodeLogTest.kt (MESHSAT-1374): the LogRecord decode, the line format and the buffer.
import MeshSatMeshtastic
import MeshSatProto
import XCTest

final class NodeLogTests: XCTestCase {
    private func record(
        _ message: String, level: Meshtastic_LogRecord.Level = .info, source: String = "IridiumPipe", time: UInt32 = 0
    ) -> [UInt8] {
        var r = Meshtastic_LogRecord()
        r.message = message
        r.level = level
        r.source = source
        r.time = time
        return Array((try? r.serializedBytes()) ?? Data())
    }

    func testParseTakesTheRecordAndTrimsTheLineEnding() throws {
        let line = try XCTUnwrap(NodeLog.parse(record("phone owns the modem\r\n", level: .warning, time: 1_700_000_000), receivedMs: 5))
        XCTAssertEqual(line.message, "phone owns the modem")
        XCTAssertEqual(line.level, "WARN")
        XCTAssertEqual(line.source, "IridiumPipe")
        XCTAssertEqual(line.timeSec, 1_700_000_000)
        XCTAssertEqual(line.receivedMs, 5)
        XCTAssertNil(NodeLog.parse([], receivedMs: 0))
        XCTAssertNil(try XCTUnwrap(NodeLog.parse(record("x", level: .unset), receivedMs: 0)).level)
        XCTAssertEqual(NodeLog.parse(record("x", level: .critical), receivedMs: 0)?.level, "CRIT")
        XCTAssertEqual(NodeLog.parse(record("x", level: .trace), receivedMs: 0)?.level, "TRACE")
    }

    func testFormatUsesTheNodesTimeWhenItHasOneElseThePhones() {
        let utc = TimeZone(identifier: "UTC")!
        let timed = NodeLogLine(timeSec: 1_700_000_000, level: "INFO", source: "BleWatchdog", message: "armed", receivedMs: 0)
        XCTAssertEqual(NodeLog.format(timed, timeZone: utc), "22:13:20 INFO [BleWatchdog] armed")
        let untimed = NodeLogLine(timeSec: 0, level: nil, source: "", message: "boot", receivedMs: 1_700_000_000_000 + 61_000)
        XCTAssertEqual(NodeLog.format(untimed, timeZone: utc), "22:14:21 boot")
    }

    func testTheBufferKeepsTheNewestHoldsWhilePausedAndAppendsOnResume() {
        let buffer = NodeLogBuffer(capacity: 3)
        func line(_ n: Int) -> NodeLogLine { NodeLogLine(timeSec: 0, level: "INFO", source: "", message: "\(n)", receivedMs: Int64(n)) }
        for n in 1...4 { buffer.add(line(n)) }
        XCTAssertEqual(buffer.lines.value.map(\.message), ["2", "3", "4"])
        buffer.pause()
        buffer.add(line(5))
        XCTAssertEqual(buffer.lines.value.map(\.message), ["2", "3", "4"], "held while paused")
        XCTAssertTrue(buffer.paused.value)
        buffer.resume()
        XCTAssertEqual(buffer.lines.value.map(\.message), ["3", "4", "5"])
        XCTAssertEqual(buffer.text(timeZone: TimeZone(identifier: "UTC")!).split(separator: "\n").count, 3)
        buffer.clear()
        XCTAssertEqual(buffer.lines.value, [])
        XCTAssertEqual(buffer.text(), "")
    }
}
