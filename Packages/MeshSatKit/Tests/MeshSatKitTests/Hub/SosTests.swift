// Ports SosRunTest.kt, and drives SosController through a start, a cancel and a test run with a
// fake environment and the dispatcher over the fake delivery store of the engine tests.
import MeshSatNet
import MeshSatWire
import XCTest

@testable import MeshSatEngine
@testable import MeshSatHub

private typealias State = SosRouteStatus.State

final class SosRunTests: XCTestCase {
    private func run(test: Bool = false, hubWanted: Bool = true, hubSentAt: Int64? = nil, cancelledAt: Int64? = nil) -> SosRun {
        SosRun(
            id: 1_000, test: test, trigger: "button", name: "flaneur", fix: nil,
            routes: [
                SosRun.Route(key: "sat", label: "Satellite, to the Hub"), SosRun.Route(key: "sms:+31600000000", label: "SMS to Anna"),
            ],
            skipped: [], hubWanted: hubWanted, deviceId: "300434067943980", hubAlertId: "sos-sbd-msa-flaneur-1", hubSentAt: hubSentAt,
            cancelledAt: cancelledAt)
    }

    private func del(_ ref: String, _ status: String, lastError: String = "", retries: Int = 0, channel: String = "x", ack: String? = nil)
        -> MessageDelivery
    {
        MessageDelivery(
            msgRef: ref, channel: channel, status: status, priority: 0, textPreview: "", retries: retries, lastError: lastError,
            ackStatus: ack,
            createdAt: 0, updatedAt: 0)
    }

    func testEachRouteReadsItsOwnDeliveryAndTheHubItsOwnLink() {
        let statuses = SosProgress.routes(
            run(),
            deliveries: [
                del("sos:1000:sat", "retry", lastError: "Not sent: status 32, no network", retries: 1),
                del("sos:1000:sms:+31600000000", "sent"),
            ])
        XCTAssertEqual(statuses.map { $0.state }, [.waiting, .sent, .waiting])
        XCTAssertTrue(statuses[0].detail.contains("status 32"))
        XCTAssertEqual(statuses[2].label, "Hub, over the internet")
    }

    func testACancelledDeliveryIsStoppedNotFailed() {
        let statuses = SosProgress.routes(
            run(hubWanted: false),
            deliveries: [
                del("sos:1000:sat", "dead", lastError: "cancelled"), del("sos:1000:sms:+31600000000", "dead", lastError: "SMS failed"),
            ])
        XCTAssertEqual(statuses.map { $0.state }, [.stopped, .failed])
    }

    func testAfterACancelEachRouteShowsItsCancellation() {
        let statuses = SosProgress.routes(
            run(hubWanted: false, cancelledAt: 2_000), deliveries: [del("sos:1000:sat", "sent"), del("sos:1000:cancel:sat", "queued")])
        XCTAssertEqual(statuses[0].cancel, .waiting)
        XCTAssertNil(statuses[1].cancel)
    }

    func testAConfirmedRouteSaysWhoConfirmedIt() {
        let sat = del("sos:1000:sat", "sent", channel: "iridium_0", ack: "acked")
        let sms = del("sos:1000:sms:+31600000000", "sent", channel: "sms_0", ack: "acked")
        XCTAssertEqual(
            SosProgress.routes(run(hubWanted: false), deliveries: [sat, sms]).map { $0.detail },
            ["Sent, and the Hub has it", "Delivered to their phone"])
        let unconfirmed = [
            del("sos:1000:sat", "sent", channel: "iridium_0", ack: "pending"), del("sos:1000:sms:+31600000000", "sent", channel: "sms_0"),
        ]
        XCTAssertEqual(SosProgress.routes(run(hubWanted: false), deliveries: unconfirmed).map { $0.detail }, ["Sent", "Sent"])
    }

