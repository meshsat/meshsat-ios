// The pipe's claim, release and routing rules (MESHSAT-1236, MESHSAT-1270) against a scripted
// link: what IridiumBlePipe.kt does with STATUS, TX and RX, without a radio.
import MeshSatMeshtastic
import XCTest

/// A node's pipe service as the GATT client sees it: three characteristics, scripted answers.
final class FakePipeLink: IridiumPipeLink, @unchecked Sendable {
    private let lock = NSLock()
    var hasRx = true
    var hasTx = true
    var hasStatus = true
    var mtuPayload = 244
    /// Refuse the first N descriptor writes (the link is still being encrypted).
    var refuseNotifies = 0
    /// What STATUS answers to a read; nil answers nothing.
    var statusOwner: IridiumPipeContract.Owner? = .phone
    var writeStatus = GattOpQueue.statusSuccess
    private(set) var notifies: [(String, Bool)] = []
    private(set) var written: [[UInt8]] = []
    weak var pipe: IridiumBlePipe?

    func chunkSize() -> Int { mtuPayload }

    func write(uuid: String, _ chunk: [UInt8]) async -> Int {
        XCTAssertEqual(uuid, IridiumPipeContract.rxUUID)
        return recordWrite(chunk)
    }

    private func recordWrite(_ chunk: [UInt8]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        written.append(chunk)
        return writeStatus
    }

    func setNotify(uuid: String, on: Bool) async -> Int {
        recordNotify(uuid, on) ? 133 : GattOpQueue.statusSuccess
    }

    /// True when this one is refused.
    private func recordNotify(_ uuid: String, _ on: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        notifies.append((uuid, on))
        let refuse = refuseNotifies > 0
        if refuse { refuseNotifies -= 1 }
        return refuse
    }

    func read(uuid: String) {
        XCTAssertEqual(uuid, IridiumPipeContract.statusUUID)
        guard let owner = statusOwner else { return }
        pipe?.onValue(uuid: uuid, [IridiumPipeContract.statusVersion, owner.rawValue])
    }
}

final class IridiumBlePipeTests: XCTestCase {
    private func make(_ setup: (FakePipeLink) -> Void = { _ in }) -> (IridiumBlePipe, FakePipeLink) {
        let link = FakePipeLink()
        setup(link)
        let pipe = IridiumBlePipe(link: link)
        link.pipe = pipe
        return (pipe, link)
    }

    func testClaimSubscribesStatusThenTxAndReadsStatus() async {
        let (pipe, link) = make()
        let ok = await pipe.claim(timeoutMs: 1_000)
        XCTAssertTrue(ok)
        XCTAssertEqual(link.notifies.map(\.0), [IridiumPipeContract.statusUUID, IridiumPipeContract.txUUID])
        XCTAssertEqual(pipe.owner.value, .phone)
    }

    func testClaimRetriesOnceWhenTheFirstDescriptorWriteFails() async {
        let (pipe, link) = make { $0.refuseNotifies = 1 }
        let ok = await pipe.claim(timeoutMs: 1_000)
        XCTAssertTrue(ok)
        XCTAssertEqual(link.notifies.count, 3, "STATUS refused once, then STATUS and TX")
    }

    func testClaimFailsWhenTxCannotBeSubscribed() async {
        let (pipe, link) = make {
            $0.hasStatus = false
            $0.refuseNotifies = 2
        }
        let ok = await pipe.claim(timeoutMs: 1_000)
        XCTAssertFalse(ok)
        XCTAssertEqual(link.notifies.count, 2)
        XCTAssertNil(pipe.owner.value)
    }

    func testANodeThatHoldsItsModemAnswersNodeAndTheClaimFails() async {
        let (pipe, _) = make { $0.statusOwner = .node }
        let ok = await pipe.claim(timeoutMs: 1_000)
        XCTAssertFalse(ok)
        XCTAssertEqual(pipe.owner.value, .node)
    }

