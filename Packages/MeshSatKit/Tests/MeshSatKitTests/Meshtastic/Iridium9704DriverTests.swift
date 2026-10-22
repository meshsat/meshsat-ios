// Mirrors Iridium9704Test.kt (CRC-16, spacedJson, constants, the MO status rule) and goes beyond
// it: the 9704 driver over a byte link against a scripted modem that speaks JSPR as the RockBLOCK
// 9704 does (MESHSAT-1624): the init, an MO the modem segments itself, an MT with its CRC, the
// 150 s budget and the cancel. Android could check the JSPR exchange only on a phone.
import Foundation
import MeshSatEngine
import MeshSatNet
import MeshSatWire
import XCTest

@testable import MeshSatMeshtastic

/// A virtual clock whose sleeps also take a hundredth of their time for real, so several loops
/// sleeping on it at once cannot race its time ahead of the work they wait for.
final class PacedClock: DriverClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64

    /// 2026-10-21T13:00:00Z by default.
    init(startMs: Int64 = 1_792_587_600_000) { now = startMs }

    func nowMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(ms: Int64) {
        lock.lock()
        now += ms
        lock.unlock()
    }

    func sleep(ms: Int64) async {
        advance(ms: ms)
        try? await Task.sleep(nanoseconds: UInt64(max(ms, 1)) * 10_000)
    }
}