    func testRefsNameTheRunAndWhetherItIsACancellation() {
        XCTAssertEqual(SosRun.parseRef("sos:1000:sms:+31600000000")?.id, 1_000)
        XCTAssertEqual(SosRun.parseRef("sos:1000:sms:+31600000000")?.isCancel, false)
        XCTAssertEqual(SosRun.parseRef("sos:1000:cancel:sat")?.isCancel, true)
        XCTAssertNil(SosRun.parseRef("msg:42"))
        XCTAssertNil(SosRun.parseRef("sos:x:sat"))
    }

    func testATestIsSettledOnlyWhenEveryRouteAndTheHubAreDone() {
        let r = run(test: true)
        let dels = [del("sos:1000:sat", "sent"), del("sos:1000:sms:+31600000000", "sent")]
        XCTAssertFalse(SosProgress.allSettled(r, statuses: SosProgress.routes(r, deliveries: dels)))
        var told = r
        told.hubSentAt = 1_500
        XCTAssertTrue(SosProgress.allSettled(told, statuses: SosProgress.routes(told, deliveries: dels)))
    }

    func testTheNotificationLineSaysWhatWentAndWhatIsStillTrying() {
        let line = SosProgress.summary(
            SosProgress.routes(run(hubSentAt: 1_500), deliveries: [del("sos:1000:sat", "retry"), del("sos:1000:sms:+31600000000", "sent")]))
        XCTAssertEqual(line, "Sent by SMS to Anna and the Hub online. Still trying satellite.")
        XCTAssertEqual(SosProgress.summary([]), "No way to send it: add emergency contacts or connect your node.")
    }

    func testAnAwaitingUserSmsIsWaitingWithItsOwnWords() {
        let statuses = SosProgress.routes(
            run(hubWanted: false), deliveries: [del("sos:1000:sms:+31600000000", Dispatcher.awaitingUser, channel: "sms_0")])
        XCTAssertEqual(statuses[1].state, .waiting)
        XCTAssertEqual(statuses[1].detail, "Waiting for you to send it in Messages")
    }

    func testTheRunSurvivesItsJson() {
        var r = run(hubSentAt: 1_500, cancelledAt: 2_000)
        r.fix = SosMessages.Fix(lat: 52.16207, lon: 4.50974, accuracyM: 8, timeMs: 1_000)
        r.skipped = ["Mesh: no mesh radio is paired with this phone."]
        let json = r.toJson()
        XCTAssertTrue(json.contains("\"hub_alert_id\":\"sos-sbd-msa-flaneur-1\""))
        XCTAssertTrue(json.contains("\"acc\":8"))
        XCTAssertEqual(SosRun.fromJson(json), r)
        XCTAssertNil(SosRun.fromJson(""))
        XCTAssertNil(SosRun.fromJson("{\"nope\":1}"))
        XCTAssertTrue(r.active == false)
    }
}

// MARK: Controller

final class FakeSosSettings: SosSettings, @unchecked Sendable {
    private let lock = NSLock()
    private var json = ""
    var sosRunJson: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return json
        }
        set {
            lock.lock()
            json = newValue
            lock.unlock()
        }
    }
    var sosName = "flaneur"
    var hubCallsign = "MSA"
    var sosContacts: [EmergencyContact] = []
}

/// The delivery store of the engine tests, seen through the by-prefix queries.
final class FakeSosQueries: SosDeliveryQueries, @unchecked Sendable {
    let store: FakeDeliveryStore
    init(_ store: FakeDeliveryStore) { self.store = store }
    func getByRefPrefix(_ prefix: String) async throws -> [MessageDelivery] { store.all().filter { $0.msgRef.hasPrefix(prefix) } }
    func cancelWaitingByRefPrefix(_ prefix: String) async throws -> Int {
        var n = 0
        for d in store.all() where d.msgRef.hasPrefix(prefix) && ["queued", "retry", "held", Dispatcher.awaitingUser].contains(d.status) {
            if let id = d.id {
                try await store.setStatus(id: id, "dead", lastError: "cancelled", now: 0)
                n += 1
            }
        }
        return n
    }
    func observeByRefPrefix(_ prefix: String) -> AsyncStream<[MessageDelivery]> {
        AsyncStream { continuation in
            continuation.yield(store.all().filter { $0.msgRef.hasPrefix(prefix) })
            continuation.finish()
        }
    }
}

