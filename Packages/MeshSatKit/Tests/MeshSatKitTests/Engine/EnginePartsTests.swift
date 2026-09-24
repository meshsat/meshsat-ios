// Mirrors SatelliteRetryTest, SatelliteLimitsTest (the frame rule; the fragment header case
// follows IridiumFragment), SequenceTrackerTest, DeduplicatorTest, OutgoingTextTest,
// HubOriginTest (the topic case follows HubTopics), CreditTrackerTest, TokenBucketTest and
// InterfaceManagerNoteErrorTest.
import Foundation
import MeshSatEngine
import MeshSatNet
import XCTest

final class SatelliteRetryTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private let initial: Int64 = 180_000
    private let max: Int64 = 30 * 60_000

    func testNoNetworkServiceIsRetriedEvery3MinutesHoweverManyTriesFailed() {
        for retries in [1, 5, 6, 8, 40] {
            XCTAssertEqual(
                Dispatcher.satelliteRetryAt(nowMs: now, retries: retries, moStatus: 32, initialWaitMs: initial, maxWaitMs: max),
                now + 3 * 60_000)
            XCTAssertEqual(
                Dispatcher.satelliteRetryAt(nowMs: now, retries: retries, moStatus: 36, initialWaitMs: initial, maxWaitMs: max),
                now + 3 * 60_000)
        }
    }

    func testABusyModemAndAGatewayThatDidNotAnswerAreRetriedSoon() {
        XCTAssertEqual(
            Dispatcher.satelliteRetryAt(nowMs: now, retries: 7, moStatus: 35, initialWaitMs: initial, maxWaitMs: max), now + 30_000)
        XCTAssertEqual(
            Dispatcher.satelliteRetryAt(nowMs: now, retries: 7, moStatus: 17, initialWaitMs: initial, maxWaitMs: max), now + 60_000)
    }

    func testOtherFailuresBackOffByDoublingUpToTheChannelsMaximum() {
        XCTAssertEqual(
            Dispatcher.satelliteRetryAt(nowMs: now, retries: 1, moStatus: 18, initialWaitMs: initial, maxWaitMs: max), now + 6 * 60_000)
        XCTAssertEqual(
            Dispatcher.satelliteRetryAt(nowMs: now, retries: 2, moStatus: nil, initialWaitMs: initial, maxWaitMs: max), now + 12 * 60_000)
        XCTAssertEqual(
            Dispatcher.satelliteRetryAt(nowMs: now, retries: 4, moStatus: nil, initialWaitMs: initial, maxWaitMs: max), now + 30 * 60_000)
        XCTAssertEqual(
            Dispatcher.satelliteRetryAt(nowMs: now, retries: 40, moStatus: 13, initialWaitMs: initial, maxWaitMs: max), now + 30 * 60_000)
    }

    func testTheModemsStatusIsReadFromTheDeliverysError() {
        XCTAssertEqual(Dispatcher.moStatusOf("Not sent: status 32, no network service, MOMSN 228"), 32)
        XCTAssertEqual(Dispatcher.moStatusOf("\(Dispatcher.unconfirmed) status 18, the radio link dropped, MOMSN 12 (part 1 of 2)"), 18)
        XCTAssertNil(Dispatcher.moStatusOf("Could not hand the message to the modem"))
        XCTAssertNil(Dispatcher.moStatusOf("The modem gave no readable answer"))
    }

    func testRecipientAndSourceBearerAreReadByHand() {
        XCTAssertEqual(Dispatcher.recipientFromOptions("{\"ttl_seconds\": 60, \"to\": \"+31612345678\"}"), "+31612345678")
        XCTAssertEqual(Dispatcher.recipientFromOptions("{\"to\": {\"x\": 1}}"), "")
        XCTAssertEqual(Dispatcher.recipientFromOptions("{}"), "")
        XCTAssertEqual(Dispatcher.recipientFromOptions(""), "")
        XCTAssertEqual(Dispatcher.sourceBearerOf("[\"sms_0\", \"mesh_0\"]"), "sms_0")
        XCTAssertEqual(Dispatcher.sourceBearerOf("[]"), "")
        XCTAssertEqual(Dispatcher.sourceBearerOf(""), "")
        XCTAssertEqual(Dispatcher.sourceBearerOf("{\"a\": [\"x\"]}"), "", "anchored: never a nested array's first string")
    }
}

