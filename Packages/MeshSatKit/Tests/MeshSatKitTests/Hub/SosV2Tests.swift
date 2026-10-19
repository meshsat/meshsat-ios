// Ports SosV2Test.kt: an SOS under its own identity (HeMB-NG stage 2, C10, MESHSAT-1584) against
// the shared cases (fixtures-v1.1 sos.json, which the Bridge's, the Hub's and Android's tests
// read too), and the controller driven through a start, the Hub's acks and a cancel with a fake
// Hub session and a clock the test moves.
import MeshSatNet
import MeshSatWire
import XCTest

@testable import MeshSatEngine
@testable import MeshSatHub

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
private func bytes(_ h: String) -> [UInt8] {
    let a = Array(h.utf8)
    return stride(from: 0, to: a.count, by: 2).map { UInt8(String(decoding: a[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
}
private func be32(_ b: [UInt8], at i: Int) -> Int64 { Int64(b[i]) << 24 | Int64(b[i + 1]) << 16 | Int64(b[i + 2]) << 8 | Int64(b[i + 3]) }
private func str(_ d: [String: Any], _ k: String) throws -> String { try XCTUnwrap(d[k] as? String, k) }
private func i64(_ d: [String: Any], _ k: String) throws -> Int64 { try XCTUnwrap((d[k] as? NSNumber)?.int64Value, k) }
private func obj(_ d: [String: Any], _ k: String) throws -> [String: Any] { try XCTUnwrap(d[k] as? [String: Any], k) }
private func objs(_ d: [String: Any], _ k: String) throws -> [[String: Any]] { try XCTUnwrap(d[k] as? [[String: Any]], k) }

final class SosV2Tests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sos", withExtension: "json", subdirectory: "Fixtures/hemb-ng/v1"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private let fix = SosMessages.Fix(lat: 52.16, lon: 4.49, accuracyM: nil, timeMs: 0)

    func testTheC10FramesAreTheFixturesBytes() throws {
        var n = 0
        for f in try objs(try fixture(), "frames") {
            guard let d = f["decoded"] as? [String: Any] else { continue }
            let want = bytes(try str(f, "hex"))
            let id = try XCTUnwrap(HubMsgIds.parseCanonical(try str(d, "sos_id")))
            let start = try i64(d, "run_start_ms")
            let got: [UInt8]
            switch try str(f, "type") {
            case "0x07":
                got = SosMessages.satFrameStart(
                    bridgeId: try str(d, "bridge_id"), deviceId: try str(d, "device_id"), fix: fix, message: try str(d, "text"),
                    nowSec: be32(want, at: want.count - 28), sosId: id, runStartMs: start)
            case "0x08":
                got = SosMessages.cancelFrame(
                    bridgeId: try str(d, "bridge_id"), sosId: id, runStartMs: start, nowSec: be32(want, at: want.count - 5),
                    reason: UInt8(Int(try i64(d, "reason"))))
            default: return XCTFail("type \(f["type"]!)")
            }
            let name = try str(f, "case")
            XCTAssertEqual(hex(got), hex(want), name)
            n += 1
        }
        XCTAssertGreaterThanOrEqual(n, 6)
    }

    func testThe07IsThe02BodyAndTheRunsIdentityAndThe02IsUnchanged() throws {
        let fx = try fixture()
        let old = bytes(try str(try objs(fx, "frames")[0], "hex"))
        let sec = be32(old, at: old.count - 4)
        XCTAssertEqual(
            hex(SosMessages.satFrame(bridgeId: "kit-a", deviceId: "", fix: fix, message: "Injured, need help", nowSec: sec)), hex(old))
        let legacy = try obj(fx, "legacy_sos_id")
        let start = SosMessages.satFrameStart(
            bridgeId: "kit-a", deviceId: "", fix: fix, message: "Injured, need help", nowSec: sec,
            sosId: HubMsgIds.parseCanonical(try str(legacy, "sos_id"))!, runStartMs: try i64(legacy, "run_start_ms"))
        XCTAssertEqual(start[3], SosMessages.typeSosStart)
        XCTAssertEqual(hex(Array(start[4..<old.count])), hex(Array(old[4...])))
        XCTAssertEqual(start.count, old.count + 24)
        // A long bridge id goes whole: the Hub matches it against the modem's bridge.
        let longId = "a-very-long-bridge-id-here"
        let id = HubMsgIds.parseCanonical(HubMsgIds.newSosId(1_792_330_000_123))!
        let long = SosMessages.satFrameStart(bridgeId: longId, deviceId: "", fix: nil, message: "SOS", nowSec: 0, sosId: id, runStartMs: 0)
        XCTAssertEqual(Int(long[4]), longId.utf8.count)
    }

    func testTheSosIdRuleIsTheFixtures() throws {
        let fx = try fixture()
        var n = 0
        for f in try objs(fx, "frames") {
            guard let d = f["decoded"] as? [String: Any], let valid = f["valid"] as? Bool else { continue }
            let name = try str(f, "case")
            XCTAssertEqual(
                HubMsgIds.sosIdValid(
                    try str(d, "sos_id"), bridgeId: try str(d, "bridge_id"), runStartMs: try i64(d, "run_start_ms")),
                valid, name)
            n += 1
        }
        XCTAssertGreaterThanOrEqual(n, 7)
        let l = try obj(fx, "legacy_sos_id")
        XCTAssertEqual(
            HubMsgIds.legacySosId(bridgeId: try str(l, "bridge_id"), runStartMs: try i64(l, "run_start_ms")),
            try str(l, "sos_id"))
        let id = HubMsgIds.newSosId(1_792_330_000_123)
        XCTAssertTrue(HubMsgIds.validV7(id) && HubMsgIds.sosIdValid(id, bridgeId: "kit-a", runStartMs: 1_792_330_000_123))
        XCTAssertFalse(HubMsgIds.sosIdValid(id, bridgeId: "kit-a", runStartMs: 1_792_330_000_124))
        XCTAssertNotEqual(id, HubMsgIds.newSosId(1_792_330_000_123))
        XCTAssertTrue(HubMsgIds.idValid(id, field: "mid"), "any other v7 field is not tied to a start")
    }

    private func run(_ sosId: String, start: Int64 = 1_792_330_000_123, cancelledAt: Int64? = nil) -> SosRun {
        var r = SosRun(
            id: start, test: false, trigger: "button", name: "Kyriakos", fix: fix, routes: [], skipped: [], hubWanted: true, deviceId: "",
            hubAlertId: "x", cancelledAt: cancelledAt)
        r.sosId = sosId
        return r
    }

    func testTheEventsReadAsTheFixturesRunStartMsAlwaysThere() throws {
        var n = 0
        for c in try objs(try fixture(), "mqtt") {
            let want = try obj(c, "json")
            if !(c["valid"] as? Bool ?? false) {
                XCTAssertNil(want["run_start_ms"], "the invalid case changed")
                continue
            }
            let r = run(try str(want, "sos_id"), start: try i64(want, "run_start_ms"), cancelledAt: 1_792_330_600_000)
            let ev = try str(want, "kind") == "start" ? SosV2.startEvent(r, text: try str(want, "text")) : SosV2.cancelEvent(r)
            let got = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ev.text().utf8)) as? [String: Any])
            for (k, v) in want { XCTAssertEqual("\(got[k] ?? "missing")", "\(v)", "\(c["case"]!): \(k)") }
            for k in got.keys { XCTAssertTrue(want[k] != nil || k == "timestamp" || k == "device_id", "\(c["case"]!): an extra \(k)") }
            n += 1
        }
        XCTAssertEqual(n, 2)
    }

    func testHubCapsAndAcks() {
        XCTAssertTrue(SosV2.capsSayV2(#"{"v":1,"caps":["sos_v2"]}"#))
        XCTAssertTrue(SosV2.capsSayV2(#"{"v":1,"caps":["other","sos_v2"]}"#))
        for no in ["", #"{"v":1,"caps":[]}"#, #"{"v":2,"caps":["sos_v2"]}"#, "not json"] { XCTAssertFalse(SosV2.capsSayV2(no), no) }
        XCTAssertEqual(
            SosV2.parseAck(#"{"v":2,"sos_id":"01a14f31-66fb-7a7b-bc7d-7e7f80818283","kind":"cancel","state":"cancelled","rev":2}"#),
            SosV2.Ack(sosId: "01a14f31-66fb-7a7b-bc7d-7e7f80818283", kind: "cancel", state: "cancelled", rev: 2))
        for bad in [#"{"v":1,"sos_id":"x","kind":"start"}"#, #"{"v":2,"kind":"start"}"#, #"{"v":2,"sos_id":"x","kind":"stop"}"#, "[]"] {
            XCTAssertNil(SosV2.parseAck(bad), bad)
        }
        XCTAssertEqual((1...4).map { SosV2.repeatAfter($0) }, [15_000, 30_000, 60_000, 60_000])
    }

    func testTheCancelFrameWaitsForTheHubsAckAndTheCancelEndsAfterADay() {
        let at: Int64 = 1_792_330_600_000
        var r = run(HubMsgIds.newSosId(1_792_330_000_123), cancelledAt: at)
        r.satV2 = true
        r.cancelV2Owed = true
        XCTAssertTrue(SosV2.cancelPending(r))
        XCTAssertFalse(SosV2.cancelFrameDue(r, nowMs: at + 1_000, hubUp: true, satStartWent: true))
        XCTAssertTrue(SosV2.cancelFrameDue(r, nowMs: at + SosV2.cancelAckGraceMs, hubUp: true, satStartWent: true))
        XCTAssertTrue(SosV2.cancelFrameDue(r, nowMs: at, hubUp: false, satStartWent: true))
        XCTAssertFalse(SosV2.cancelFrameDue(r, nowMs: at, hubUp: false, satStartWent: false))
        var acked = r
        acked.cancelHubAckedAt = at + 1
        XCTAssertFalse(SosV2.cancelPending(acked))
        XCTAssertFalse(SosV2.cancelOver(r, nowMs: at + SosV2.cancelForMs - 1))
        XCTAssertTrue(SosV2.cancelOver(r, nowMs: at + SosV2.cancelForMs))
        XCTAssertFalse(SosV2.hubLegV2(r, capsV2: false))
        XCTAssertTrue(SosV2.hubLegV2(r, capsV2: true))
    }

    func testARunKeepsItsC10StateAcrossARestartAndAnOldRunReadsWithNone() {
        var r = run(HubMsgIds.newSosId(1_792_330_000_123), cancelledAt: 1_792_330_600_000)
        r.bridgeId = "kit-a"
        r.satV2 = true
        r.hubV2 = true
        r.hubPublishedAt = 1
        r.hubSentAt = 2
        r.hubState = "active"
        r.cancelV2Owed = true
        r.cancelHubPublishedAt = 3
        r.cancelHubAckedAt = 4
        r.cancelFrameDone = true
        r.cancelGaveUp = true
        XCTAssertEqual(SosRun.fromJson(r.toJson()), r)
        let old = SosRun.fromJson(
            #"{"id":1792330000123,"name":"K","routes":[],"skipped":[],"hub_wanted":true,"device_id":"","hub_alert_id":"x"}"#)!
        XCTAssertEqual(old.sosId, "")
        XCTAssertFalse(old.satV2 || old.hubV2 || old.cancelV2Owed)
    }
}

/// The Hub session for the controller tests: it records what the SOS publishes.
final class FakeSosHub: SosHubLink, @unchecked Sendable {
    private let lock = NSLock()
    private var upValue: Bool
    private(set) var events: [JSONBody] = []
    private(set) var oldWay = 0
    let bridgeId = "msa-flaneur"
    init(up: Bool) { upValue = up }
    var up: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return upValue
        }
        set {
            lock.lock()
            upValue = newValue
            lock.unlock()
        }
    }
    var isConnected: Bool { get async { up } }
    // swiftlint:disable:next function_parameter_count
    func publishSos(deviceId: String, id: String, text: String, sos: Bool, type: String, lat: Double?, lon: Double?, asMessage: Bool) async
        -> Bool
    {
        guard up else { return false }
        noteOldWay()
        return true
    }
    func publishSosEvent(_ event: JSONBody) async -> Bool {
        guard up else { return false }
        note(event)
        return true
    }
    private func noteOldWay() {
        lock.lock()
        oldWay += 1
        lock.unlock()
    }
    private func note(_ event: JSONBody) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    func count(_ kind: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.string("kind") == kind }.count
    }
}

final class SosV2ControllerTests: XCTestCase {
    private var store: FakeDeliveryStore!
    private var settings: FakeSosSettings!
    private var env: FakeSosEnv!
    private var clock: Slept!
    private var hub: FakeSosHub!

    private func makeController(sosV2: Bool, up: Bool) -> SosController {
        store = FakeDeliveryStore(rows: [])
        settings = FakeSosSettings()
        env = FakeSosEnv()
        clock = Slept()
        clock.add(1_792_330_000_123)
        hub = FakeSosHub(up: up)
        env.hub = hub
        if sosV2 { settings.hubCapsJson = #"{"v":1,"caps":["sos_v2"]}"# }
        let rules = EmptyRules()
        env.dispatcher = Dispatcher(
            store: store, accessEvaluator: AccessEvaluator(rules: rules, groups: rules), failoverResolver: nil, registry: ChannelRegistry(),
            deliveryCallback: { _, _, _, _, _, _ in nil })
        let clock = self.clock!
        return SosController(
            deliveries: FakeSosQueries(store), settings: settings, env: env, now: { clock.values.reduce(0, +) },
            sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) })
    }

    private func eventually(_ what: String, _ cond: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !(await cond()) {
            if Date() > deadline { return XCTFail("\(what): never") }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testWithoutTheHubsCapsTheSosGoesTheOldWay() async throws {
        let sos = makeController(sosV2: false, up: true)
        await sos.start(test: false, trigger: "button")
        await eventually("the old-way publish") { hub.oldWay > 0 }
        let r = try XCTUnwrap(sos.run.value)
        XCTAssertTrue(HubMsgIds.sosIdValid(r.sosId, bridgeId: "x", runStartMs: r.id), "the run keeps its own id all the same")
        XCTAssertEqual(store.all().first { $0.channel == "iridium_0" }?.payload?[3], 0x02)
        XCTAssertEqual(hub.count("start"), 0)
        sos.stop()
    }

    func testUnderSosV2TheFrameAndTheHubLegCarryTheRunsIdentityUntilTheAck() async throws {
        let sos = makeController(sosV2: true, up: true)
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        let frame = Array(try XCTUnwrap(store.all().first { $0.channel == "iridium_0" }?.payload))
        XCTAssertEqual(frame[3], SosMessages.typeSosStart)
        XCTAssertEqual(Array(frame[(frame.count - 24)..<(frame.count - 8)]), HubMsgIds.parseCanonical(r.sosId))
        XCTAssertTrue(r.satV2)
        await eventually("the v2 start") { hub.count("start") > 0 }
        XCTAssertEqual(hub.oldWay, 0, "nothing goes the old way")
        let ev = try XCTUnwrap(hub.events.first)
        XCTAssertEqual(ev.string("sos_id"), r.sosId)
        XCTAssertEqual(ev.int("run_start_ms"), r.id)
        await eventually("published") { sos.run.value?.hubPublishedAt != nil }
        XCTAssertNil(sos.run.value?.hubSentAt, "the broker having it is not the Hub having it")
        // Published again once the repeat is due.
        let n = hub.count("start")
        clock.add(16_000)
        await eventually("the start again") { hub.count("start") > n }
        await sos.onAck(#"{"v":2,"sos_id":"\#(r.sosId)","kind":"start","state":"active","rev":1}"#)
        XCTAssertNotNil(sos.run.value?.hubSentAt)
        XCTAssertEqual(sos.run.value?.hubState, "active")
        try? await Task.sleep(nanoseconds: 20_000_000)
        let m = hub.count("start")
        clock.add(3_600_000)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(hub.count("start"), m, "nothing after the ack")
        // An ack for another run changes nothing.
        await sos.onAck(#"{"v":2,"sos_id":"\#(HubMsgIds.newSosId(1))","kind":"cancel","state":"cancelled","rev":1}"#)
        XCTAssertNil(sos.run.value?.cancelHubAckedAt)
        sos.stop()
    }

    func testTheCancelRepeatsUntilItsAckAndTheFrameWaitsForIt() async throws {
        let sos = makeController(sosV2: true, up: true)
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        await eventually("the v2 start") { hub.count("start") > 0 }
        await sos.onAck(#"{"v":2,"sos_id":"\#(r.sosId)","kind":"start","state":"active","rev":1}"#)
        let sat = try XCTUnwrap(store.all().first { $0.msgRef == r.refPrefix + "sat" })
        try await store.setStatus(id: sat.id!, "sent", lastError: "", now: 0)
        await sos.cancel()
        let cancelled = try XCTUnwrap(sos.run.value)
        XCTAssertTrue(cancelled.cancelV2Owed)
        XCTAssertNil(store.all().first { $0.msgRef == r.refPrefix + "cancel:sat" }, "no text and no frame inside the grace")
        await eventually("the v2 cancel") { hub.count("cancel") > 0 }
        clock.add(SosV2.cancelAckGraceMs + 1_000)
        await eventually("the 0x08 after the grace") { store.all().contains { $0.msgRef == r.refPrefix + "cancel:sat" } }
        let row = try XCTUnwrap(store.all().first { $0.msgRef == r.refPrefix + "cancel:sat" })
        let want = SosMessages.cancelFrame(
            bridgeId: "msa-flaneur", sosId: HubMsgIds.parseCanonical(r.sosId)!, runStartMs: r.id, nowSec: cancelled.cancelledAt! / 1000)
        XCTAssertEqual(row.payload.map { hex(Array($0)) }, hex(want))
        XCTAssertEqual(row.channel, "iridium_0")
        XCTAssertEqual(row.priority, 0)
        await sos.onAck(#"{"v":2,"sos_id":"\#(r.sosId)","kind":"cancel","state":"cancelled","rev":2}"#)
        XCTAssertEqual(
            store.all().first { $0.msgRef == r.refPrefix + "cancel:sat" }?.status, "dead", "the ack stops the frame still waiting")
        XCTAssertNotNil(sos.run.value?.cancelHubAckedAt)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let n = hub.count("cancel")
        clock.add(3_600_000)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(hub.count("cancel"), n, "nothing after the ack")
        sos.stop()
    }

    func testWithoutAHubSessionTheFrameGoesAtOnceForADayAtMost() async throws {
        let sos = makeController(sosV2: true, up: false)
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        let sat = try XCTUnwrap(store.all().first { $0.msgRef == r.refPrefix + "sat" })
        try await store.setStatus(id: sat.id!, "sent", lastError: "", now: 0)
        await sos.cancel()
        await eventually("the 0x08 at once") { store.all().contains { $0.msgRef == r.refPrefix + "cancel:sat" } }
        clock.add(SosV2.cancelForMs + 60_000)
        await eventually("stopped after a day") { store.all().first { $0.msgRef == r.refPrefix + "cancel:sat" }?.status == "dead" }
        await eventually("given up") { sos.run.value?.cancelGaveUp == true }
        XCTAssertEqual(hub.count("cancel"), 0)
        sos.stop()
    }

    func testACancelBeforeTheStartWentOwesNothing() async throws {
        let sos = makeController(sosV2: true, up: false)
        await sos.start(test: false, trigger: "button")
        let r = try XCTUnwrap(sos.run.value)
        await sos.cancel()
        hub.up = true
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(try XCTUnwrap(sos.run.value).cancelV2Owed)
        XCTAssertEqual(hub.count("cancel"), 0)
        XCTAssertNil(store.all().first { $0.msgRef == r.refPrefix + "cancel:sat" })
        sos.stop()
    }

    func testARunFromBeforeC10TakesTheOldFormatIdOnRestore() throws {
        let sos = makeController(sosV2: true, up: false)
        settings.sosRunJson =
            #"{"id":1792330000123,"name":"K","routes":[],"skipped":[],"hub_wanted":true,"device_id":"","hub_alert_id":"x","#
            + #""cancelled_at":1792330600000}"#
        sos.restore()
        XCTAssertEqual(sos.run.value?.sosId, HubMsgIds.legacySosId(bridgeId: "msa-flaneur", runStartMs: 1_792_330_000_123))
        XCTAssertTrue(settings.sosRunJson.contains(#""sos_id""#))
        sos.stop()
    }
}
