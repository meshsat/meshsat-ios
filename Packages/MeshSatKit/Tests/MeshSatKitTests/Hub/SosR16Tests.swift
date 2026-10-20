// The r16 review's C10 findings on iOS (MESHSAT-1584), on the real controller with the fakes of
// SosTests and SosV2Tests: R3 a cancel frame whose enqueue failed stays owed and is queued once,
// never twice; R4 a new SOS keeps the last one's owed cancel, after a restart too; R5 a cancel
// made while the first start publish is under way owes the cancel, and so does a start's ack that
// comes after the local cancel. Android's SosControllerC10Test is the same set. The review's
// acceptance cases follow at the end (the Bridge's sos_r17_test.go is the same set): a start
// publish that timed out after the Hub took it, a restart inside the first start publish, and the
// last SOS's satellite start going out only after the next SOS began.
import MeshSatNet
import MeshSatWire
import XCTest

@testable import MeshSatEngine
@testable import MeshSatHub

/// A Hub session whose first start publish waits until the test releases it, as a broker that
/// has the start and has not answered yet.
final class GatedSosHub: SosHubLink, @unchecked Sendable {
    let inner: FakeSosHub
    private let lock = NSLock()
    private var gate = false
    private var entered = false
    init(_ inner: FakeSosHub) { self.inner = inner }
    var bridgeId: String { inner.bridgeId }
    var isConnected: Bool { get async { await inner.isConnected } }
    func close(_ on: Bool) { change { $0.gate = on } }
    var started: Bool { read { $0.entered } }
    private func change(_ f: (GatedSosHub) -> Void) {
        lock.lock()
        f(self)
        lock.unlock()
    }
    private func read<T>(_ f: (GatedSosHub) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f(self)
    }
    // swiftlint:disable:next function_parameter_count
    func publishSos(deviceId: String, id: String, text: String, sos: Bool, type: String, lat: Double?, lon: Double?, asMessage: Bool) async
        -> Bool
    {
        await inner.publishSos(deviceId: deviceId, id: id, text: text, sos: sos, type: type, lat: lat, lon: lon, asMessage: asMessage)
    }
    func publishSosEvent(_ event: JSONBody) async -> Bool {
        if event.string("kind") == "start" {
            change { $0.entered = true }
            while read({ $0.gate }) { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        return await inner.publishSosEvent(event)
    }
}

/// A Hub session that takes every start and answers as a PUBACK that never came: the Hub has the
/// start, the phone is told the publish failed.
final class TimedOutSosHub: SosHubLink, @unchecked Sendable {
    let inner: FakeSosHub
    init(_ inner: FakeSosHub) { self.inner = inner }
    var bridgeId: String { inner.bridgeId }
    var isConnected: Bool { get async { await inner.isConnected } }
    // swiftlint:disable:next function_parameter_count
    func publishSos(deviceId: String, id: String, text: String, sos: Bool, type: String, lat: Double?, lon: Double?, asMessage: Bool) async
        -> Bool
    {
        await inner.publishSos(deviceId: deviceId, id: id, text: text, sos: sos, type: type, lat: lat, lon: lon, asMessage: asMessage)
    }
    func publishSosEvent(_ event: JSONBody) async -> Bool {
        let took = await inner.publishSosEvent(event)
        return took && event.string("kind") != "start"
    }
}

/// A Hub session whose start publish never answers, as an app that stops inside it: the publish
/// ends only when its task is cancelled, and reaches no broker.
final class StuckSosHub: SosHubLink, @unchecked Sendable {
    let inner: FakeSosHub
    private let lock = NSLock()
    private var entered = false
    init(_ inner: FakeSosHub) { self.inner = inner }
    var bridgeId: String { inner.bridgeId }
    var isConnected: Bool { get async { await inner.isConnected } }
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }
    private func enter() {
        lock.lock()
        entered = true
        lock.unlock()
    }
    // swiftlint:disable:next function_parameter_count
    func publishSos(deviceId: String, id: String, text: String, sos: Bool, type: String, lat: Double?, lon: Double?, asMessage: Bool) async
        -> Bool
    {
        await inner.publishSos(deviceId: deviceId, id: id, text: text, sos: sos, type: type, lat: lat, lon: lon, asMessage: asMessage)
    }
    func publishSosEvent(_ event: JSONBody) async -> Bool {
        guard event.string("kind") == "start" else { return await inner.publishSosEvent(event) }
        enter()
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        return false
    }
}

final class SosR16Tests: XCTestCase {
    private var store: FakeDeliveryStore!
    private var settings: FakeSosSettings!
    private var env: FakeSosEnv!
    private var clock: Slept!
    private var hub: FakeSosHub!