final class SatelliteLimitsTests: XCTestCase {
    func test340BytesFitsAnd341DoesNot() {
        XCTAssertTrue(SatelliteLimits.fits(0))
        XCTAssertTrue(SatelliteLimits.fits(340))
        XCTAssertFalse(SatelliteLimits.fits(341))
    }

    func testAPersonIsToldTheSizeTheLimitAndWhatToDo() {
        XCTAssertEqual(
            SatelliteLimits.tooLong(412), "Too long for a satellite message: 412 bytes, 340 at most. Shorten it or send it in two.")
    }
}

final class SequenceTrackerTests: XCTestCase {
    func testEgressStartsAt1AndIncrements() {
        let t = SequenceTracker()
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 1)
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 2)
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 3)
    }

    func testPerInterfaceIndependentCounters() {
        let t = SequenceTracker()
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 1)
        XCTAssertEqual(t.nextEgressSeq("iridium_0"), 1)
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 2)
        XCTAssertEqual(t.nextEgressSeq("iridium_0"), 2)
    }

    func testCurrentEgressSeq() {
        let t = SequenceTracker()
        XCTAssertEqual(t.currentEgressSeq("mesh_0"), 0)
        _ = t.nextEgressSeq("mesh_0")
        _ = t.nextEgressSeq("mesh_0")
        XCTAssertEqual(t.currentEgressSeq("mesh_0"), 2)
    }

    func testIngressIndependentFromEgressAndResets() {
        let t = SequenceTracker()
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 1)
        XCTAssertEqual(t.nextIngressSeq("mesh_0"), 1)
        XCTAssertEqual(t.nextEgressSeq("mesh_0"), 2)
        XCTAssertEqual(t.nextIngressSeq("mesh_0"), 2)
        _ = t.nextEgressSeq("iridium_0")
        t.reset("mesh_0")
        XCTAssertEqual(t.currentEgressSeq("mesh_0"), 0)
        XCTAssertEqual(t.currentEgressSeq("iridium_0"), 1)
        t.resetAll()
        XCTAssertEqual(t.currentEgressSeq("iridium_0"), 0)
    }
}

final class DeduplicatorTests: XCTestCase {
    func testFirstIsNewSameIsDuplicateOthersAreNew() {
        let d = Deduplicator()
        XCTAssertFalse(d.isDuplicate(from: 1, packetId: 100))
        XCTAssertTrue(d.isDuplicate(from: 1, packetId: 100))
        XCTAssertFalse(d.isDuplicate(from: 1, packetId: 101))
        XCTAssertFalse(d.isDuplicate(from: 2, packetId: 100))
    }

    func testStringKeys() {
        let d = Deduplicator()
        XCTAssertFalse(d.isDuplicateKey("sms:+1234:hello"))
        XCTAssertTrue(d.isDuplicateKey("sms:+1234:hello"))
        XCTAssertFalse(d.isDuplicateKey("sms:+1234:world"))
    }

    func testCapacityLimitEvictsOldest() {
        let d = Deduplicator(maxSize: 3)
        XCTAssertFalse(d.isDuplicateKey("a"))
        XCTAssertFalse(d.isDuplicateKey("b"))
        XCTAssertFalse(d.isDuplicateKey("c"))
        XCTAssertEqual(d.size, 3)
        XCTAssertFalse(d.isDuplicateKey("d"))
        XCTAssertEqual(d.size, 3)
        XCTAssertFalse(d.isDuplicateKey("a"), "evicted, no longer a duplicate")
    }

    func testSizeAndPrune() {
        let clock = TickClock()
        let d = Deduplicator(ttlMs: 1000, now: { clock.now })
        XCTAssertEqual(d.size, 0)
        _ = d.isDuplicateKey("x")
        _ = d.isDuplicateKey("y")
        _ = d.isDuplicateKey("x")
        XCTAssertEqual(d.size, 2)
        clock.now += 1500
        XCTAssertEqual(d.prune(), 2)
        XCTAssertEqual(d.size, 0)
        XCTAssertFalse(d.isDuplicateKey("x"))
    }
}

final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    var now: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

final class OutgoingTextTests: XCTestCase {
    func testWhatIsTypedIsWhatGoesOnTheMesh() {
        for s in ["on my way", "Need water and a medic at the north gate", "Καλημέρα, όλα καλά", "ATEPAE4AAAA=", ""] {
            XCTAssertEqual(OutgoingText.onMesh(s), s)
        }
    }
}

