// Mirrors DeliveryWorkerRoomTest.kt (review 2026-10-18 23:31, FE-R4, MESHSAT-1584): a
// confirmation that commits while a send is out (before its outcome, at the old gap between "sent"
// and the ACK wait, or while a later send is in flight) leaves the delivery confirmed, and nothing
// selects it to be sent again. The store is FakeDeliveryStore in its live mode, which keeps the
// guards of MessageDeliveryDao's SQL; the SQL itself is checked in MeshSatAppleTests.
import Foundation
import MeshSatEngine
import MeshSatNet
import XCTest

final class DeliveryWorkerTests: XCTestCase {
    private func row(_ id: Int64, status: String = "queued", retries: Int = 0, maxRetries: Int = 3, ack: String? = nil) -> MessageDelivery {
        MessageDelivery(
            id: id, msgRef: "msg:\(id)", channel: "iridium_0", status: status, textPreview: "x", retries: retries,
            maxRetries: maxRetries, qosLevel: 1, ackStatus: ack, createdAt: 1, updatedAt: 1)
    }

    private func waitUntil(_ timeoutMs: Int = 5_000, _ cond: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func make(_ store: FakeDeliveryStore, deliver: @escaping Dispatcher.DeliveryCallback) -> Dispatcher {
        let rules = EmptyRules()
        return Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil,
            registry: ChannelRegistry(), deliveryCallback: deliver, pollIntervalMs: 20)
    }

    /// Waits until the worker has started `more` batches after `seen`: the send before them returned.
    private func afterBatches(_ store: FakeDeliveryStore, _ seen: Int, more: Int = 1) async -> Bool {
        await waitUntil { store.batches >= seen + more }
    }

    private func state(_ store: FakeDeliveryStore, _ id: Int64) -> String {
        guard let r = store.row(id) else { return "missing" }
        return "\(r.status)/\(r.ackStatus ?? "nil")"
    }

    func testAConfirmationWhileTheSendIsOutStaysAfterItReturns() async {
        let store = FakeDeliveryStore(rows: [row(1)])
        store.live = true
        let out = Gate()
        let release = Gate()
        let dispatcher = make(store) { _, _, _, _, _, _ in
            await out.open()
            await release.wait()
            return nil
        }
        dispatcher.startWorker("iridium_0")
        await out.wait()
        let seen = store.batches
        try? await store.setAcked(id: 1, now: 2)
        await release.open()
        let returned = await afterBatches(store, seen)
        XCTAssertTrue(returned)
        XCTAssertEqual(state(store, 1), "delivered/acked")
        XCTAssertFalse(store.log.contains("ackPending:1"), "\(store.log)")
        dispatcher.stop()
    }

    func testAConfirmationAtTheOldGapBetweenSentAndTheAckWaitStays() async {
        // onSent runs where the old worker had written "sent" and not yet the ACK wait.
        let store = FakeDeliveryStore(rows: [row(1)])
        store.live = true
        let dispatcher = make(store) { _, _, _, _, _, _ in nil }
        dispatcher.setOnSent { del in try? await store.setAcked(id: del.id ?? 0, now: 2) }
        dispatcher.startWorker("iridium_0")
        let acked = await waitUntil { store.log.contains("acked:1") }
        XCTAssertTrue(acked)
        let returned = await afterBatches(store, store.batches)
        XCTAssertTrue(returned)
        XCTAssertEqual(state(store, 1), "delivered/acked")
        dispatcher.stop()
    }

    private func earlierSendConfirmsWhileALaterOneFails(retriesBefore: Int) async {
        let store = FakeDeliveryStore(rows: [row(1, status: "retry", retries: retriesBefore)])
        store.live = true
        let sends = Changes()
        let out = Gate()
        let release = Gate()
        let dispatcher = make(store) { _, _, text, _, _, _ in
            sends.add(text)
            await out.open()
            await release.wait()
            return "Not sent: the modem gave no readable answer"
        }
        dispatcher.startWorker("iridium_0")
        await out.wait()
        let seen = store.batches
        try? await store.setAcked(id: 1, now: 2)  // the earlier send's confirmation
        await release.open()
        let returned = await afterBatches(store, seen, more: 2)
        XCTAssertTrue(returned)
        XCTAssertEqual(state(store, 1), "delivered/acked")
        XCTAssertEqual(store.row(1)?.retries, retriesBefore)
        XCTAssertEqual(sends.list.count, 1)
        dispatcher.stop()
    }