    private func setUpWorld(up: Bool) {
        store = FakeDeliveryStore(rows: [])
        settings = FakeSosSettings()
        settings.hubCapsJson = #"{"v":1,"caps":["sos_v2"]}"#
        env = FakeSosEnv()
        clock = Slept()
        clock.add(1_792_330_000_123)
        hub = FakeSosHub(up: up)
        env.hub = hub
        let rules = EmptyRules()
        env.dispatcher = Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil, registry: ChannelRegistry(),
            deliveryCallback: { _, _, _, _, _, _ in nil })
    }

    /// A controller over the world, its kept state restored, as a process that starts.
    private func controller() -> SosController {
        let clock = self.clock!
        let c = SosController(
            deliveries: FakeSosQueries(store), settings: settings, env: env, now: { clock.values.reduce(0, +) },
            sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) })
        c.restore()
        return c
    }

    private func eventually(_ what: String, _ cond: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !(await cond()) {
            if Date() > deadline { return XCTFail("\(what): never") }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func rows(_ ref: String) -> [MessageDelivery] { store.all().filter { $0.msgRef == ref } }

    private func satWent(_ r: SosRun) async throws {
        let sat = try XCTUnwrap(rows(r.refPrefix + "sat").first)
        try await store.setStatus(id: sat.id!, "sent", lastError: "", now: 0)
    }

    private func ack(_ c: SosController, _ r: SosRun, _ kind: String, _ state: String) async {
        await c.onAck(#"{"v":2,"sos_id":"\#(r.sosId)","kind":"\#(kind)","state":"\#(state)","rev":1}"#)
    }

    func testAFailedCancelFrameEnqueueIsTriedAgainAndQueuedOnce() async throws {
        setUpWorld(up: false)
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        try await satWent(r)
        store.failInserts(endingWith: "cancel:sat")
        await sos.cancel()
        try? await Task.sleep(nanoseconds: 40_000_000)  // several rounds, each failing
        let ref = r.refPrefix + "cancel:sat"
        XCTAssertEqual(rows(ref).count, 0)
        XCTAssertFalse(try XCTUnwrap(sos.run.value).cancelFrameDone, "done after a failed enqueue")
        store.failInserts(endingWith: nil)
        await eventually("the frame queued") { rows(ref).count == 1 }
        await eventually("done") { sos.run.value?.cancelFrameDone == true }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rows(ref).count, 1, "one frame for one bearer")
        sos.stop()
    }

    func testARowFromBeforeACrashIsNotQueuedTwice() async throws {
        setUpWorld(up: false)
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        try await satWent(r)
        await sos.cancel()
        let ref = r.refPrefix + "cancel:sat"
        await eventually("the frame") { rows(ref).count == 1 }
        sos.stop()
        // The run's update was lost: a new process finds the row and a run that says not done.
        var lost = try XCTUnwrap(SosRun.fromJson(settings.sosRunJson))
        lost.cancelFrameDone = false
        settings.sosRunJson = lost.toJson()
        let after = controller()
        await eventually("done after the restart") { after.run.value?.cancelFrameDone == true }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rows(ref).count, 1)
        after.stop()
    }

    func testANewSosKeepsTheLastOnesOwedCancelAlsoAfterARestart() async throws {
        setUpWorld(up: true)
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        let a = try XCTUnwrap(sos.run.value)
        await eventually("A's start published") { hub.count("start") > 0 }
        await ack(sos, a, "start", "active")
        hub.up = false  // A's cancel does not reach the Hub
        await sos.cancel()
        clock.add(1_000)
        await sos.start(test: false, trigger: "button")
        let b = try XCTUnwrap(sos.run.value)
        XCTAssertNotEqual(b.sosId, a.sosId)
        sos.stop()
        // A restart before the connection comes back.
        let after = controller()
        hub.up = true
        await eventually("A's cancel after B and the restart") {
            hub.events.contains { $0.string("kind") == "cancel" && $0.string("sos_id") == a.sosId }
        }
        await ack(after, a, "cancel", "cancelled")
        await eventually("A no longer kept") { !settings.sosPrevRunsJson.contains(a.sosId) }
        XCTAssertEqual(after.run.value?.id, b.id)
        XCTAssertEqual(after.run.value?.active, true, "B still active")
        XCTAssertFalse(hub.events.contains { $0.string("kind") == "cancel" && $0.string("sos_id") == b.sosId }, "B has no cancel")
        after.stop()
    }

    func testACancelDuringTheFirstStartPublishOwesTheCancel() async throws {
        setUpWorld(up: true)
        let gated = GatedSosHub(hub)
        gated.close(true)
        env.hub = gated
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        await eventually("the start publish began") { gated.started }
        let r = try XCTUnwrap(sos.run.value)
        XCTAssertTrue(r.hubV2, "the attempt is kept before the publish")
        await sos.cancel()
        XCTAssertEqual(sos.run.value?.cancelV2Owed, true, "a cancel during the publish owes the Hub the cancel")
        gated.close(false)
        await eventually("the cancel") { hub.count("cancel") > 0 }
        await ack(sos, r, "cancel", "cancelled")
        XCTAssertNotNil(sos.run.value?.cancelHubAckedAt)
        sos.stop()
    }

    func testAStartsAckAfterTheCancelOwesTheCancel() async throws {
        setUpWorld(up: false)  // no start leaves, so the cancel owes nothing yet
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        await sos.cancel()
        XCTAssertEqual(sos.run.value?.cancelV2Owed, false, "the precondition: nothing left, so nothing owed")
        hub.up = true
        await ack(sos, r, "start", "active")
        XCTAssertEqual(sos.run.value?.cancelV2Owed, true, "the late start ack made the cancel owed")
        await eventually("the cancel") { hub.count("cancel") > 0 }
        sos.stop()
    }

    private func cancelPublished(_ hub: FakeSosHub, _ r: SosRun) -> Bool {
        hub.events.contains { $0.string("kind") == "cancel" && $0.string("sos_id") == r.sosId }
    }

    /// R5: every start publish times out after the Hub took the start, so the phone never sees one
    /// reach the broker; a cancel then still owes the Hub the cancel.
    func testAStartPublishThatTimedOutAfterTheHubTookItOwesTheCancel() async throws {
        setUpWorld(up: true)
        env.hub = TimedOutSosHub(hub)
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        await eventually("the Hub has the start") { hub.count("start") > 0 }
        let r = try XCTUnwrap(sos.run.value)
        XCTAssertNil(r.hubPublishedAt, "the precondition: the phone saw the start reach the broker")
        await sos.cancel()
        XCTAssertEqual(sos.run.value?.cancelV2Owed, true, "a start the Hub took, though its publish failed, owes the Hub no cancel")
        await eventually("the cancel") { cancelPublished(hub, r) }
        sos.stop()
    }

    /// R5: the app stops while the first start publish is under way. The next process finds the
    /// attempt kept, so a cancel made after the restart owes the Hub the cancel, with no start
    /// publish of its own before it.
    func testARestartInsideTheFirstStartPublishOwesTheCancel() async throws {
        setUpWorld(up: true)
        let stuck = StuckSosHub(hub)
        env.hub = stuck
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        await eventually("the start publish began") { stuck.started }
        let r = try XCTUnwrap(sos.run.value)
        sos.stop()  // the old process ends inside its publish, which never reached a broker
        let fresh = FakeSosHub(up: false)  // no session yet: the new process publishes nothing
        env.hub = fresh
        let after = controller()
        await after.cancel()
        XCTAssertEqual(after.run.value?.cancelV2Owed, true, "after a restart inside the start publish, the cancel owes the Hub nothing")
        XCTAssertEqual(fresh.count("start"), 0, "the precondition: the new process published a start")
        XCTAssertEqual(hub.count("start"), 0, "the precondition: the old publish reached the broker")
        fresh.up = true
        await eventually("the cancel after the restart") { cancelPublished(fresh, r) }
        after.stop()
    }

    /// R4: A is cancelled while its satellite start is with the modem, A's cancel gets no ack, B
    /// starts, and only then does A's start go out. A's 0x08 still goes on the satellite once the
    /// grace is over; B stays active and owes no cancel.
    func testASatelliteStartThatGoesAfterTheNextSosStillGetsItsCancelFrame() async throws {
        setUpWorld(up: true)
        let sos = controller()
        await sos.start(test: false, trigger: "button")
        let a = try XCTUnwrap(sos.run.value)
        XCTAssertTrue(a.satV2, "the precondition: A's satellite leg is the 0x07")
        let sat = try XCTUnwrap(rows(a.refPrefix + "sat").first)
        try await store.setStatus(id: sat.id!, "sending", lastError: "", now: 0)  // with the modem
        await eventually("A's start published") { hub.count("start") > 0 }
        await ack(sos, a, "start", "active")
        await sos.cancel()
        await eventually("A's cancel published") { cancelPublished(hub, a) }
        clock.add(1_000)
        await sos.start(test: false, trigger: "button")
        let b = try XCTUnwrap(sos.run.value)
        XCTAssertNotEqual(b.sosId, a.sosId)
        try await store.setStatus(id: sat.id!, "sent", lastError: "", now: 0)  // A's start goes out, after B began
        let went = try XCTUnwrap(rows(a.refPrefix + "sat").first)
        await sos.onSent(went)
        clock.add(SosV2.cancelAckGraceMs + 1_000)
        await eventually("A's 0x08 after the grace") { rows(a.refPrefix + "cancel:sat").count == 1 }
        XCTAssertEqual(rows(b.refPrefix + "cancel:sat").count, 0, "B has a cancel frame")
        XCTAssertEqual(sos.run.value?.id, b.id)
        XCTAssertEqual(sos.run.value?.active, true, "B is not the active SOS")
        XCTAssertFalse(cancelPublished(hub, b), "a cancel was published for B")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rows(a.refPrefix + "cancel:sat").count, 1, "one frame for A's one bearer")
        sos.stop()
    }
}
