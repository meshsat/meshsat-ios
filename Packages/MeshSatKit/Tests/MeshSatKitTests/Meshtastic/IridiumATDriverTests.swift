// Mirrors IridiumSppOverPipeTest.kt: the 9603 driver over a byte link, against a scripted modem
// that behaves like the one on the MeshSat node (MESHSAT-1236): echo on until ATE0, READY then a
// binary phase for SBDWB, binary SBDRB frames, and the cost rules the driver enforces for every
// caller. Time runs on a virtual clock, so every timeout passes at once.
import MeshSatMeshtastic
import MeshSatNet
import XCTest

/// A clock the tests advance: sleeping moves time forward and yields, nothing waits for real.
final class VirtualClock: DriverClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64 = 1_700_000_000_000

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
        await Task.yield()
    }
}

/// A scripted RockBLOCK 9603 behind the pipe.
final class FakeModem: ModemLink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [String] = []
    var echo = true
    var sbdixReply = "+SBDIX: 0, 219, 0, 0, 0, 0"
    var csqf = 2
    var sbdsxReply = "+SBDSX: 0, 218, 0, -1, 0, 0"
    var mt: [UInt8] = []
    /// Commands to ignore first, as a modem still powering up does.
    var silentFor = 0
    var moWritten: [UInt8]?
    /// A wedged BLE pipe: attached, answering every write with a failure (MESHSAT-1270).
    var writesFail = false
    /// The node is using its own modem, so it discards what this phone writes.
    var notOurs = false

    private var receiver: (@Sendable ([UInt8]) -> Void)?
    private var line = [UInt8]()
    private var binaryLeft = 0
    private var binary = [UInt8]()

    func setReceiver(_ receiver: (@Sendable ([UInt8]) -> Void)?) {
        lock.lock()
        self.receiver = receiver
        lock.unlock()
    }

    private func flags() -> (fail: Bool, foreign: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (writesFail, notOurs)
    }

    func write(_ bytes: [UInt8]) async throws {
        let (fail, foreign) = flags()
        if foreign { throw PipeError.notOwned }
        if fail { throw PipeError.writeFailed }
        for b in bytes { onByte(b) }
    }

    func clearCommands() {
        lock.lock()
        commands.removeAll()
        lock.unlock()
    }

    /// Something the modem says on its own, e.g. SBDRING.
    func unsolicited(_ text: String) { send(Array(text.utf8)) }

    private func send(_ bytes: [UInt8]) {
        lock.lock()
        let r = receiver
        lock.unlock()
        r?(bytes)
    }

    private func reply(_ command: String, _ body: String) {
        let echoed = echo ? command + "\r" : ""
        send(Array((echoed + body).utf8))
    }

    private func onByte(_ b: UInt8) {
        if binaryLeft > 0 {
            binary.append(b)
            binaryLeft -= 1
            if binaryLeft == 0 {
                let data = Array(binary.dropLast(2))
                let sum = Int(binary[binary.count - 2]) << 8 | Int(binary[binary.count - 1])
                let ok = data.reduce(0, { $0 + Int($1) }) & 0xFFFF == sum
                if ok { moWritten = data }
                send(Array((ok ? "\r\n0\r\n\r\nOK\r\n" : "\r\n2\r\n\r\nOK\r\n").utf8))
            }
            return
        }
        if b != 0x0D {
            line.append(b)
            return
        }
        let command = String(decoding: line, as: UTF8.self)
        line.removeAll()
        lock.lock()
        commands.append(command)
        let silent = silentFor > 0
        if silent { silentFor -= 1 }
        lock.unlock()
        if silent { return }
        switch command {
        case "ATE0":
            reply(command, "\r\nOK\r\n")
            echo = false
        case "AT+CGMI": reply(command, "\r\nIridium\r\n\r\nOK\r\n")
        case "AT+CGMM": reply(command, "\r\nIRIDIUM 9600 Family SBD Transceiver\r\n\r\nOK\r\n")
        case "AT+CGSN": reply(command, "\r\n300434067943980\r\n\r\nOK\r\n")
        case "AT+CSQ": reply(command, "\r\n+CSQ:4\r\n\r\nOK\r\n")
        case "AT+CSQF": reply(command, "\r\n+CSQF:\(csqf)\r\n\r\nOK\r\n")
        case "AT+SBDSX": reply(command, "\r\n\(sbdsxReply)\r\n\r\nOK\r\n")
        case "AT+SBDIX", "AT+SBDIXA": reply(command, "\r\n\(sbdixReply)\r\n\r\nOK\r\n")
        case "AT+SBDD0": reply(command, "\r\n0\r\n\r\nOK\r\n")
        case "AT+SBDD2":
            moWritten = nil
            mt = []
            reply(command, "\r\n0\r\n\r\nOK\r\n")
        case "AT+SBDTC":
            mt = moWritten ?? []
            reply(command, "\r\nSBDTC: Outbound SBD Copied to Inbound SBD: size = \(mt.count)\r\n\r\nOK\r\n")
        case "AT+SBDRB":
            let sum = mt.reduce(0, { $0 + Int($1) }) & 0xFFFF
            let frame = [UInt8(mt.count >> 8), UInt8(mt.count & 0xFF)] + mt + [UInt8(sum >> 8), UInt8(sum & 0xFF)]
            let echoed = echo ? Array((command + "\r").utf8) : []
            send(echoed + frame + Array("\r\nOK\r\n".utf8))
        default:
            if command.hasPrefix("AT+SBDWB=") {
                binaryLeft = Int(command.dropFirst("AT+SBDWB=".count))! + 2
                binary.removeAll()
                reply(command, "READY\r\n")
            } else {
                reply(command, "\r\nOK\r\n")
            }
        }
    }
}