final class HubOriginTests: XCTestCase {
    private let imei = "300434000000000"
    private let bridge = "msa-flaneur"

    func testATextFromAPersonIsThatPersonsNotTheModems() {
        XCTAssertEqual(
            HubOrigin.deviceIdFor(sourceBearer: "sms_0", origin: "+31600000000", modemImei: imei, bridgeId: bridge), "+31600000000")
    }

    func testAMeshMessageIsTheSendingNodes() {
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "mesh_0", origin: "!4370c1d8", modemImei: imei, bridgeId: bridge), "!4370c1d8")
    }

    func testWhatTheModemCarriedKeepsTheModemsName() {
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "iridium_0", origin: imei, modemImei: imei, bridgeId: bridge), imei)
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "iridium9704_0", origin: "", modemImei: imei, bridgeId: bridge), imei)
    }

    func testWrittenOnThisPhoneItIsThisPhones() {
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "", origin: "", modemImei: imei, bridgeId: bridge), bridge)
    }

    func testAnUnknownSenderFallsToTheGatewayNeverToTheModem() {
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "sms_0", origin: "", modemImei: imei, bridgeId: bridge), bridge)
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "mesh_0", origin: "someone", modemImei: imei, bridgeId: bridge), bridge)
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "mesh_0", origin: "  ", modemImei: imei, bridgeId: bridge), bridge)
    }

    func testWithNoBridgeIdAtAllThereIsStillAnId() {
        XCTAssertEqual(HubOrigin.deviceIdFor(sourceBearer: "", origin: "", modemImei: imei, bridgeId: ""), imei)
    }
}

final class CreditTrackerTests: XCTestCase {
    private final class FakeStore: IridiumCreditStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [IridiumCreditEntry] = []
        var entries: [IridiumCreditEntry] {
            lock.lock()
            defer { lock.unlock() }
            return rows
        }
        private func add(_ e: IridiumCreditEntry) {
            lock.lock()
            rows.append(e)
            lock.unlock()
        }
        func insert(_ entry: IridiumCreditEntry) async throws { add(entry) }
        func totalCostCents() async throws -> Int? { entries.reduce(0) { $0 + $1.costCents } }
        func costSince(_ since: Int64) async throws -> Int? { entries.filter { $0.timestamp > since }.reduce(0) { $0 + $1.costCents } }
        func messagesSince(_ since: Int64) async throws -> Int { entries.filter { $0.timestamp > since }.count }
    }

    func testRecordMoInsertsEntryWithDefaultCost() async throws {
        let store = FakeStore()
        let tracker = CreditTracker(store: store)
        try await tracker.recordMo(moMsn: 42)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].costCents, 5)
        XCTAssertEqual(store.entries[0].messageType, "mo")
        XCTAssertEqual(store.entries[0].moMsn, 42)
    }

    func testRecordBurstMultipliesCostByMessageCount() async throws {
        let store = FakeStore()
        let tracker = CreditTracker(store: store, costPerMoCents: 5)
        try await tracker.recordBurst(messageCount: 4)
        XCTAssertEqual(store.entries[0].costCents, 20)
        XCTAssertEqual(store.entries[0].messageType, "burst")
    }

    func testTotalsAndToday() async throws {
        let store = FakeStore()
        let tracker = CreditTracker(store: store, now: { 1_790_000_000_000 })
        try await tracker.recordMo()
        try await tracker.recordMo()
        try await tracker.recordBurst(messageCount: 3)
        let total = try await tracker.totalCostCents()
        XCTAssertEqual(total, 25)
        let today = try await tracker.todayMessageCount()
        XCTAssertEqual(today, 3)
        XCTAssertEqual(CreditTracker.startOfTodayUtc(nowMs: 1_790_000_000_000), 1_789_948_800_000)
    }
}