final class FakeSosEnv: SosEnv, @unchecked Sendable {
    var dispatcher: Dispatcher?
    var hubReporter: HubReporter?
    var imei = "300434067943980"
    var paired = true
    var fix: SosMessages.Fix? = SosMessages.Fix(lat: 52.16207, lon: 4.50974, accuracyM: 8, timeMs: 1_000)
    var sms = true
    private let lock = NSLock()
    private(set) var audits: [String] = []
    private(set) var taks: [String] = []
    func modemImei() async -> String { imei }
    func meshPaired() async -> Bool { paired }
    func location() -> (fix: SosMessages.Fix, altitudeM: Double)? { fix.map { ($0, 12.7) } }
    func canSendSms() -> Bool { sms }
    func tak(lat: Double, lon: Double, alt: Double, reason: String) {
        lock.lock()
        taks.append(reason)
        lock.unlock()
    }
    func audit(event: String, detail: String) async { record("\(event) \(detail)") }
    private func record(_ line: String) {
        lock.lock()
        audits.append(line)
        lock.unlock()
    }
}

final class SosControllerTests: XCTestCase {
    private var store: FakeDeliveryStore!
    private var settings: FakeSosSettings!
    private var env: FakeSosEnv!
    private var clock: Slept!

    private func makeController() -> SosController {
        store = FakeDeliveryStore(rows: [])
        settings = FakeSosSettings()
        env = FakeSosEnv()
        clock = Slept()
        clock.add(1_700_000_000_000)
        let rules = EmptyRules()
        let disp = Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil, registry: ChannelRegistry(),
            deliveryCallback: { _, _, _, _, _, _ in nil })
        env.dispatcher = disp
        settings.sosContacts = [EmergencyContact(name: "Anna", phone: "+31600000000")]
        let clock = self.clock!
        return SosController(
            deliveries: FakeSosQueries(store), settings: settings, env: env, now: { clock.values.reduce(0, +) },
            sleep: { _ in throw CancellationError() })
    }

    func testAnSosQueuesEveryRouteAtPriorityZeroAndIsSaved() async throws {
        let sos = makeController()
        await sos.start(test: false, trigger: "button")
        let run = try XCTUnwrap(sos.run.value)
        XCTAssertFalse(run.test)
        XCTAssertEqual(run.routes.map { $0.key }, ["sat", "mesh", "sms:+31600000000"])
        XCTAssertEqual(run.routes.last?.label, "SMS to Anna")
        XCTAssertEqual(run.deviceId, "300434067943980")
        XCTAssertTrue(run.hubAlertId.hasPrefix("sos-sbd-meshsat-ios-"))
        XCTAssertFalse(run.hubWanted)
        XCTAssertTrue(run.skipped.contains("Hub: not set up on this phone."))
        XCTAssertTrue(run.skipped.contains { $0.hasPrefix("SMS goes out when you tap Send") })
        XCTAssertTrue(sos.sosActive.value)
        XCTAssertEqual(SosRun.fromJson(settings.sosRunJson), run)
        let rows = store.all()
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.priority == 0 && $0.status == "queued" })
        XCTAssertEqual(rows.map { $0.channel }, ["iridium_0", "mesh_0", "sms_0"])
        XCTAssertEqual(rows[2].recipient, "+31600000000")
        // The satellite leg is the Bridge's frame, magic "MS".
        XCTAssertEqual(Array(rows[0].payload!.prefix(2)), Array("MS".utf8))
        XCTAssertTrue(SosMessages.containsAlarmWord(rows[1].textPreview))
        XCTAssertEqual(env.taks.count, 1)
        XCTAssertEqual(env.audits.first, "sos_activated trigger=button routes=sat, mesh, sms position=known")
        // The dispatcher's veto: this run's deliveries may go, another run's may not.
        XCTAssertTrue(sos.mayDeliver(rows[0]))
        var other = rows[0]
        other.msgRef = "sos:1:sat"
        XCTAssertFalse(sos.mayDeliver(other))
        XCTAssertTrue(
            sos.mayDeliver(
                MessageDelivery(msgRef: "msg:7", channel: "x", status: "queued", priority: 1, textPreview: "", createdAt: 0, updatedAt: 0)))
        sos.stop()
    }

    func testARouteThatCannotBeUsedIsSkippedWithASentence() async throws {
        let sos = makeController()
        env.imei = ""
        env.paired = false
        env.sms = false
        env.fix = nil
        await sos.start(test: false, trigger: "checkin")
        let run = try XCTUnwrap(sos.run.value)
        XCTAssertTrue(run.routes.isEmpty)
        XCTAssertEqual(
            run.skipped,
            [
                "Satellite: no satellite modem has been connected to this phone yet.", "Mesh: no mesh radio is paired with this phone.",
                "SMS: this device cannot send SMS.", "Hub: not set up on this phone.",
            ])
        XCTAssertEqual(run.trigger, "checkin")
        XCTAssertTrue(env.taks.isEmpty, "no position, no TAK")
        XCTAssertEqual(
            SosProgress.summary(SosProgress.routes(run, deliveries: [])), "No way to send it: add emergency contacts or connect your node.")
        sos.stop()
    }

    func testCancelStopsWhatWaitsAndTellsWhatWent() async throws {
        let sos = makeController()
        await sos.start(test: false, trigger: "button")
        let run = try XCTUnwrap(sos.run.value)
        // The satellite leg went out; the others still wait.
        let sat = try XCTUnwrap(store.all().first { $0.channel == "iridium_0" })
        try await store.setStatus(id: sat.id!, "sent", lastError: "", now: 0)
        await sos.cancel()
        let cancelled = try XCTUnwrap(sos.run.value)
        XCTAssertNotNil(cancelled.cancelledAt)
        XCTAssertFalse(cancelled.active)
        XCTAssertFalse(sos.sosActive.value)
        let rows = store.all()
        XCTAssertEqual(rows.filter { $0.status == "dead" && $0.lastError == "cancelled" }.count, 2, "the two waiting routes are stopped")
        let cancelRef = run.refPrefix + "cancel:sat"
        let cancellation = try XCTUnwrap(rows.first { $0.msgRef == cancelRef })
        XCTAssertEqual(cancellation.channel, "iridium_0")
        XCTAssertFalse(SosMessages.containsAlarmWord(cancellation.textPreview))
        XCTAssertEqual(env.audits.last, "sos_cancelled sos=\(run.id)")
        // A send that finished after the cancel gets its cancellation too, once.
        let mesh = try XCTUnwrap(rows.first { $0.channel == "mesh_0" && $0.msgRef.hasSuffix(":mesh") })
        await sos.onSent(mesh)
        await sos.onSent(mesh)
        XCTAssertEqual(store.all().filter { $0.msgRef == run.refPrefix + "cancel:mesh" }.count, 1)
        // Another SOS can start now.
        clock.add(1_000)
        await sos.start(test: false, trigger: "button")
        XCTAssertNotEqual(sos.run.value?.id, run.id)
        sos.stop()
    }

    func testATestRaisesNoAlarmAndARealSosReplacesIt() async throws {
        let sos = makeController()
        await sos.start(test: true, trigger: "button")
        let test = try XCTUnwrap(sos.run.value)
        XCTAssertTrue(test.test)
        XCTAssertFalse(sos.sosActive.value, "a test is not an SOS")
        for row in store.all() {
            XCTAssertFalse(SosMessages.containsAlarmWord(row.textPreview), row.textPreview)
        }
        // The satellite leg of a test with a fix is the position report frame.
        let sat = try XCTUnwrap(store.all().first { $0.channel == "iridium_0" })
        XCTAssertEqual(sat.textPreview, "Alarm test: position report to the Hub")
        XCTAssertEqual(Array(sat.payload!.prefix(4)), [0x4D, 0x53, 0x01, 0x01])
        XCTAssertTrue(env.taks.isEmpty)
        XCTAssertEqual(env.audits.first?.hasPrefix("sos_test "), true)
        // A second test does not start; a real SOS replaces the test.
        await sos.start(test: true, trigger: "button")
        XCTAssertEqual(sos.run.value?.id, test.id)
        clock.add(1_000)
        await sos.start(test: false, trigger: "button")
        let real = try XCTUnwrap(sos.run.value)
        XCTAssertFalse(real.test)
        XCTAssertNotEqual(real.id, test.id)
        XCTAssertTrue(
            store.all().filter { $0.msgRef.hasPrefix(test.refPrefix) }.allSatisfy { $0.status == "dead" },
            "the test's waiting routes were stopped")
        sos.stop()
    }

    func testRestoreBringsBackTheSavedRun() async throws {
        let sos = makeController()
        await sos.start(test: false, trigger: "button")
        let run = try XCTUnwrap(sos.run.value)
        sos.stop()
        let again = SosController(
            deliveries: FakeSosQueries(store), settings: settings, env: env, now: { 0 }, sleep: { _ in throw CancellationError() })
        XCTAssertNil(again.run.value)
        again.restore()
        XCTAssertEqual(again.run.value, run)
        XCTAssertTrue(again.sosActive.value)
        let words = SosController.notificationText(run, statuses: SosProgress.routes(run, deliveries: store.all()))
        XCTAssertEqual(words.title, "SOS is on")
        XCTAssertTrue(words.text.hasPrefix("Still trying satellite, mesh and SMS to Anna."))
        again.stop()
    }
}

