// Mirrors rnode/RnodeDriverTest.kt and FakeRnode.kt (the Bridge's driver_test.go): the RNode driver
// against a software RNode (MESHSAT-1553 P4, here MESHSAT-1735).
import Foundation
import MeshSatNet
import XCTest

@testable import MeshSatRns

/// A software RNode, the twin of scripts/fake_rnode.py: answers the host protocol of RNode firmware
/// 1.75 (detect, firmware version, platform, MCU, configuration echo, READY flow control), and every
/// data frame written to one side is delivered as a data frame on its peer. Replies arrive on their
/// own queue, as a real link's do.
final class FakeRnode: RnodeLink, @unchecked Sendable {
    let name: String
    private let readyAfterData: Bool
    private let firmware: (UInt8, UInt8)
    private let answerDetect: Bool
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let splitter = Kiss.Splitter()
    weak var peer: FakeRnode?
    var onBytes: (@Sendable ([UInt8]) -> Void)?
    private var frames: [Kiss.Frame] = []
    private var isClosed = false

    init(_ name: String, ready: Bool = true, firmware: (UInt8, UInt8) = (1, 75), answerDetect: Bool = true) {
        self.name = name
        self.readyAfterData = ready
        self.firmware = firmware
        self.answerDetect = answerDetect
        queue = DispatchQueue(label: "fake-rnode-\(name)")
    }

    var written: [Kiss.Frame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// Injected device-side frames, e.g. an error or a reset.
    func emit(_ cmd: UInt8, _ payload: [UInt8]) { deliver(Kiss.encode(cmd, payload)) }

    fileprivate func deliver(_ b: [UInt8]) {
        queue.async { [weak self] in self?.onBytes?(b) }
    }

    func write(_ b: [UInt8]) throws {
        lock.lock()
        let closed = isClosed
        let got = closed ? [] : splitter.feed(b, nowMs: 0)
        frames += got
        lock.unlock()
        if closed { throw ByteStreamError.closed }
        for f in got { handle(f) }
    }

    private func handle(_ f: Kiss.Frame) {
        let p = f.payload
        switch f.cmd {
        case RnodeProtocol.cmdDetect:
            if answerDetect, p.first == RnodeProtocol.detectReq {
                deliver(Kiss.encode(RnodeProtocol.cmdDetect, [RnodeProtocol.detectResp]))
            }
        case RnodeProtocol.cmdFwVersion: deliver(Kiss.encode(RnodeProtocol.cmdFwVersion, [firmware.0, firmware.1]))
        case RnodeProtocol.cmdPlatform: deliver(Kiss.encode(RnodeProtocol.cmdPlatform, [RnodeProtocol.platformEsp32]))
        case RnodeProtocol.cmdMcu: deliver(Kiss.encode(RnodeProtocol.cmdMcu, [0x81]))
        case RnodeProtocol.cmdFrequency, RnodeProtocol.cmdBandwidth, RnodeProtocol.cmdTxPower, RnodeProtocol.cmdSf, RnodeProtocol.cmdCr,
            RnodeProtocol.cmdRadioState, RnodeProtocol.cmdStALock, RnodeProtocol.cmdLtALock:
            deliver(Kiss.encode(f.cmd, p))
        case RnodeProtocol.cmdData:
            peer?.deliver(Kiss.encode(RnodeProtocol.cmdData, p))
            if readyAfterData { deliver(Kiss.encode(RnodeProtocol.cmdReady, [1])) }
        default: break
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }
}

/// The driver's 2 s settle and 2 s BLE pause shortened, real time otherwise (the fake answers on a queue).
private struct QuickClock: DriverClock {
    func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func sleep(ms: Int64) async { try? await Task.sleep(nanoseconds: UInt64(min(ms, 50)) * 1_000_000) }
}

/// Packets and errors a test waits for.
private final class Inbox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ t: T) {
        lock.lock()
        items.append(t)
        lock.unlock()
    }

