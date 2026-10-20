// Mirrors DispatcherInFlightTest.kt: the satellite queue across interface state changes
// (MESHSAT-1243). A send that has started finishes and is recorded when its worker is stopped
// meanwhile; an interface coming online makes what waited for it due at once; "not now" waits
// without counting a try and stops the batch; a successful send wakes the channel's others.
import Foundation
import MeshSatEngine
import MeshSatNet
import XCTest

/// A delivery store answered from a script, recording what the dispatcher asked of it. Its worker
/// writes keep the guards of MessageDeliveryDao's SQL (FE-R4): a claim only of a waiting,
/// unconfirmed row, a send's outcome only while the row is 'sending'.
final class FakeDeliveryStore: DeliveryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Int64: MessageDelivery] = [:]
    private var pendingOnce: [MessageDelivery] = []
    private var served = false
    private var calls: [String] = []
    /// getPending answers from the rows as they are now, every time, as the SQL does (not once).
    var live = false

    init(rows: [MessageDelivery] = []) {
        for r in rows { self.rows[r.id ?? 0] = r }
        pendingOnce = rows
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var log: [String] { locked { calls } }
    func row(_ id: Int64) -> MessageDelivery? { locked { rows[id] } }
    /// Every row, by id.
    func all() -> [MessageDelivery] { locked { rows.keys.sorted().compactMap { rows[$0] } } }
    private func note(_ s: String) { locked { calls.append(s) } }

    /// An insert whose msg_ref ends so fails, as a database that refuses it (C10-R3).
    private var failSuffix: String?
    func failInserts(endingWith suffix: String?) { locked { failSuffix = suffix } }
    struct InjectedInsertFailure: Error {}

    func insert(_ delivery: MessageDelivery) async throws -> Int64 {
        if let suffix = locked({ failSuffix }), delivery.msgRef.hasSuffix(suffix) { throw InjectedInsertFailure() }
        return locked {
            let id = Int64(rows.count + 1)
            var d = delivery
            d.id = id
            rows[id] = d
            calls.append("insert:\(delivery.channel)")
            return id
        }
    }
    func getById(_ id: Int64) async throws -> MessageDelivery? { row(id) }
    private var pendingCalls = 0
    /// How many batches the worker has started (getPending calls).
    var batches: Int { locked { pendingCalls } }
    func getPending(channel: String, now: Int64, limit: Int) async throws -> [MessageDelivery] {
        locked {
            pendingCalls += 1
            if live {
                return rows.keys.sorted().compactMap { rows[$0] }.filter {
                    $0.channel == channel && ["queued", "retry"].contains($0.status) && ($0.nextRetry ?? 0) <= now
                        && $0.ackStatus != "acked"
                }
            }
            if served { return [] }
            served = true
            return pendingOnce.filter { $0.channel == channel }
        }
    }
    func setStatus(id: Int64, _ status: String, lastError: String, now: Int64) async throws {
        locked {
            rows[id]?.status = status
            rows[id]?.lastError = lastError
            calls.append("status:\(id):\(status)")
        }
    }
    /// Changes row `id` when `allowed` holds for it, as an UPDATE ... WHERE would; 1 or 0.
    private func update(
        _ id: Int64, _ what: String, when allowed: (MessageDelivery) -> Bool, _ change: (inout MessageDelivery) -> Void
    ) -> Int {
        locked {
            guard var r = rows[id], allowed(r) else {
                calls.append("refused:\(what):\(id)")
                return 0
            }
            change(&r)
            rows[id] = r
            calls.append(what)
            return 1
        }
    }
    private static func waiting(_ r: MessageDelivery) -> Bool { ["queued", "retry"].contains(r.status) && r.ackStatus != "acked" }
    private static func sending(_ r: MessageDelivery) -> Bool { r.status == "sending" }
    func claimForSend(id: Int64, now: Int64) async throws -> Int {
        update(id, "status:\(id):sending", when: Self.waiting) { $0.status = "sending" }
    }
    func markSent(id: Int64, seqNum: Int64, ackPending: Bool, now: Int64) async throws -> Int {
        let n = update(id, "status:\(id):sent", when: Self.sending) {
            $0.status = "sent"
            $0.seqNum = seqNum
            if ackPending && $0.ackStatus != "acked" { $0.ackStatus = "pending" }
        }
        if n > 0 {
            note("seq:\(id):\(seqNum)")
            if ackPending { note("ackPending:\(id)") }
        }
        return n
    }
    func dropWaiting(id: Int64, _ status: String, lastError: String, now: Int64) async throws -> Int {
        update(id, "status:\(id):\(status)", when: Self.waiting) {
            $0.status = status
            $0.lastError = lastError
        }
    }
    func finishSend(id: Int64, _ status: String, lastError: String, now: Int64) async throws -> Int {
        update(id, "status:\(id):\(status)", when: Self.sending) {
            $0.status = status
            $0.lastError = lastError
        }
    }
    func scheduleRetry(id: Int64, retries: Int, nextRetry: Int64, lastError: String, now: Int64) async throws -> Int {
        update(id, "retry:\(id)", when: Self.sending) {
            $0.status = "retry"
            $0.retries = retries
            $0.nextRetry = nextRetry
            $0.lastError = lastError
        }
    }
    func deferRetry(id: Int64, nextRetry: Int64, lastError: String, now: Int64) async throws -> Int {
        update(id, "defer:\(id)", when: Self.sending) {
            $0.status = "retry"
            $0.nextRetry = nextRetry
            $0.lastError = lastError
        }
    }
    func settleConfirmed(now: Int64) async throws -> Int {
        locked {
            var n = 0
            for (id, r) in rows where r.ackStatus == "acked" && ["queued", "retry", "held", "sending"].contains(r.status) {
                rows[id]?.status = "sent"
                n += 1
            }
            calls.append("settle")
            return n
        }
    }
    func queueDepth(channel: String) async throws -> Int { 0 }
    func expireDeliveries(now: Int64) async throws -> Int { 0 }
    func holdForChannel(_ channel: String, now: Int64) async throws -> Int {
        note("hold:\(channel)")
        return 0
    }
    func unholdForChannel(_ channel: String, now: Int64) async throws -> Int {
        note("unhold:\(channel)")
        return 0
    }
    func cancelRunaway(safetyLimit: Int, now: Int64) async throws -> Int { 0 }
    func retryNowForChannel(_ channel: String, now: Int64) async throws -> Int {
        note("retryNow:\(channel)")
        return 2
    }
    /// Set to hold the start-up repair until the test opens it.
    var recoverGate: Gate?
    func recoverStale(now: Int64) async throws -> Int {
        note("recover")
        if let recoverGate { await recoverGate.wait() }
        return 0
    }
    func setAcked(id: Int64, now: Int64) async throws {
        locked {
            rows[id]?.ackStatus = "acked"
            rows[id]?.status = "delivered"
            calls.append("acked:\(id)")
        }
    }
    func setNacked(id: Int64, now: Int64) async throws { note("nacked:\(id)") }
    func timeoutPendingAcks(cutoff: Int64, now: Int64) async throws -> Int {
        note("sweepAll:\(cutoff)")
        return 0
    }
    func timeoutPendingAcks(channel: String, cutoff: Int64, now: Int64) async throws -> Int {
        note("sweep:\(channel):\(cutoff)")
        return 0
    }
    /// The channels the AckTracker test says have a pending ACK.
    var pendingChannels: [String] = []
    func pendingAckChannels() async throws -> [String] { locked { pendingChannels } }
    /// What getByChannelAndSeq answers (the AckTracker tests set it).
    var seqRow: MessageDelivery?
    func getByChannelAndSeq(channel: String, seqNum: Int64) async throws -> MessageDelivery? { locked { seqRow } }
}