/// A scripted RockBLOCK 9704 behind the pipe: it answers each JSPR request at once, as the bytes
/// arrive, asks for an MO's segments one after the other and settles it, and says what a test
/// makes it say on its own (an MT).
final class FakeJsprModem: ModemLink, @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let target: String
        let json: String
        /// The whole line as it came, without its CR.
        let line: String
    }

    private let lock = NSLock()
    private var receiver: (@Sendable ([UInt8]) -> Void)?
    private var pending: [UInt8] = []
    private var requestLog: [Request] = []
    private var apiVersionSet = false
    private var simInterface = "external"
    private var operational = "inactive"
    // MO in flight
    private var moTopic = 0
    private var moLength = 0
    private var moBytes: [UInt8] = []
    private var segmentLog: [(start: Int, data: String)] = []

    /// The segment size the modem asks for.
    var segmentSize = Iridium9704Driver.maxSegmentSize
    /// The final status after the last segment; nil: the modem never reports one.
    var finalMoStatus: String? = "mo_ack_received"
    /// Whether the modem answers a cancel (with 200, then the message's one final status).
    var answersCancel = true
    let messageId = 7

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var requests: [Request] { locked { requestLog } }
    /// The MO as the modem assembled it from the segments, CRC included.
    var moReceived: [UInt8] { locked { moBytes } }
    var segments: [(start: Int, data: String)] { locked { segmentLog } }

    func setReceiver(_ receiver: (@Sendable ([UInt8]) -> Void)?) {
        locked { self.receiver = receiver }
    }

    func write(_ bytes: [UInt8]) async throws {
        var lines: [String] = []
        locked {
            for b in bytes {
                if b == 0x0D {
                    lines.append(String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                } else {
                    pending.append(b)
                }
            }
        }
        for line in lines { say(answer(line)) }
    }

    /// Something the modem says on its own, one line, CR added.
    func say(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let r = locked { receiver }
        r?(Array(lines.map { $0 + "\r" }.joined().utf8))
    }

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// The lines the modem answers a request with.
    private func answer(_ line: String) -> [String] {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return ["400 unknown {}"] }
        let (method, target, body) = (parts[0], parts[1], parts.count > 2 ? parts[2] : "")
        locked { requestLog.append(Request(method: method, target: target, json: body, line: line)) }
        let request = json(body)
        switch (method, target) {
        case ("GET", "apiVersion"):
            return locked { apiVersionSet }
                ? ["200 apiVersion {\"active_version\": {\"major\": 1, \"minor\": 0, \"patch\": 0}}"]
                : ["200 apiVersion {\"supported_versions\": [{\"major\": 1, \"minor\": 0, \"patch\": 0}]}"]
        case ("PUT", "apiVersion"):
            locked { apiVersionSet = true }
            return ["200 apiVersion {\"active_version\": {\"major\": 1, \"minor\": 0, \"patch\": 0}}"]
        case ("GET", "simConfig"):
            return ["200 simConfig {\"interface\": \"\(locked { simInterface })\"}"]
        case ("PUT", "simConfig"):
            locked { simInterface = request["interface"] as? String ?? "" }
            return ["200 simConfig {\"interface\": \"internal\"}", "299 simStatus {\"card_present\": true, \"sim_connected\": true}"]
        case ("GET", "operationalState"):
            return ["200 operationalState {\"state\": \"\(locked { operational })\"}"]
        case ("PUT", "operationalState"):
            locked { operational = request["state"] as? String ?? "" }
            return ["200 operationalState {\"state\": \"\(locked { operational })\"}"]
        case ("GET", "hwInfo"):
            return [
                "200 hwInfo {\"hw_version\": \"1.0\", \"serial_number\": \"TEST-1\", \"imei\": \"300000000000001\", \"board_temp\": 24}"
            ]
        case ("GET", "constellationState"):
            return ["200 constellationState {\"constellation_visible\": true, \"signal_bars\": 3, \"signal_level\": -110}"]
        case ("PUT", "messageOriginate"):
            return originate(request)
        case ("PUT", "messageOriginateSegment"):
            return segment(request)
        case ("PUT", "messageOriginateStatus"):
            guard answersCancel else { return [] }
            return [
                "200 messageOriginateStatus {\"topic_id\": \(locked { moTopic }), \"message_id\": \(messageId)}",
                "299 messageOriginateStatus {\"topic_id\": \(locked { moTopic }), \"message_id\": \(messageId), "
                    + "\"final_mo_status\": \"message_cancelled_pre_transit\"}",
            ]
        default:
            return ["404 \(target) {}"]
        }
    }

    private func originate(_ request: [String: Any]) -> [String] {
        let topic = request["topic_id"] as? Int ?? -1
        let length = request["message_length"] as? Int ?? -1
        let ref = request["request_reference"] as? Int ?? -1
        locked {
            moTopic = topic
            moLength = length
            moBytes = []
            segmentLog = []
        }
        return [
            "200 messageOriginate {\"topic_id\": \(topic), \"request_reference\": \(ref), \"message_id\": \(messageId), "
                + "\"message_response\": \"message_accepted\"}",
            segmentRequest(start: 0),
        ]
    }

    private func segmentRequest(start: Int) -> String {
        let (topic, length) = locked { (moTopic, moLength) }
        return "299 messageOriginateSegment {\"topic_id\": \(topic), \"message_id\": \(messageId), "
            + "\"segment_length\": \(min(segmentSize, length - start)), \"segment_start\": \(start)}"
    }

    private func segment(_ request: [String: Any]) -> [String] {
        let start = request["segment_start"] as? Int ?? -1
        let data = request["data"] as? String ?? ""
        // An independent decoder: Foundation's, not the driver's.
        let bytes = Data(base64Encoded: data).map { [UInt8]($0) } ?? []
        let (received, length, topic) = locked {
            segmentLog.append((start, data))
            if start == moBytes.count { moBytes += bytes }
            return (moBytes.count, moLength, moTopic)
        }
        var out = ["200 messageOriginateSegment {\"topic_id\": \(topic), \"message_id\": \(messageId), \"segment_start\": \(start)}"]
        if received < length {
            out.append(segmentRequest(start: received))
        } else if let final = finalMoStatus {
            out.append(
                "299 messageOriginateStatus {\"topic_id\": \(topic), \"message_id\": \(messageId), \"final_mo_status\": \"\(final)\"}")
        }
        return out
    }
}

/// Values a test collects from the driver's tasks.
final class Collected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    var list: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class Iridium9704DriverTests: XCTestCase {
    private func eventually(_ timeoutMs: Int = 20_000, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await cond()
    }

    /// Attached and through the init.
    private func ready(_ modem: FakeJsprModem, file: StaticString = #filePath, line: UInt = #line) async -> Iridium9704Driver {
        let driver = Iridium9704Driver(clock: PacedClock())
        await driver.attach(modem)
        let up = await eventually { await driver.state == .ready }
        XCTAssertTrue(up, "the init did not finish", file: file, line: line)
        return driver
    }