    func testNothingAnsweringTimesOut() async {
        let (pipe, _) = make { $0.statusOwner = nil }
        let started = Date()
        let ok = await pipe.claim(timeoutMs: 200)
        XCTAssertFalse(ok)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
        XCTAssertNil(pipe.owner.value)
    }

    func testANodeWithoutStatusIsOwnedOnceTxIsSubscribed() async {
        let (pipe, link) = make { $0.hasStatus = false }
        let ok = await pipe.claim(timeoutMs: 1_000)
        XCTAssertTrue(ok)
        XCTAssertEqual(link.notifies.map(\.0), [IridiumPipeContract.txUUID])
        await pipe.release()
        XCTAssertEqual(pipe.owner.value, IridiumPipeContract.Owner.none)
        XCTAssertEqual(link.notifies.last?.1, false)
    }

    func testWritesGoToRxInChunksOnlyWhileThePhoneOwnsTheModem() async throws {
        let (pipe, link) = make { $0.mtuPayload = 20 }
        do {
            try await pipe.write(Array("AT\r".utf8))
            XCTFail("should refuse before the claim")
        } catch {
            XCTAssertEqual(error as? PipeError, .notOwned)
        }
        _ = await pipe.claim(timeoutMs: 1_000)
        let payload = (0..<45).map { UInt8($0) }
        try await pipe.write(payload)
        XCTAssertEqual(link.written.count, 3)
        XCTAssertEqual(link.written.flatMap { $0 }, payload)
    }

    func testAHandoverToTheNodeClearsWhatWasBufferedAndRefusesWrites() async {
        let (pipe, _) = make()
        _ = await pipe.claim(timeoutMs: 1_000)
        pipe.onValue(uuid: IridiumPipeContract.txUUID, Array("OK\r\n".utf8))
        XCTAssertEqual(pipe.input.available, 4)
        pipe.onValue(uuid: IridiumPipeContract.statusUUID, [1, IridiumPipeContract.Owner.node.rawValue])
        XCTAssertEqual(pipe.input.available, 0)
        do {
            try await pipe.write(Array("AT\r".utf8))
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? PipeError, .notOwned)
        }
    }

    func testAFailedChunkIsWriteFailedNotNotOwned() async {
        let (pipe, link) = make()
        _ = await pipe.claim(timeoutMs: 1_000)
        link.writeStatus = 133
        do {
            try await pipe.write(Array("AT\r".utf8))
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? PipeError, .writeFailed)
        }
        link.writeStatus = 0
        pipe.refuseWrites = true
        do {
            try await pipe.write(Array("AT\r".utf8))
            XCTFail("drill should fail")
        } catch {
            XCTAssertEqual(error as? PipeError, .writeFailed)
        }
    }

    func testTxBytesReachTheReceiverAndTheInputBuffer() async {
        let (pipe, _) = make()
        let seen = SentChunks()
        pipe.setReceiver { chunk in Task { _ = await seen.add(chunk) } }
        pipe.onValue(uuid: IridiumPipeContract.txUUID, Array("SBDRING\r".utf8))
        try? await Task.sleep(for: .milliseconds(50))
        let chunks = await seen.chunks
        XCTAssertEqual(chunks, [Array("SBDRING\r".utf8)])
        XCTAssertEqual(pipe.input.read(max: 16), Array("SBDRING\r".utf8))
        pipe.close()
        XCTAssertTrue(pipe.input.isClosed)
        XCTAssertNil(pipe.owner.value)
    }

    func testCharacteristicRouting() {
        XCTAssertTrue(IridiumBlePipe.isPipeCharacteristic(IridiumPipeContract.txUUID.uppercased()))
        XCTAssertTrue(IridiumBlePipe.isPipeCharacteristic(IridiumPipeContract.statusUUID))
        XCTAssertFalse(IridiumBlePipe.isPipeCharacteristic(IridiumPipeContract.rxUUID))
        XCTAssertFalse(IridiumBlePipe.isPipeCharacteristic(MeshtasticBleContract.fromRadioUUID))
    }
}