final class TokenBucketTests: XCTestCase {
    private final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var t = 0.0
        var seconds: Double {
            get {
                lock.lock()
                defer { lock.unlock() }
                return t
            }
            set {
                lock.lock()
                t = newValue
                lock.unlock()
            }
        }
    }

    func testFreshBucketAllowsRequestsUpToCapacity() {
        let time = Time()
        let b = TokenBucket(maxTokens: 3, refillRate: 1, now: { time.seconds })
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertFalse(b.allow())
    }

    func testTokensRefillOverTime() {
        let time = Time()
        let b = TokenBucket(maxTokens: 2, refillRate: 10, now: { time.seconds })
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertFalse(b.allow())
        time.seconds += 0.2
        XCTAssertTrue(b.allow())
    }

    func testTokensNeverExceedMaxAndZeroRateNeverRefills() {
        let time = Time()
        let b = TokenBucket(maxTokens: 3, refillRate: 100, now: { time.seconds })
        time.seconds += 10
        XCTAssertEqual(b.tokenCount(), 3, accuracy: 0.01)
        let z = TokenBucket(maxTokens: 1, refillRate: 0, now: { time.seconds })
        XCTAssertTrue(z.allow())
        XCTAssertFalse(z.allow())
        time.seconds += 10
        XCTAssertFalse(z.allow())
        XCTAssertNil(TokenBucket.ruleLimiter(perWindow: 0, windowSeconds: 60))
        XCTAssertNotNil(TokenBucket.ruleLimiter(perWindow: 5, windowSeconds: 60))
    }
}

final class InterfaceManagerTests: XCTestCase {
    func testANotedErrorKeepsTheInterfaceOnlineAndFiresNoStateChange() {
        let mgr = InterfaceManager()
        let changes = Changes()
        mgr.setStateChangeCallback { _, _, old, new in changes.add("\(old)->\(new)") }
        mgr.register(InterfaceConfig(id: "iridium_0", channelType: "iridium"))
        mgr.setOnline("iridium_0")
        XCTAssertEqual(changes.list, ["offline->online"])
        mgr.noteError("iridium_0", "SBDIX held for 42 s after a failed session")
        let status = mgr.states.value["iridium_0"]
        XCTAssertEqual(status?.state, .online)
        XCTAssertEqual(status?.error, "SBDIX held for 42 s after a failed session")
        XCTAssertEqual(changes.list, ["offline->online"])
        XCTAssertTrue(mgr.isOnline("iridium_0"))
    }

    func testTransitionsAndBackoff() {
        let mgr = InterfaceManager()
        let changes = Changes()
        mgr.setStateChangeCallback { id, _, old, new in changes.add("\(id):\(old)->\(new)") }
        mgr.register(InterfaceConfig(id: "sms_0", channelType: "sms", alwaysOnline: true))
        mgr.register(InterfaceConfig(id: "mesh_0", channelType: "mesh", autoReconnect: false))
        XCTAssertEqual(mgr.getState("sms_0"), .online)
        mgr.setOnline("mesh_0")
        mgr.setError("mesh_0", "gone")
        mgr.setError("mesh_0", "still gone")
        mgr.disable("mesh_0")
        mgr.setError("mesh_0", "ignored while disabled")
        XCTAssertEqual(mgr.getState("mesh_0"), .disabled)
        mgr.enable("mesh_0")
        XCTAssertEqual(
            changes.list, ["mesh_0:offline->online", "mesh_0:online->error", "mesh_0:error->disabled", "mesh_0:disabled->offline"])
        XCTAssertEqual(InterfaceManager.calculateBackoff(attempt: 0, initialMs: 5000, maxMs: 120_000), 5000)
        XCTAssertEqual(InterfaceManager.calculateBackoff(attempt: 3, initialMs: 5000, maxMs: 120_000), 40_000)
        XCTAssertEqual(InterfaceManager.calculateBackoff(attempt: 9, initialMs: 5000, maxMs: 120_000), 120_000)
    }
}

final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }
    var list: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class ChannelRegistryTests: XCTestCase {
    func testDefaultsAndLookups() throws {
        let registry = ChannelRegistry()
        try ChannelDefaults.register(into: registry)
        XCTAssertEqual(registry.ids(), ["mesh", "iridium", "sms", "mqtt", "reticulum", "aprs"])
        XCTAssertTrue(registry.isPaid("iridium"))
        XCTAssertFalse(registry.binaryCapable("sms"))
        XCTAssertEqual(registry.get("iridium")?.retryConfig.backoffFunc, "isu")
        XCTAssertEqual(registry.get("iridium")?.defaultTtlSeconds, 3600)
        XCTAssertEqual(ChannelRegistry.channelType(of: "iridium_0"), "iridium")
        XCTAssertEqual(ChannelRegistry.channelType(of: "mesh"), "mesh")
        XCTAssertThrowsError(try registry.register(ChannelDescriptor(id: "mesh", label: "again")))
    }
}