    private func crcBytes(_ data: [UInt8]) -> [UInt8] {
        let crc = Iridium9704Driver.crc16(data)
        return [UInt8(crc >> 8), UInt8(crc & 0xFF)]
    }

    // MARK: The init

    func testTheInitNegotiatesTurnsTheModemOnAndReadsTheImei() async {
        let modem = FakeJsprModem()
        let driver = await ready(modem)
        XCTAssertEqual(
            modem.requests.map { "\($0.method) \($0.target)" },
            [
                "GET apiVersion", "PUT apiVersion", "GET simConfig", "PUT simConfig", "GET operationalState", "PUT operationalState",
                "GET hwInfo", "GET constellationState",
            ])
        // The first supported version is set, and every request has the spaces the modem's parser wants.
        XCTAssertEqual(modem.requests[1].line, "PUT apiVersion {\"active_version\": {\"major\": 1, \"minor\": 0, \"patch\": 0}}")
        XCTAssertEqual(modem.requests[3].line, "PUT simConfig {\"interface\": \"internal\"}")
        XCTAssertEqual(modem.requests[5].line, "PUT operationalState {\"state\": \"active\"}")
        XCTAssertEqual(modem.requests[0].line, "GET apiVersion {}")
        let info = await driver.modemInfo
        XCTAssertEqual(info.imei, "300000000000001")
        XCTAssertEqual(info.serial, "TEST-1")
        XCTAssertEqual(info.boardTemp, 24)
        let signal = await driver.signal
        XCTAssertEqual(signal, 3)
        let onPipe = await driver.onNodePipe
        XCTAssertTrue(onPipe)
        // Busy: a second attach waits for the first to be detached.
        let again = await driver.attachIfIdle(FakeJsprModem())
        XCTAssertFalse(again)
        await driver.detach()
        let state = await driver.state
        XCTAssertEqual(state, .disconnected)
    }

    // MARK: MO

    func testAnMoOfEveryByteValueGoesOutInSegmentsThatDecodeToItsBytes() async throws {
        let modem = FakeJsprModem()
        modem.segmentSize = 100
        let driver = await ready(modem)
        let data = (0...255).map { UInt8($0) }
        let status = await driver.sendMessageBlocking(data)
        XCTAssertEqual(status, "mo_ack_received")
        XCTAssertEqual(modem.moReceived, data + crcBytes(data))
        XCTAssertEqual(modem.segments.map { $0.start }, [0, 100, 200])
        // Each segment's base64 is exactly its slice of the payload.
        let sent = data + crcBytes(data)
        for s in modem.segments {
            let slice = Array(sent[s.start..<min(s.start + 100, sent.count)])
            XCTAssertEqual(Data(base64Encoded: s.data).map { [UInt8]($0) }, slice, "segment at \(s.start)")
        }
        let originate = try XCTUnwrap(modem.requests.first { $0.target == "messageOriginate" })
        XCTAssertEqual(originate.line, "PUT messageOriginate {\"topic_id\": 244, \"message_length\": 258, \"request_reference\": 1}")
        let first = try XCTUnwrap(modem.requests.first { $0.target == "messageOriginateSegment" })
        XCTAssertTrue(
            first.line.hasPrefix(
                "PUT messageOriginateSegment {\"topic_id\": 244, \"message_id\": 7, \"segment_length\": 100, \"segment_start\": 0, "
                    + "\"data\": \""), first.line)
        let mo = await driver.moStatus
        XCTAssertEqual(mo, .idle)
        await driver.detach()
    }

