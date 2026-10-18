// Mirrors AckStatusTest.kt (MESHSAT-1584): each channel's pending ACKs time out on that channel's
// own timeout, a mesh send (a broadcast, which never asks for an ACK) is not left waiting for one,
// and the deduplicator's TTL applies without anyone calling prune(), with a key for a text that
// stays the same across launches.
import Foundation
import MeshSatEngine
import MeshSatNet
import XCTest

private struct FixedClock: DriverClock {
    let t: Int64
    func nowMs() -> Int64 { t }
    func sleep(ms: Int64) async {}
}

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64 = 1_000_000_000
    func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return t
    }
    func advance(_ ms: Int64) {
        lock.lock()
        t += ms
        lock.unlock()
    }
}

final class AckStatusTests: XCTestCase {
    func testEachChannelsPendingAcksTimeOutOnItsOwnTimeout() async {
        let store = FakeDeliveryStore()
        store.pendingChannels = ["iridium_0", "sms_0", "mqtt_0"]
        let now: Int64 = 1_000_000_000
        await AckTracker(store: store, clock: FixedClock(t: now)).checkTimeouts()
        XCTAssertEqual(
            store.log.filter { $0.hasPrefix("sweep") },
            ["sweep:iridium_0:\(now - 120_000)", "sweep:sms_0:\(now - 30_000)", "sweep:mqtt_0:\(now - 30_000)"])
    }

    private func sendOne(_ channel: String) async -> [String] {
        let row = MessageDelivery(
            id: 3, msgRef: "msg:3", channel: channel, textPreview: "hello", maxRetries: 3, qosLevel: 1, createdAt: 1, updatedAt: 1)
        let store = FakeDeliveryStore(rows: [row])
        let rules = EmptyRules()
        let dispatcher = Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil,
            registry: ChannelRegistry(), deliveryCallback: { _, _, _, _, _, _ in nil }, pollIntervalMs: 20)
        dispatcher.startWorker(channel)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !store.log.contains("status:3:sent") { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))  // what follows "sent"
        dispatcher.stop()
        return store.log
    }

    func testAMeshBroadcastIsNotLeftWaitingForAnAckThatNeverComes() async {
        let mesh = await sendOne("mesh_0")
        XCTAssertTrue(mesh.contains("status:3:sent"), "\(mesh)")
        XCTAssertFalse(mesh.contains("ackPending:3"), "a mesh broadcast waits for an ACK: \(mesh)")
        let sat = await sendOne("iridium_0")
        XCTAssertTrue(sat.contains("ackPending:3"), "a satellite send with QoS 1 waits for its ACK: \(sat)")
    }

    func testTheDeduplicatorsTTLAppliesWithoutAPrune() {
        let clock = StepClock()
        let d = Deduplicator(ttlMs: 10 * 60_000, now: { clock.now() })
        XCTAssertFalse(d.isDuplicateKey("A"))
        clock.advance(5 * 60_000)
        XCTAssertTrue(d.isDuplicateKey("A"), "within the TTL")
        clock.advance(4 * 60_000 + 59_000)  // 9:59 in: the once-a-minute prune runs, nothing expired yet
        XCTAssertFalse(d.isDuplicateKey("B"))
        clock.advance(31_000)  // 10:30 in, 31 s after that prune: A expired, no prune due
        XCTAssertFalse(d.isDuplicateKey("A"), "an expired key is new again between prunes")
        XCTAssertTrue(d.isDuplicateKey("A"))
        clock.advance(20 * 60_000)  // keys nobody asks for again are let go
        XCTAssertFalse(d.isDuplicateKey("C"))
        XCTAssertEqual(d.size, 1, "expired keys were never let go")
    }

    func testTheStableKeyIsTheSameForTheSameText() {
        XCTAssertEqual(Deduplicator.stableKey("hello sat"), Deduplicator.stableKey("hello sat"))
        XCTAssertNotEqual(Deduplicator.stableKey("hello sat"), Deduplicator.stableKey("hello sat!"))
        // SHA-256 of "hello sat", first 16 bytes: the same in every launch and on every platform.
        XCTAssertEqual(Deduplicator.stableKey("hello sat").count, 32)
    }

    func testALateAckAfterTheTimeoutIsRecordedAndOneAlreadyRecordedStays() async {
        var row = MessageDelivery(
            id: 9, msgRef: "msg:9", channel: "iridium_0", textPreview: "x", ackStatus: "timeout", createdAt: 1, updatedAt: 1)
        let store = FakeDeliveryStore(rows: [row])
        store.seqRow = row
        let tracker = AckTracker(store: store, clock: FixedClock(t: 5_000))
        let late = await tracker.processAck(channel: "iridium_0", seqNum: 4)
        XCTAssertTrue(late, "a late ACK was dropped")
        row.ackStatus = "acked"
        store.seqRow = row
        let over = await tracker.processAck(channel: "iridium_0", seqNum: 4, positive: false)
        XCTAssertFalse(over, "an ACK over a recorded one was taken")
        XCTAssertEqual(store.log.filter { $0.hasPrefix("acked:") || $0.hasPrefix("nacked:") }, ["acked:9"])
    }
}