final class EmptyRules: AccessRuleStore, ObjectGroupStore, @unchecked Sendable {
    func getAllSync() async throws -> [AccessRule] { [] }
    func recordMatch(id: Int64, timestamp: String) async throws {}
    func getAll() async throws -> [ObjectGroup] { [] }
}

/// A gate the test opens.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

final class DispatcherTests: XCTestCase {
    private func delivery(_ id: Int64, _ ref: String, _ text: String) -> MessageDelivery {
        MessageDelivery(id: id, msgRef: ref, channel: "iridium_0", textPreview: text, maxRetries: 0, createdAt: 1, updatedAt: 1)
    }

    private func waitUntil(_ timeoutMs: Int = 5_000, _ cond: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func make(store: FakeDeliveryStore, deliver: @escaping Dispatcher.DeliveryCallback) -> Dispatcher {
        let rules = EmptyRules()
        return Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil,
            registry: ChannelRegistry(), deliveryCallback: deliver, pollIntervalMs: 20)
    }

    func testStoppingTheWorkerMidSendLetsTheSendFinishAndRecordsIt() async {
        let store = FakeDeliveryStore(rows: [delivery(7, "msg:7", "now?")])
        let started = Gate()
        let release = Gate()
        let dispatcher = make(store: store) { _, _, _, _, _, _ in
            await started.open()
            await release.wait()
            return nil
        }
        dispatcher.startWorker("iridium_0")
        await started.wait()
        dispatcher.stopWorker("iridium_0")  // the interface went offline during the session
        await release.open()
        let done = await waitUntil { store.log.contains("status:7:sent") }
        XCTAssertTrue(done)
        XCTAssertEqual(store.log.filter { $0.hasPrefix("status:7:") }, ["status:7:sending", "status:7:sent"])
        dispatcher.stop()
    }