    func testAnHChainWireGoesOutExactlyAndOneAtTheLimitInFullSegments() async throws {
        let modem = FakeJsprModem()
        let driver = await ready(modem)
        let envelope = try XCTUnwrap(try HChainVectors.load().vectors.envelopes.first { $0.name == "el_sentence" })
        let wire = hexBytes(envelope.wireHex)
        let status = await driver.sendMessageBlocking(wire)
        XCTAssertEqual(status, "mo_ack_received")
        XCTAssertEqual(Array(modem.moReceived.dropLast(2)), wire)
        XCTAssertEqual(Array(modem.moReceived.suffix(2)), crcBytes(wire))

        // The longest sealed message: 100,000 bytes, 70 segments of at most 1446. Followed by its
        // status rather than through the blocking send, whose 150 s budget the loops racing this
        // clock could use up on a slow runner.
        var rng = SeededBytes(seed: 1624)
        let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let most = try SatelliteChain.seal(rng.next(SatelliteChain.maxWireBytes - SatelliteChain.overhead), keyHex: key)
        XCTAssertEqual(most.count, Iridium9704Driver.imtMaxSize)
        let started = await driver.sendMessage(most)
        XCTAssertTrue(started)
        let settled = await eventually(60_000) { await driver.moStatus == .complete }
        XCTAssertTrue(settled)
        await driver.resetMoStatus()
        XCTAssertEqual(modem.moReceived, most + crcBytes(most))
        XCTAssertEqual(modem.segments.count, (most.count + 2 + 1445) / 1446)
        XCTAssertEqual(try SatelliteChain.open(Array(modem.moReceived.dropLast(2)), keyHex: key).count, 99_970)
        await driver.detach()
    }

    func testAnOversizeMoIsRefusedBeforeTheModemHearsOfIt() async {
        let modem = FakeJsprModem()
        let driver = await ready(modem)
        let tooLong = [UInt8](repeating: 0x41, count: Iridium9704Driver.imtMaxSize + 1)
        let started = await driver.sendMessage(tooLong)
        XCTAssertFalse(started)
        let status = await driver.sendMessageBlocking(tooLong)
        XCTAssertNil(status)
        XCTAssertFalse(modem.requests.contains { $0.target == "messageOriginate" })
        await driver.detach()
    }

    func testAnMoWithNoFinalStatusIsCancelledAfterTheBudget() async throws {
        let modem = FakeJsprModem()
        modem.finalMoStatus = nil
        let driver = await ready(modem)
        let status = await driver.sendMessageBlocking(Array("meet at the north gate".utf8))
        XCTAssertEqual(status, "message_cancelled_pre_transit")
        let cancel = try XCTUnwrap(modem.requests.first { $0.target == "messageOriginateStatus" })
        XCTAssertEqual(cancel.line, "PUT messageOriginateStatus {\"topic_id\": 244, \"message_id\": 7, \"action\": \"cancel\"}")
        // A modem that never settles the cancel: the message may still go out, and the send says so.
        modem.answersCancel = false
        let unanswered = await driver.sendMessageBlocking(Array("second".utf8))
        XCTAssertEqual(unanswered, Iridium9704Driver.moCancelUnanswered)
        let mo = await driver.moStatus
        XCTAssertEqual(mo, .idle)
        await driver.detach()
    }

    // MARK: MT

    /// The modem's MT lines for `message`, segmented, each written when the last one was read.
    private func deliver(_ message: [UInt8], to driver: Iridium9704Driver, by modem: FakeJsprModem, breakLine: Bool = false) async {
        let b64Segments = stride(from: 0, to: message.count, by: 1446).map {
            (start: $0, data: Data(message[$0..<min($0 + 1446, message.count)]).base64EncodedString())
        }
        var lines = ["299 messageTerminate {\"topic_id\": 244, \"message_id\": 9, \"message_length_max\": \(message.count)}"]
        for (i, s) in b64Segments.enumerated() {
            // A JSON "\n" inside the data, which the lenient decode skips.
            let data = breakLine && i == 0 ? String(s.data.prefix(8)) + "\\n" + String(s.data.dropFirst(8)) : s.data
            lines.append(
                "299 messageTerminateSegment {\"topic_id\": 244, \"message_id\": 9, \"segment_length\": \(s.data.count), "
                    + "\"segment_start\": \(s.start), \"data\": \"\(data)\"}")
        }
        lines.append("299 messageTerminateStatus {\"topic_id\": 244, \"message_id\": 9, \"final_mt_status\": \"complete\"}")
        for line in lines {
            modem.say([line])
            _ = await eventually { driver.bufferedInput == 0 }
        }
    }