final class IridiumATDriverTests: XCTestCase {
    let clock = VirtualClock()

    /// Attach and wait for the probe: the virtual clock only moves when the driver sleeps.
    func attached(_ modem: FakeModem, file: StaticString = #filePath, line: UInt = #line) async -> IridiumATDriver {
        let spp = IridiumATDriver(clock: clock)
        await spp.attach(modem)
        await waitUntil { await spp.state == .connected }
        let state = await spp.state
        XCTAssertEqual(state, .connected, file: file, line: line)
        return spp
    }

    /// The driver only advances when it sleeps on the virtual clock, one step per yield: a
    /// minute of modem silence is about 6,000 steps of 10 ms.
    func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<100_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    func testTheProbeTurnsFlowControlOffFirstAndReadsTheImeiThroughTheEcho() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        XCTAssertEqual(modem.commands.first, "AT&K0")
        XCTAssertLessThan(modem.commands.firstIndex(of: "ATE0")!, modem.commands.firstIndex(of: "AT+CGSN")!)
        XCTAssertTrue(modem.commands.contains("AT+SBDMTA=1"))
        let info = await spp.modemInfo
        XCTAssertEqual(info.imei, "300434067943980")
        XCTAssertEqual(info.manufacturer, "Iridium")
        XCTAssertTrue(modem.commands.contains("AT+CSQF"))
        let sig = await spp.signal
        XCTAssertEqual(sig, modem.csqf)
    }

    func testAPipeThatStopsTakingWritesTakesTheDriverOutOfConnected() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.writesFail = true
        for _ in 0..<IridiumATDriver.linkBrokenWrites { await spp.pollSignal() }
        let state = await spp.state
        XCTAssertEqual(state, .disconnected)
        let broken = await spp.linkBroken
        XCTAssertTrue(broken)
    }

    func testANodeUsingItsOwnModemIsAHandoverNotABrokenLink() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.notOurs = true
        for _ in 0..<(IridiumATDriver.linkBrokenWrites + 2) { await spp.pollSignal() }
        let broken = await spp.linkBroken
        XCTAssertFalse(broken)
        let state = await spp.state
        XCTAssertEqual(state, .connected)
    }

    func testAWriteThatLandsClearsAFailureBeforeItCountsAsBroken() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        for _ in 0..<(IridiumATDriver.linkBrokenWrites - 1) {
            modem.writesFail = true
            await spp.pollSignal()
            modem.writesFail = false
            await spp.pollSignal()
        }
        let state = await spp.state
        XCTAssertEqual(state, .connected)
        let broken = await spp.linkBroken
        XCTAssertFalse(broken)
    }

    func testAModemStillPoweringUpIsAskedAgainUntilItAnswersThenProbed() async {
        let modem = FakeModem()
        modem.silentFor = 3
        let spp = await attached(modem)
        XCTAssertEqual(Array(modem.commands.prefix(4)), ["AT&K0", "AT&K0", "AT&K0", "AT&K0"])
        let info = await spp.modemInfo
        XCTAssertEqual(info.imei, "300434067943980")
        let silent = await spp.modemSilent
        XCTAssertFalse(silent)
    }

    func testANodeWithoutAModemIsNeverReportedConnectedAndDetachStopsTheChecks() async {
        let modem = FakeModem()
        modem.silentFor = Int.max
        let spp = IridiumATDriver(clock: clock)
        await spp.attach(modem)
        await waitUntil { await spp.modemSilent }
        let silent = await spp.modemSilent
        XCTAssertTrue(silent)
        let state = await spp.state
        XCTAssertEqual(state, .connecting)
        XCTAssertTrue(modem.commands.allSatisfy { $0 == "AT&K0" })
        await spp.detach()
        for _ in 0..<200 { await clock.sleep(ms: 1000) }
        let sent = modem.commands.count
        for _ in 0..<200 { await clock.sleep(ms: 1000) }
        XCTAssertEqual(modem.commands.count, sent)
        let silentAfter = await spp.modemSilent
        XCTAssertFalse(silentAfter)
    }

    func testASessionThatBringsAMessageInHandsItOverAtOnceWhateverStartedIt() async throws {
        let modem = FakeModem()
        modem.sbdixReply = "+SBDIX: 0, 220, 1, 7, 5, 0"
        modem.mt = Array("hello".utf8)
        let spp = await attached(modem)
        let got = Received()
        await spp.setMtSink { await got.add(String(decoding: $0, as: UTF8.self)) }
        let result = await spp.sbdix()
        let texts = await got.texts
        XCTAssertEqual(texts, ["hello"])
        XCTAssertEqual(String(decoding: try XCTUnwrap(result?.mt), as: UTF8.self), "hello")
        XCTAssertTrue(modem.commands.contains("AT+SBDRB"))
    }

    func testAMessageThatHasBeenHandedOverIsDroppedFromTheModem() async {
        let modem = FakeModem()
        modem.sbdixReply = "+SBDIX: 0, 220, 1, 7, 5, 0"
        modem.mt = Array("hello".utf8)
        let spp = await attached(modem)
        await spp.setMtSink { _ in }
        _ = await spp.sbdix()
        XCTAssertTrue(modem.commands.contains("AT+SBDD1"), "MESHSAT-1266")
    }

    func testAMessageThatCouldNotBeStoredStaysInTheModem() async {
        let modem = FakeModem()
        modem.sbdixReply = "+SBDIX: 0, 221, 1, 7, 5, 0"
        modem.mt = Array("keep me".utf8)
        let spp = await attached(modem)
        await spp.setMtSink { _ in throw IridiumDriverError.protocolError("database is gone") }
        _ = await spp.sbdix()
        XCTAssertFalse(modem.commands.contains("AT+SBDD1"))
    }

    func testSbdwbSendsThePayloadWithItsChecksumBinarySafe() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        let payload: [UInt8] = [0x00, 0x0D, 0x0A, 0xFF, 0x94, 0xC3] + (0..<94).map { UInt8($0) }
        let ok = await spp.writeMoBuffer(payload)
        XCTAssertTrue(ok)
        XCTAssertEqual(modem.moWritten, payload)
    }

    func testSbdrbReturnsTheMtBytesWithAndWithoutEcho() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.mt = [0x21, 0x0D, 0x0A, 0x00, 0x4F, 0x4B]
        var got = await spp.readMtBinary()
        XCTAssertEqual(got, modem.mt)
        modem.echo = true
        got = await spp.readMtBinary()
        XCTAssertEqual(got, modem.mt)
        modem.mt = []
        got = await spp.readMtBinary()
        XCTAssertEqual(got, [])
        let text = await spp.readMtBuffer()
        XCTAssertNil(text)
    }

    func testEverySbdixClearsTheMoBufferSentOrNot() async throws {
        let modem = FakeModem()
        let spp = await attached(modem)
        let resultRaw = await spp.sbdix()
        let result = try XCTUnwrap(resultRaw)
        XCTAssertTrue(result.moSuccess)
        XCTAssertEqual(modem.commands.last, "AT+SBDD0")
        // Left in the modem after a failed session, the message went out with the next mailbox
        // check and again on the queue's retry (19 Sep, MOMSN 228 and 229).
        clock.advance(ms: IridiumATDriver.sbdixHoldMs)
        modem.sbdixReply = "+SBDIX: 32, 229, 2, 0, 0, 0"
        let failedRaw = await spp.sbdix()
        let failed = try XCTUnwrap(failedRaw)
        XCTAssertEqual(failed.moStatus, 32)
        XCTAssertEqual(modem.commands.last, "AT+SBDD0")
    }

    func testAZeroFromCsqfIsConfirmedWithAFreshCsqAtMostOnceAMinute() async {
        let modem = FakeModem()
        modem.csqf = 0
        let spp = await attached(modem)
        // The probe's own reading used this minute's confirmation.
        clock.advance(ms: 60_000)
        modem.clearCommands()
        var sig = await spp.pollSignal()
        XCTAssertEqual(sig, 4)
        XCTAssertEqual(modem.commands, ["AT+CSQF", "AT+CSQ"])

        modem.clearCommands()
        sig = await spp.pollSignal()
        XCTAssertEqual(sig, 0)
        XCTAssertEqual(modem.commands, ["AT+CSQF"])

        clock.advance(ms: 60_000)
        modem.clearCommands()
        sig = await spp.pollSignal()
        XCTAssertEqual(sig, 4)
        XCTAssertEqual(modem.commands, ["AT+CSQF", "AT+CSQ"])
    }

    func testASessionThatAnswersARingAlertIsAnSbdixa() async throws {
        let modem = FakeModem()
        let spp = await attached(modem)
        let resultRaw = await spp.sbdix(answeringRing: true)
        let result = try XCTUnwrap(resultRaw)
        XCTAssertTrue(result.moSuccess)
        XCTAssertTrue(modem.commands.contains("AT+SBDIXA"))
        XCTAssertFalse(modem.commands.contains("AT+SBDIX"))
    }

    func testTheRegularSignalReadIsCsqfAFreshOneCsqAndEveryReadingIsReported() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        let stream = spp.signalReadings.subscribe()
        modem.clearCommands()
        var readings = [Int]()
        var it = stream.makeAsyncIterator()
        // A repeated value is reported again: a StateFlow would swallow it, and with it the cue to send.
        var sig = await spp.pollSignal()
        XCTAssertEqual(sig, 2)
        readings.append(await it.next()!)
        sig = await spp.pollSignal()
        XCTAssertEqual(sig, 2)
        readings.append(await it.next()!)
        XCTAssertEqual(modem.commands, ["AT+CSQF", "AT+CSQF"])
        sig = await spp.pollSignal(fresh: true)
        XCTAssertEqual(sig, 4)
        XCTAssertEqual(modem.commands.last, "AT+CSQ")
        readings.append(await it.next()!)
        XCTAssertEqual(readings, [2, 2, 4])
    }

    func testAfterStatus32NoSbdixGoesOutForThreeMinutes() async throws {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.sbdixReply = "+SBDIX: 32, 218, 0, 0, 0, 0"
        let firstRaw = await spp.sbdix()
        let first = try XCTUnwrap(firstRaw)
        XCTAssertEqual(first.moStatus, 32)
        let sent = modem.commands.filter { $0 == "AT+SBDIX" }.count

        let held = await spp.sbdix()
        XCTAssertNil(held)
        XCTAssertEqual(modem.commands.filter { $0 == "AT+SBDIX" }.count, sent)

        clock.advance(ms: IridiumATDriver.sbdixHoldMs)
        modem.sbdixReply = "+SBDIX: 0, 219, 0, 0, 0, 0"
        let againRaw = await spp.sbdix()
        let again = try XCTUnwrap(againRaw)
        XCTAssertTrue(again.moSuccess)
        XCTAssertEqual(modem.commands.filter { $0 == "AT+SBDIX" }.count, sent + 1)
    }

    func testAnUnsolicitedSbdringIsReportedWithoutSendingAnything() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        let stream = spp.ringAlerts.subscribe()
        let before = modem.commands.count
        modem.unsolicited("SBDRING\r\n")
        var it = stream.makeAsyncIterator()
        let rang = await it.next()
        XCTAssertNotNil(rang)
        XCTAssertEqual(modem.commands.count, before)
    }

    func testTheLoopbackRoundTripsBinaryThroughBothBuffersClearsThemAndNeverOpensASession() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        let ok = await spp.loopbackTest(size: 270)
        XCTAssertTrue(ok)
        XCTAssertTrue(modem.commands.contains("AT+SBDTC"))
        await waitUntil { modem.commands.last == "AT+SBDD2" }
        XCTAssertEqual(modem.commands.last, "AT+SBDD2")
        XCTAssertFalse(modem.commands.contains("AT+SBDIX"))
        XCTAssertNil(modem.moWritten)
    }

    func testAnEmptyMailboxCheckIsOneSessionAndReportsNoMessages() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        let got = Received()
        let result = await spp.checkMailbox { await got.add(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(result, .checked(received: 0, stillQueued: 0))
        XCTAssertEqual(modem.commands.filter { $0 == "AT+SBDIX" }.count, 1)
        let texts = await got.texts
        XCTAssertTrue(texts.isEmpty)
    }

    func testAWaitingMtIsFetchedAndHandedOverAndWhatStillWaitsIsReported() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.sbdixReply = "+SBDIX: 0, 219, 1, 7, 5, 2"
        modem.mt = Array("hello".utf8)
        let got = Received()
        let result = await spp.checkMailbox { await got.add(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(result, .checked(received: 1, stillQueued: 2))
        let texts = await got.texts
        XCTAssertEqual(texts, ["hello"])
    }

    func testAnMtAlreadyInTheBufferIsReadForFreeAndALeftOverMoIsClearedNeverSent() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.sbdsxReply = "+SBDSX: 1, 218, 1, 6, 0, 0"
        modem.mt = Array("earlier".utf8)
        let got = Received()
        let result = await spp.checkMailbox { await got.add(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(result, .checked(received: 1, stillQueued: 0))
        let texts = await got.texts
        XCTAssertEqual(texts, ["earlier"])
        let rb = modem.commands.firstIndex(of: "AT+SBDRB")!
        let ix = modem.commands.firstIndex(of: "AT+SBDIX")!
        XCTAssertLessThan(rb, ix)
        // Outgoing messages are the delivery queue's: the check empties the MO buffer first.
        let d0 = modem.commands.firstIndex(of: "AT+SBDD0")!
        XCTAssertLessThan(d0, ix)
    }

    func testNoNetworkIsReportedAndTheNextCheckWithinTheHoldSendsNothing() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        modem.sbdixReply = "+SBDIX: 32, 218, 0, 0, 0, 0"
        let failed = await spp.checkMailbox { _ in }
        XCTAssertEqual(failed, .sessionFailed(moStatus: 32))
        let sessions = modem.commands.filter { $0 == "AT+SBDIX" }.count
        let held = await spp.checkMailbox { _ in }
        if case .held(let seconds) = held {
            XCTAssertGreaterThan(seconds, 0)
        } else {
            XCTFail("expected held, got \(held)")
        }
        XCTAssertEqual(modem.commands.filter { $0 == "AT+SBDIX" }.count, sessions)
    }

    func testAMailboxCheckWithoutTheModemSendsNothing() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        await spp.detach()
        let before = modem.commands.count
        let result = await spp.checkMailbox { _ in }
        XCTAssertEqual(result, .notConnected)
        XCTAssertEqual(modem.commands.count, before)
    }

    func testAfterDetachNothingIsSent() async {
        let modem = FakeModem()
        let spp = await attached(modem)
        await spp.detach()
        let before = modem.commands.count
        let session = await spp.sbdix()
        XCTAssertNil(session)
        let wrote = await spp.writeMoBuffer([1])
        XCTAssertFalse(wrote)
        XCTAssertEqual(modem.commands.count, before)
    }
}

actor Received {
    var texts: [String] = []
    func add(_ t: String) { texts.append(t) }
}