    func testAnInterfaceComingOnlineMakesItsWaitingRetriesDueNow() async {
        let store = FakeDeliveryStore()
        let dispatcher = make(store: store) { _, _, _, _, _, _ in "offline" }
        dispatcher.onInterfaceStateChange("iridium_0", channelType: "iridium", old: .connecting, new: .online)
        let woke = await waitUntil { store.log.contains("retryNow:iridium_0") }
        XCTAssertTrue(woke)
        dispatcher.stop()
    }

    func testANotNowAnswerWaitsWithoutCountingATryAndStopsTheBatch() async {
        let store = FakeDeliveryStore(rows: [delivery(1, "msg:1", "old"), delivery(2, "msg:2", "new")])
        let attempts = Changes()
        let dispatcher = make(store: store) { _, _, text, _, _, _ in
            attempts.add(text)
            return "\(Dispatcher.notNow)120000 the modem pauses"
        }
        dispatcher.startWorker("iridium_0")
        let deferred = await waitUntil { store.log.contains("defer:1") }
        XCTAssertTrue(deferred)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(attempts.list, ["old"])
        XCTAssertFalse(store.log.contains("defer:2"))
        XCTAssertFalse(store.log.contains { $0.hasPrefix("retry:") })
        dispatcher.stop()
    }

    func testASuccessfulSendMakesTheChannelsOtherWaitingMessagesDueNow() async {
        let store = FakeDeliveryStore(rows: [delivery(5, "msg:5", "tst2")])
        let dispatcher = make(store: store) { _, _, _, _, _, _ in nil }
        dispatcher.startWorker("iridium_0")
        // The three records land in no fixed order relative to each other, so wait for all of them.
        let done = await waitUntil {
            store.log.contains("retryNow:iridium_0") && store.log.contains("seq:5:1") && store.log.contains("ackPending:5")
        }
        XCTAssertTrue(done, "\(store.log)")
        dispatcher.stop()
    }

    func testANeverAnswerStopsTheDeliveryForGood() async {
        let store = FakeDeliveryStore(rows: [delivery(3, "msg:3", "too long")])
        let audits = Changes()
        let dispatcher = make(store: store) { _, _, _, _, _, _ in "\(Dispatcher.never) 412 bytes, 340 at most" }
        dispatcher.setOnAudit { event, iface, id, _, detail in audits.add("\(event):\(iface):\(id):\(detail)") }
        dispatcher.startWorker("iridium_0")
        let dead = await waitUntil { store.log.contains("status:3:dead") }
        XCTAssertTrue(dead)
        let audited = await waitUntil { !audits.list.isEmpty }
        XCTAssertTrue(audited)
        XCTAssertEqual(audits.list, ["drop:iridium_0:3:msg: 412 bytes, 340 at most"])
        dispatcher.stop()
    }

    func testEnqueueDirectStoresAnUncappedDelivery() async {
        let store = FakeDeliveryStore()
        let dispatcher = make(store: store) { _, _, _, _, _, _ in nil }
        let id = await dispatcher.enqueueDirect(
            destInterface: "iridium_0", payload: [1, 2], textPreview: "hi", msgRef: "msg:9", recipient: "+31")
        XCTAssertEqual(id, 1)
        let row = store.row(1)
        XCTAssertEqual(row?.maxRetries, 0)
        XCTAssertEqual(row?.qosLevel, 1)
        XCTAssertEqual(row?.recipient, "+31")
        XCTAssertNil(row?.expiresAt)
    }