    func testAnMtOfBinaryBytesWithItsCrcArrivesExactly() async {
        let modem = FakeJsprModem()
        let driver = await ready(modem)
        let got = Collected<[UInt8]>()
        let errors = Collected<String>()
        let errorStream = driver.errors.subscribe()
        let watcher = Task { for await e in errorStream { errors.add(e) } }
        await driver.setMtSink { got.add($0) }
        var rng = SeededBytes(seed: 9704)
        let payload = (0...255).map { UInt8($0) } + rng.next(3000)
        await deliver(payload + crcBytes(payload), to: driver, by: modem, breakLine: true)
        let arrived = await eventually { got.list.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(got.list.first, payload)
        XCTAssertEqual(errors.list, [])
        watcher.cancel()
        await driver.detach()
    }

    func testAnMtWhoseCrcDoesNotMatchIsHandedOnAndReported() async {
        let modem = FakeJsprModem()
        let driver = await ready(modem)
        let got = Collected<[UInt8]>()
        let errors = Collected<String>()
        let errorStream = driver.errors.subscribe()
        let watcher = Task { for await e in errorStream { errors.add(e) } }
        await driver.setMtSink { got.add($0) }
        let payload = Array("all good here".utf8)
        let crc = crcBytes(payload)
        await deliver(payload + [crc[0] ^ 0xFF, crc[1]], to: driver, by: modem)
        let reported = await eventually { errors.list.contains("MT message CRC mismatch") }
        XCTAssertTrue(reported)
        // Handed on anyway, as Android does: the application layer decides.
        XCTAssertEqual(got.list, [payload])
        watcher.cancel()
        await driver.detach()
    }

    // MARK: Pure helpers (Iridium9704Test.kt)

    func testCrc16IsXmodem() {
        XCTAssertEqual(Iridium9704Driver.crc16([]), 0)
        XCTAssertEqual(Iridium9704Driver.crc16(Array("123456789".utf8)), 0x31C3)
        XCTAssertEqual(Iridium9704Driver.crc16([UInt8](repeating: 0, count: 10)), 0)
        XCTAssertNotEqual(Iridium9704Driver.crc16(Array("abc".utf8)), Iridium9704Driver.crc16(Array("abd".utf8)))
        XCTAssertTrue((1...0xFFFF).contains(Iridium9704Driver.crc16([0x31])))
        let large = (0..<100_000).map { UInt8($0 % 256) }
        XCTAssertEqual(Iridium9704Driver.crc16(large), Iridium9704Driver.crc16(large))
        for data in [Array("SOS".utf8), (0..<340).map { UInt8($0 % 256) }, [0xFF], (0..<1446).map { UInt8($0 % 256) }] {
            let withCrc = data + crcBytes(data)
            let carried = Int(withCrc[data.count]) << 8 | Int(withCrc[data.count + 1])
            XCTAssertEqual(Iridium9704Driver.crc16(Array(withCrc.dropLast(2))), carried)
        }
    }

    func testSpacedJsonAddsTheModemsSpacesOutsideStrings() {
        XCTAssertEqual(Iridium9704Driver.spacedJson("{}"), "{}")
        XCTAssertEqual(Iridium9704Driver.spacedJson("{\"key\":\"value\",\"num\":42}"), "{\"key\": \"value\", \"num\": 42}")
        XCTAssertEqual(
            Iridium9704Driver.spacedJson("{\"url\":\"http://host:8080\",\"list\":\"a,b,c\"}"),
            "{\"url\": \"http://host:8080\", \"list\": \"a,b,c\"}")
        XCTAssertEqual(Iridium9704Driver.spacedJson("{\"a\":{\"b\":1}}"), "{\"a\": {\"b\": 1}}")
        XCTAssertEqual(Iridium9704Driver.spacedJson("{\"q\":\"say \\\"x,y\\\"\",\"n\":1}"), "{\"q\": \"say \\\"x,y\\\"\", \"n\": 1}")
    }

    /// Android's imtStatus (0249d1a): ready is online, disconnected offline, the rest binding.
    func testTheHubReadsAReadyModemAsOnline() {
        XCTAssertEqual(Iridium9704Driver.State.ready.hubStatus, "online")
        XCTAssertEqual(Iridium9704Driver.State.disconnected.hubStatus, "offline")
        for state in [Iridium9704Driver.State.connecting, .connected, .initializing] {
            XCTAssertEqual(state.hubStatus, "binding", "\(state)")
        }
    }

    func testConstantsAndTheMoStatusRule() {
        // The node says it carries a 9704 with STATUS flag bit 4 (IRIDIUM-BLE.md, 8 Oct 2026).
        XCTAssertEqual(IridiumPipeContract.parseStatus([2, 1, 0x14, 3])?.flags, IridiumPipeContract.Flags([.modemAnswers, .modemIsJspr]))
        XCTAssertEqual(IridiumPipeContract.parseStatus([2, 1, 0x04, 3])?.flags?.contains(.modemIsJspr), false)
        XCTAssertEqual(Iridium9704Driver.imtMaxSize, 100_000)
        XCTAssertEqual(Iridium9704Driver.rawTopic, 244)
        XCTAssertEqual(Iridium9704Driver.maxSegmentSize, 1446)
        XCTAssertTrue(Iridium9704Driver.moStatusSettles(inFlightId: 4, statusId: 4))
        // The node's own text (3) and a laptop's (2) sat in the same modem on 8 Oct 2026.
        XCTAssertFalse(Iridium9704Driver.moStatusSettles(inFlightId: 4, statusId: 3))
        XCTAssertFalse(Iridium9704Driver.moStatusSettles(inFlightId: 4, statusId: 2))
        XCTAssertTrue(Iridium9704Driver.moStatusSettles(inFlightId: 4, statusId: -1))
    }

    func testJsprLinesParse() throws {
        let line = "200 hwInfo {\"imei\": \"300000000000001\", \"board_temp\": 24}"
        let hw = try XCTUnwrap(Iridium9704Driver.parseJsprLine(Array(line.utf8)))
        XCTAssertEqual(hw.code, 200)
        XCTAssertEqual(hw.target, "hwInfo")
        XCTAssertEqual(Iridium9704Driver.optString(hw.json, "imei", ""), "300000000000001")
        XCTAssertEqual(Iridium9704Driver.optInt(hw.json, "board_temp", 0), 24)
        XCTAssertEqual(Iridium9704Driver.optInt(hw.json, "missing", -1), -1)
        let bare = try XCTUnwrap(Iridium9704Driver.parseJsprLine(Array("299 simStatus".utf8)))
        XCTAssertEqual(bare.target, "simStatus")
        XCTAssertTrue(bare.json.isEmpty)
        let broken = try XCTUnwrap(Iridium9704Driver.parseJsprLine(Array("407 apiVersion {bad".utf8)))
        XCTAssertEqual(broken.code, 407)
        XCTAssertTrue(broken.json.isEmpty)
        XCTAssertNil(Iridium9704Driver.parseJsprLine(Array("OK".utf8)))
        XCTAssertNil(Iridium9704Driver.parseJsprLine(Array("199 apiVersion {}".utf8)))
        XCTAssertNil(Iridium9704Driver.parseJsprLine(Array("abc apiVersion {}".utf8)))
    }

    /// Java's MIME decoder, which android.util.Base64.DEFAULT stood in for: lenient about what is
    /// not base64, strict about a unit the padding cannot close.
    func testSegmentDataDecodesAsJavasMimeDecoder() {
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("QUJD"), Array("ABC".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("QUI="), Array("AB".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("QUI"), Array("AB".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("QQ=="), Array("A".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("QQ"), Array("A".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("Q U\r\nJ D"), Array("ABC".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes("QUI=\n"), Array("AB".utf8))
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes(""), [])
        for bad in ["Q", "=", "QQ=", "QQ=x", "QUI=QQ==", "QUJDQ"] {
            XCTAssertNil(Iridium9704Driver.jsprSegmentBytes(bad), bad)
        }
    }
}