    /// MESHSAT-1670: retries already past maxRetries, so a 9603 failure would be dropped here.
    func testA9704SendThatSawNoSatelliteIsRetriedWithinAMinuteAndNeverUsedUp() async {
        let store = FakeDeliveryStore(rows: [row(11, retries: 5, maxRetries: 3)])
        store.live = true
        let dispatcher = make(store) { _, _, _, _, _, _ in "9704 MO failed: cancelled" }
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        dispatcher.startWorker("iridium_0")
        let settled = await waitUntil { store.log.contains("retry:11") || store.log.contains("status:11:dead") }
        dispatcher.stop()
        XCTAssertTrue(settled, "\(store.log)")
        XCTAssertFalse(store.log.contains("status:11:dead"), "a 9704 miss must not be dropped by the retry limit")
        let wait = (store.row(11)?.nextRetry ?? 0) - before
        XCTAssertTrue((55_000...65_000).contains(wait), "retry in about a minute, was \(wait) ms")
    }

    func testALaterSendThatFailsDoesNotRetryAConfirmedDelivery() async {
        await earlierSendConfirmsWhileALaterOneFails(retriesBefore: 1)
    }

    func testALaterSendThatFailsOnItsLastTryDoesNotDropAConfirmedDelivery() async {
        await earlierSendConfirmsWhileALaterOneFails(retriesBefore: 2)
    }

    func testAConfirmationJustBeforeTheClaimMeansNoSend() async {
        let store = FakeDeliveryStore(rows: [row(1)])
        store.live = true
        let sends = Changes()
        let dispatcher = make(store) { _, _, text, _, _, _ in
            sends.add(text)
            return nil
        }
        // mayDeliver runs after the worker read the row and before it takes it.
        dispatcher.setMayDeliver { del in
            try? await store.setAcked(id: del.id ?? 0, now: 2)
            return true
        }
        dispatcher.startWorker("iridium_0")
        let refused = await waitUntil { store.log.contains("refused:status:1:sending:1") }
        XCTAssertTrue(refused, "\(store.log)")
        let returned = await afterBatches(store, store.batches)
        XCTAssertTrue(returned)
        XCTAssertEqual(sends.list, [])
        XCTAssertEqual(state(store, 1), "delivered/acked")
        dispatcher.stop()
    }

    func testAConfirmedDeliveryAnOlderWorkerLeftWaitingIsNotSentAgain() async {
        let store = FakeDeliveryStore(rows: [row(1, status: "retry", ack: "acked")])
        store.live = true
        let pending = try? await store.getPending(channel: "iridium_0", now: 10, limit: 10)
        XCTAssertEqual(pending?.count, 0)
        let sends = Changes()
        let dispatcher = make(store) { _, _, text, _, _, _ in
            sends.add(text)
            return nil
        }
        dispatcher.start(interfaces: ["iridium_0": "iridium"])
        let returned = await afterBatches(store, 1, more: 2)
        XCTAssertTrue(returned)
        XCTAssertEqual(sends.list, [])
        XCTAssertEqual(state(store, 1), "sent/acked")
        dispatcher.stop()
    }

    func testNoWorkerSendsBeforeTheStartupRepairIsDone() async {
        let store = FakeDeliveryStore(rows: [row(1)])
        store.live = true
        let gate = Gate()
        store.recoverGate = gate
        let dispatcher = make(store) { _, _, _, _, _, _ in nil }
        dispatcher.start(interfaces: ["iridium_0": "iridium"])
        let recovering = await waitUntil { store.log.contains("recover") }
        XCTAssertTrue(recovering)
        try? await Task.sleep(for: .milliseconds(300))  // fifteen polls
        XCTAssertEqual(store.batches, 0, "\(store.log)")
        await gate.open()
        let sent = await waitUntil { store.log.contains("status:1:sent") }
        XCTAssertTrue(sent, "\(store.log)")
        dispatcher.stop()
    }
}