    func testDispatchAccessQueuesAMatchedRuleWithTtlRecipientAndVisited() async throws {
        let store = FakeDeliveryStore()
        let rules = EmptyRules()
        let evaluator = AccessEvaluator(rules: rules, groups: rules)
        evaluator.load(rules: [
            AccessRule(
                id: 1, interfaceId: "mesh_0", direction: "ingress", priority: 5, name: "to sms", forwardTo: "sms_0",
                forwardOptions: "{\"to\": \"+31612345678\"}"),
            AccessRule(id: 2, interfaceId: "mesh_0", direction: "ingress", name: "loop", forwardTo: "mesh_0"),
        ])
        let registry = ChannelRegistry()
        try ChannelDefaults.register(into: registry)
        let dispatcher = Dispatcher(
            store: store, accessEvaluator: evaluator, failoverResolver: nil, registry: registry,
            deliveryCallback: { _, _, _, _, _, _ in nil }, pollIntervalMs: 20)
        let count = await dispatcher.dispatchAccess(
            sourceInterface: "mesh_0", msg: RouteMessage(text: "help", from: "!4370c1d8"), payload: Array("help".utf8))
        XCTAssertEqual(count, 1)
        let row = store.row(1)
        XCTAssertEqual(row?.channel, "sms_0")
        XCTAssertEqual(row?.recipient, "+31612345678")
        XCTAssertEqual(row?.origin, "!4370c1d8")
        XCTAssertEqual(row?.ttlSeconds, 86400, "the SMS channel's default TTL")
        XCTAssertEqual(row?.maxRetries, 3)
        XCTAssertEqual(row?.visited, "[\"mesh_0\"]")
        XCTAssertEqual(row?.ruleId, 1)
        // The same payload again within the TTL is a duplicate.
        let again = await dispatcher.dispatchAccess(
            sourceInterface: "mesh_0", msg: RouteMessage(text: "help", from: "!4370c1d8"), payload: Array("help".utf8))
        XCTAssertEqual(again, 0)
        XCTAssertEqual(dispatcher.deliveryDedups, 1)
    }
}

final class AccessEvaluatorTests: XCTestCase {
    private func evaluator(_ rules: [AccessRule], groups: [String: [String]] = [:]) -> AccessEvaluator {
        let store = EmptyRules()
        let e = AccessEvaluator(rules: store, groups: store)
        e.load(rules: rules, groups: groups)
        return e
    }

    func testImplicitDenyAndForward() {
        let e = evaluator([AccessRule(id: 1, interfaceId: "mesh_0", direction: "ingress", name: "fwd", forwardTo: "iridium_0")])
        XCTAssertEqual(e.evaluateIngress("mesh_0", RouteMessage(text: "x")).map(\.forwardTo), ["iridium_0"])
        XCTAssertTrue(e.evaluateIngress("sms_0", RouteMessage(text: "x")).isEmpty)
        XCTAssertTrue(e.evaluateEgress("mesh_0", RouteMessage(text: "x")).isEmpty)
        XCTAssertFalse(e.hasEgressRules("mesh_0"))
    }

    func testDropWinsAndFiltersApply() {
        let e = evaluator([
            AccessRule(
                id: 1, interfaceId: "mesh_0", direction: "ingress", priority: 1, name: "drop spam", action: "drop",
                filters: "{\"keyword\": \"spam\"}"),
            AccessRule(
                id: 2, interfaceId: "mesh_0", direction: "ingress", priority: 2, name: "fwd", forwardTo: "sms_0",
                filters: "{\"nodes\": \"[\\\"!aa\\\"]\", \"portnums\": \"[1]\"}"),
            AccessRule(id: 3, interfaceId: "mesh_0", direction: "ingress", priority: 3, name: "off", enabled: false, forwardTo: "aprs_0"),
        ])
        XCTAssertTrue(e.evaluateIngress("mesh_0", RouteMessage(text: "Buy SPAM now", from: "!aa")).isEmpty)
        XCTAssertEqual(e.evaluateIngress("mesh_0", RouteMessage(text: "hello", from: "!aa")).map(\.forwardTo), ["sms_0"])
        XCTAssertTrue(e.evaluateIngress("mesh_0", RouteMessage(text: "hello", from: "!bb")).isEmpty)
        XCTAssertTrue(e.evaluateIngress("mesh_0", RouteMessage(text: "hello", from: "!aa", portNum: 67)).isEmpty)
    }

    func testLoopsAndGroups() {
        let e = evaluator(
            [
                AccessRule(id: 1, interfaceId: "mesh_0", direction: "ingress", name: "self", forwardTo: "mesh_0"),
                AccessRule(id: 2, interfaceId: "mesh_0", direction: "ingress", name: "visited", forwardTo: "sms_0"),
                AccessRule(
                    id: 3, interfaceId: "mesh_0", direction: "ingress", name: "group", forwardTo: "iridium_0", filterNodeGroup: "vips"),
            ], groups: ["vips": ["!aa", "!bb"]])
        let fromVip = e.evaluateIngress("mesh_0", RouteMessage(text: "x", from: "!aa", visited: ["sms_0"]))
        XCTAssertEqual(fromVip.map(\.forwardTo), ["iridium_0"])
        XCTAssertTrue(e.evaluateIngress("mesh_0", RouteMessage(text: "x", from: "!zz", visited: ["sms_0"])).isEmpty)
    }
}