final class DispatcherManualChannelTests: XCTestCase {
    private func queued(_ id: Int64, _ ref: String) -> MessageDelivery {
        MessageDelivery(
            id: id, msgRef: ref, channel: "sms_0", status: "queued", priority: 0, textPreview: "hi", createdAt: 0, updatedAt: 0,
            recipient: "+31600000000")
    }

    func testAManualChannelParksTheDeliveryForTheUser() async throws {
        // The fake store serves its pending rows once, so both are there from the start.
        let store = FakeDeliveryStore(rows: [queued(1, "msg:1"), queued(2, "msg:2")])
        let sent = Slept()
        let rules = EmptyRules()
        let disp = Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil, registry: ChannelRegistry(),
            deliveryCallback: { _, _, _, _, _, _ in
                sent.add(1)
                return nil
            }, pollIntervalMs: 20)
        disp.setManualChannels(["sms_0"])
        let hooked = Slept()
        disp.setOnSent { _ in hooked.add(1) }
        disp.startWorker("sms_0")
        for _ in 0..<300 where store.row(2)?.status != Dispatcher.awaitingUser { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.row(1)?.status, Dispatcher.awaitingUser)
        XCTAssertEqual(store.row(2)?.status, Dispatcher.awaitingUser)
        XCTAssertTrue(sent.values.isEmpty, "the callback never sends on a manual channel")
        await disp.userSent(deliveryId: 1)
        XCTAssertEqual(store.row(1)?.status, "sent")
        XCTAssertEqual(hooked.values.count, 1)
        await disp.userSent(deliveryId: 1)
        XCTAssertEqual(hooked.values.count, 1, "only once")
        await disp.userDeclined(deliveryId: 2)
        XCTAssertEqual(store.row(2)?.status, "dead")
        XCTAssertEqual(store.row(2)?.lastError, "not sent by you")
        disp.stop()
    }
}