    func next(within ms: Int) async -> T? {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < deadline {
            if let t = take() { return t }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return take()
    }

    private func take() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

final class RnodeDriverTests: XCTestCase {
    private let eu = RnodeProtocol.preset("eu-868")!.params

    private func driver(
        _ name: String, _ link: FakeRnode, packets: Inbox<[UInt8]>? = nil, errors: Inbox<String>? = nil,
        transport: RnodeDriver.Transport = .serial
    ) -> RnodeDriver {
        let d = RnodeDriver(
            link: link,
            options: RnodeDriver.Options(
                name: name, transport: transport, params: eu, onPacket: { packets?.add($0) }, onError: { errors?.add($0) },
                clock: QuickClock()))
        link.onBytes = { [weak d] in d?.feed($0) }
        return d
    }

    private func pair() -> (FakeRnode, FakeRnode) {
        let a = FakeRnode("A")
        let b = FakeRnode("B")
        a.peer = b
        b.peer = a
        return (a, b)
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testKissRoundTrip() {
        let payload: [UInt8] = [1, Kiss.fend, 2, Kiss.fesc, 3]
        let frame = Kiss.encode(RnodeProtocol.cmdData, payload)
        XCTAssertEqual(frame.first, Kiss.fend)
        XCTAssertEqual(frame.last, Kiss.fend)
        XCTAssertEqual(frame.count, payload.count + 2 + 3)
        let frames = Kiss.Splitter().feed(frame + frame, nowMs: 0)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload, payload)
        XCTAssertEqual(frames[0].cmd, 0)
        let s = Kiss.Splitter()
        XCTAssertTrue(s.feed(Array(frame[0..<3]), nowMs: 0).isEmpty)
        XCTAssertEqual(s.feed(Array(frame[3...]), nowMs: 1).count, 1)
        let t = Kiss.Splitter(maxLen: 600, timeoutMs: 100)
        XCTAssertTrue(t.feed(Array(frame[0..<3]), nowMs: 0).isEmpty)
        XCTAssertEqual(t.feed(frame, nowMs: 1000).count, 1)
    }

    func testCommandEncoders() {
        XCTAssertEqual(hex(RnodeProtocol.detectBurst()), "c00873c05000c04800c04900c0")
        XCTAssertEqual(hex(RnodeProtocol.setFrequency(867_200_000)), "c00133b06c00c0")
        XCTAssertEqual(hex(RnodeProtocol.setBandwidth(0xC000)), "c0020000dbdc00c0")
        XCTAssertEqual(hex(RnodeProtocol.setStaLock(10.0)), "c00b03e8c0")
        XCTAssertEqual(RnodeProtocol.bitrate(sf: 8, cr: 5, bw: 125_000), 3125.0, accuracy: 0.001)
        XCTAssertEqual(eu.bitrate(), RnodeProtocol.bitrate(sf: 8, cr: 5, bw: 125_000), accuracy: 0.001)
        XCTAssertNotNil(RnodeProtocol.Params(frequency: 100_000_000, bandwidth: 125_000, txPower: 14, sf: 8, cr: 5).validate())
        XCTAssertNotNil(RnodeProtocol.Params(frequency: 867_200_000, bandwidth: 125_000, txPower: 40, sf: 8, cr: 5).validate())
        XCTAssertNil(eu.validate())
    }

    func testOpensConfiguresAndExchangesPackets() async throws {
        let (a, b) = pair()
        let gotA = Inbox<[UInt8]>()
        let gotB = Inbox<[UInt8]>()
        let da = driver("A", a, packets: gotA)
        let db = driver("B", b, packets: gotB)
        let openA = await da.open()
        let openB = await db.open()
        XCTAssertNil(openA)
        XCTAssertNil(openB)
        XCTAssertTrue(da.online && db.online)
        let st = da.currentStats()
        XCTAssertEqual(st.frequency, 867_200_000)
        XCTAssertEqual(st.sf, 8)
        XCTAssertTrue(st.radioOn)
        XCTAssertTrue(st.detected)
        XCTAssertEqual(st.firmware, "1.75")
        XCTAssertEqual(st.platform, RnodeProtocol.platformEsp32)
        XCTAssertNil(da.send(Array("hello B".utf8)))
        let toB = await gotB.next(within: 2000)
        XCTAssertEqual(toB.map { String(decoding: $0, as: UTF8.self) }, "hello B")
        XCTAssertNil(db.send(Array("hello A".utf8)))
        let toA = await gotA.next(within: 2000)
        XCTAssertEqual(toA.map { String(decoding: $0, as: UTF8.self) }, "hello A")
        XCTAssertEqual(da.currentStats().txPackets, 1)
        XCTAssertEqual(da.currentStats().rxPackets, 1)
        // The configuration went out in order, then the radio was switched on.
        let cmds = a.written.map(\.cmd)
        let i = try XCTUnwrap(cmds.firstIndex(of: RnodeProtocol.cmdFrequency))
        XCTAssertEqual(
            Array(cmds[i..<i + 6]),
            [
                RnodeProtocol.cmdFrequency, RnodeProtocol.cmdBandwidth, RnodeProtocol.cmdTxPower, RnodeProtocol.cmdSf, RnodeProtocol.cmdCr,
                RnodeProtocol.cmdRadioState,
            ])
        da.close()
        XCTAssertFalse(da.online)
        XCTAssertEqual(a.written.suffix(2).map(\.cmd), [RnodeProtocol.cmdRadioState, RnodeProtocol.cmdLeave])
    }

    func testFlowControlQueuesUntilReady() async {
        let a = FakeRnode("A", ready: false)
        let b = FakeRnode("B")
        a.peer = b
        b.peer = a
        let gotB = Inbox<[UInt8]>()
        let da = driver("A", a)
        let db = driver("B", b, packets: gotB)
        let openA = await da.open()
        let openB = await db.open()
        XCTAssertNil(openA)
        XCTAssertNil(openB)
        XCTAssertNil(da.send(Array("one".utf8)))
        XCTAssertNil(da.send(Array("two".utf8)))  // queued: no READY came back for "one"
        let first = await gotB.next(within: 2000)
        XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, "one")
        let early = await gotB.next(within: 300)
        XCTAssertNil(early)
        a.emit(RnodeProtocol.cmdReady, [1])
        let second = await gotB.next(within: 2000)
        XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, "two")
        XCTAssertEqual(da.currentStats().txPackets, 2)
    }

    func testRefusesOldFirmwareAndSilence() async {
        let old = FakeRnode("old", firmware: (1, 40))
        let d1 = driver("old", old)
        let why1 = await d1.open()
        XCTAssertTrue(why1?.contains("older than") == true, why1 ?? "nil")
        let mute = FakeRnode("mute", answerDetect: false)
        let d2 = driver("mute", mute)
        let why2 = await d2.open()
        XCTAssertEqual(why2, "device not detected")
        XCTAssertFalse(d2.online)
    }

    func testHardwareErrorAndResetReachTheOwner() async {
        let (a, b) = pair()
        let errs = Inbox<String>()
        let da = driver("A", a, errors: errs)
        let db = driver("B", b)
        let openA = await da.open()
        let openB = await db.open()
        XCTAssertNil(openA)
        XCTAssertNil(openB)
        a.emit(RnodeProtocol.cmdError, [RnodeProtocol.errorMemoryLow])  // non-fatal: logged only
        let none = await errs.next(within: 300)
        XCTAssertNil(none)
        a.emit(RnodeProtocol.cmdError, [RnodeProtocol.errorTxFailed])
        let tx = await errs.next(within: 2000)
        XCTAssertTrue(tx?.contains("transmit failure") == true)
        a.emit(RnodeProtocol.cmdReset, [RnodeProtocol.resetMagic])
        let reset = await errs.next(within: 2000)
        XCTAssertTrue(reset?.contains("reset") == true)
        XCTAssertFalse(da.online)
        XCTAssertNotNil(da.send(Array("x".utf8)))
    }
}
