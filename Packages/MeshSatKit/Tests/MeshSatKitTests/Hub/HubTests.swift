// Mirrors HubProtocolTest.kt, HubConnectRetryTest.kt and HubConnectFailureTest.kt, and drives
// the reporter against a fake broker session (what Android could only check on a phone).
import Crypto
import Foundation
import MeshSatHub
import MeshSatNet
import XCTest

final class HubProtocolTests: XCTestCase {
    func testConstantsMatchTheBridge() {
        XCTAssertEqual(HubProtocol.version, "meshsat-uplink/v1")
        XCTAssertEqual(HubProtocol.cotBridge, "a-f-G-U-C-I")
        XCTAssertEqual(HubProtocol.cotSatModem, "a-f-G-E-S")
        XCTAssertEqual(HubProtocol.cotEmergency, "b-a")
        XCTAssertEqual(HubProtocol.deviceIridiumSbd, "iridium_sbd")
        XCTAssertEqual(HubProtocol.cotType(forDevice: HubProtocol.deviceIridiumImt), HubProtocol.cotSatModem)
        XCTAssertEqual(HubProtocol.cotType(forDevice: HubProtocol.deviceCellular), HubProtocol.cotCellModem)
        XCTAssertEqual(HubProtocol.cotType(forDevice: "unknown"), HubProtocol.cotMeshNode)
    }

    func testTopics() {
        let t = HubTopics()
        XCTAssertEqual(t.bridgeBirth("pi-01"), "meshsat/bridge/pi-01/birth")
        XCTAssertEqual(t.bridgeCmdResponse("pi-01"), "meshsat/bridge/pi-01/cmd/response")
        XCTAssertEqual(t.bridgeMOAck("pi-01"), "meshsat/bridge/pi-01/mo/ack")
        XCTAssertEqual(t.deviceBirth("pi-01", "mesh-abc"), "meshsat/bridge/pi-01/device/mesh-abc/birth")
        XCTAssertEqual(t.deviceSOS("dev-01"), "meshsat/dev-01/sos")
        XCTAssertEqual(t.deviceMODecoded("+31600000000"), "meshsat/%2B31600000000/mo/decoded")
        XCTAssertTrue(t.mayReceiveTakBroadcast)
        XCTAssertEqual(HubTopics.segment("a/b#c+%"), "a%2Fb%23c%2B%25")
    }

    func testBodiesCarryTheBridgesFields() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let birth = BridgeBirth(
            bridgeId: "ios-test", version: "0.1.0", hostname: "iPhone",
            interfaces: [InterfaceInfo(name: "ble_mesh_0", type: "meshtastic", status: "online")],
            capabilities: ["ios", "gps"], cotCallsign: "ALPHA-1", uptimeSec: 3600)
        let text = birth.toJson(now: now).text()
        XCTAssertTrue(
            text.hasPrefix(
                "{\"protocol\":\"meshsat-uplink/v1\",\"bridge_id\":\"ios-test\",\"version\":\"0.1.0\",\"hostname\":\"iPhone\""
                    + ",\"mode\":\"ios\",\"tenant_id\":\"default\",\"interfaces\":[{\"name\":\"ble_mesh_0\",\"type\":\"meshtastic\""
                    + ",\"status\":\"online\"}],\"capabilities\":[\"ios\",\"gps\"],\"cot_type\":\"a-f-G-U-C\""
                    + ",\"cot_callsign\":\"ALPHA-1\",\"uptime_sec\":3600,\"timestamp\":\"2026-09-21T"
            ), text)
        XCTAssertEqual(HubProtocol.isoTimestamp(now), "2026-09-21T14:13:20Z")
        let pos = DevicePosition(lat: 37.7749, lon: -122.4194, alt: 10, speed: 1.5, course: 270, source: "gps", bridgeId: "ios-test")
            .toJson(now: now)
        XCTAssertEqual(
            pos.text().dropLast(36),
            "{\"lat\":37.7749,\"lon\":-122.4194,\"alt\":10,\"speed\":1.5,\"course\":270,\"source\":\"gps\",\"bridge_id\":\"ios-test\"")
        let health = InterfaceHealth(name: "iridium_0", status: "online", signalBars: 4, signalDBm: -75).toJson().text()
        XCTAssertEqual(health, "{\"name\":\"iridium_0\",\"status\":\"online\",\"signal_bars\":4,\"signal_dbm\":-75}")
        let resp = CommandResponse(requestId: "r1", cmd: "unknown", status: "error", error: "unsupported command").toJson(now: now)
        XCTAssertEqual(resp.string("error"), "unsupported command")
        XCTAssertEqual(HubReporterConfig(hubUrl: "wss://hub.example", bridgeId: "abcdefghijklmnop").clientId, "meshsat-ios-efghijklmnop")
    }

    func testCanonicalJsonIsSortedAndUnspaced() {
        var b = JSONBody()
        b.put("z", "last \"quoted\"\n")
        b.put("a", 1.0)
        var inner = JSONBody()
        inner.put("y", true)
        inner.put("x", .null)
        b.put("m", inner)
        b.put("list", .array([.int(1), .double(2.5), .string("s")]))
        XCTAssertEqual(
            b.text(sortedKeys: true), "{\"a\":1,\"list\":[1,2.5,\"s\"],\"m\":{\"x\":null,\"y\":true},\"z\":\"last \\\"quoted\\\"\\n\"}")
        XCTAssertEqual(b.text(), "{\"z\":\"last \\\"quoted\\\"\\n\",\"a\":1,\"m\":{\"y\":true,\"x\":null},\"list\":[1,2.5,\"s\"]}")
        let parsed = JSONBody.parse(Data("{\"cmd\":\"ping\",\"request_id\":\"r7\",\"n\":3,\"f\":1.5,\"ok\":true}".utf8))
        XCTAssertEqual(parsed?.string("cmd"), "ping")
        XCTAssertEqual(parsed?.int("n"), 3)
        XCTAssertEqual(parsed?.bool("ok"), true)
        XCTAssertEqual(HubCommand.fromJson(parsed!), HubCommand(cmd: "ping", requestId: "r7"))
    }

    func testBirthSigningRoundTrip() throws {
        let key = P256.Signing.PrivateKey()
        var birth = BridgeBirth(bridgeId: "ios-test", version: "0.1.0", hostname: "iPhone").toJson(
            now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(
            BirthSigner.sign(&birth, certPem: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----", keyPem: key.pemRepresentation)
        )
        XCTAssertNotNil(birth.string("signature"))
        XCTAssertEqual(
            birth.string("certificate"), Data("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----".utf8).base64EncodedString())
        XCTAssertTrue(BirthSigner.verify(birth, publicKey: key.publicKey))
        var tampered = birth
        tampered.put("bridge_id", "someone-else")
        XCTAssertFalse(BirthSigner.verify(tampered, publicKey: key.publicKey))
        var unsigned = JSONBody()
        XCTAssertFalse(BirthSigner.sign(&unsigned, certPem: "", keyPem: key.pemRepresentation))
        var bad = JSONBody()
        XCTAssertFalse(BirthSigner.sign(&bad, certPem: "x", keyPem: "not a key"))
        XCTAssertNil(bad.string("certificate"))
    }

    func testTheWaitDoublesFromFiveSecondsAndStopsAtAMinute() {
        var waits: [Int64] = [HubReporter.connectRetryMinMs]
        for _ in 0..<6 { waits.append(HubReporter.nextConnectRetry(waits.last!)) }
        XCTAssertEqual(waits, [5_000, 10_000, 20_000, 40_000, 60_000, 60_000, 60_000])
        XCTAssertEqual(HubReporter.nextConnectRetry(0), HubReporter.connectRetryMinMs)
        XCTAssertEqual(HubReporter.nextConnectRetry(10 * 60_000), HubReporter.connectRetryMaxMs)
    }

    func testTheWrappedCauseIsShownAfterTheLibrarysWords() {
        let inner = NSError(domain: "tls", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chain validation failed"])
        let outer = NSError(
            domain: "mqtt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to connect to server", NSUnderlyingErrorKey: inner])
        XCTAssertEqual(HubReporter.connectFailureText(outer), "Unable to connect to server: Chain validation failed")
        let repeated = NSError(
            domain: "io", code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "connect failed: timeout",
                NSUnderlyingErrorKey: NSError(domain: "io", code: 4, userInfo: [NSLocalizedDescriptionKey: "timeout"]),
            ])
        XCTAssertEqual(HubReporter.connectFailureText(repeated), "connect failed: timeout")
        struct Plain: Error {}
        XCTAssertFalse(HubReporter.connectFailureText(Plain()).isEmpty)
    }
}

/// A broker in memory: records publishes and subscriptions, delivers what the test sends.
final class FakeMQTTSession: MQTTSession, @unchecked Sendable {
    struct Published: Equatable {
        let topic: String
        let payload: String
        let qos: Int
        let retain: Bool
    }

    private let lock = NSLock()
    private var connected = false
    private var failConnect: String?
    private(set) var will: MQTTWill?
    private var publishedList: [Published] = []
    private var subscribedList: [String] = []
    let inbound = Broadcast<MQTTInbound>(bufferSize: 16)
    let events = Broadcast<MQTTSessionEvent>(bufferSize: 4)

    init(failConnect: String? = nil) { self.failConnect = failConnect }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var published: [Published] { locked { publishedList } }
    var subscribed: [String] { locked { subscribedList } }
    var isConnected: Bool { get async { locked { connected } } }

    func connect(will: MQTTWill?) async throws {
        try locked {
            if let failConnect { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: failConnect]) }
            self.will = will
            connected = true
        }
    }

    func publish(topic: String, payload: [UInt8], qos: Int, retain: Bool) async throws {
        try locked {
            guard connected else { throw NSError(domain: "fake", code: 2, userInfo: [NSLocalizedDescriptionKey: "not connected"]) }
            publishedList.append(Published(topic: topic, payload: String(decoding: payload, as: UTF8.self), qos: qos, retain: retain))
        }
    }

    func subscribe(_ topics: [String], qos: Int) async throws {
        locked { subscribedList.append(contentsOf: topics) }
    }

    func disconnect() async { locked { connected = false } }

    func deliver(_ topic: String, _ text: String) { inbound.send(MQTTInbound(topic: topic, payload: Array(text.utf8))) }
}

final class FakeHubHost: HubReporterHost, @unchecked Sendable {
    private let lock = NSLock()
    private var ifaces: [InterfaceInfo] = [InterfaceInfo(name: "ble_mesh_0", type: "meshtastic", status: "online")]
    func setInterfaces(_ i: [InterfaceInfo]) {
        lock.lock()
        ifaces = i
        lock.unlock()
    }
    func interfaces() -> [InterfaceInfo] {
        lock.lock()
        defer { lock.unlock() }
        return ifaces
    }
    func interfaceHealth() -> [InterfaceHealth] { [InterfaceHealth(name: "ble_mesh_0", status: "online")] }
    func capabilities() -> [String] { ["ios", "gps", "ble_mesh"] }
    func location() -> HubLocation? { HubLocation(lat: 52.16, lon: 4.51, alt: 12) }
    func batteryPct() -> Double { 85 }
    func memPct() -> Double { 42.5 }
    func diskPct() -> Double { 60 }
    var appVersion: String { "0.1.0" }
    var deviceModel: String { "iPhone" }
}

final class HubReporterTests: XCTestCase {
    private func waitUntil(_ timeoutMs: Int = 5_000, _ cond: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private let config = HubReporterConfig(
        hubUrl: "wss://hub.example/mqtt", bridgeId: "ios-test", callsign: "ALPHA-1", healthIntervalSec: 1)

    func testConnectSubscribesAnnouncesWithAWillAndAnswersAPing() async {
        let session = FakeMQTTSession()
        let reporter = HubReporter(config: config, host: FakeHubHost(), makeSession: { _ in session })
        reporter.start()
        let announced = await waitUntil { session.published.contains { $0.topic == "meshsat/bridge/ios-test/birth" } }
        XCTAssertTrue(announced)
        XCTAssertEqual(reporter.state.value, .connected)
        XCTAssertEqual(session.will?.topic, "meshsat/bridge/ios-test/death")
        XCTAssertTrue(session.will.map { String(decoding: $0.payload, as: UTF8.self).contains("\"reason\":\"lwt\"") } ?? false)
        XCTAssertEqual(
            session.subscribed, ["meshsat/bridge/ios-test/cmd", "meshsat/broadcast/tak/cot/in", "meshsat/bridge/ios-test/mo/ack"])
        let birth = session.published.first { $0.topic.hasSuffix("/birth") }
        XCTAssertEqual(birth?.retain, true)
        XCTAssertEqual(birth?.qos, 1)
        XCTAssertTrue(birth?.payload.contains("\"cot_callsign\":\"ALPHA-1\"") ?? false)
        XCTAssertTrue(birth?.payload.contains("\"mode\":\"ios\"") ?? false)

        session.deliver("meshsat/bridge/ios-test/cmd", "{\"cmd\":\"ping\",\"request_id\":\"r1\"}")
        let answered = await waitUntil { session.published.contains { $0.topic == "meshsat/bridge/ios-test/cmd/response" } }
        XCTAssertTrue(answered)
        XCTAssertTrue(session.published.last?.payload.contains("\"request_id\":\"r1\"") ?? false)

        let ok = await reporter.publishMessage(
            deviceId: "+31600000000", text: "hello", recipient: "", channel: "sms", messageId: "ios-test-d7")
        XCTAssertTrue(ok)
        let mo = session.published.last
        XCTAssertEqual(mo?.topic, "meshsat/%2B31600000000/mo/decoded")
        XCTAssertTrue(
            mo?.payload.hasPrefix(
                "{\"id\":\"ios-test-d7\",\"imei\":\"+31600000000\",\"device_id\":\"+31600000000\",\"bridge_id\":\"ios-test\""
                    + ",\"text\":\"hello\",\"sos\":false,\"channel\":\"sms\",\"source\":\"ios\""
            ) ?? false, mo?.payload ?? "")

        // A health report comes on the interval, fire and forget.
        let health = await waitUntil(3_000) { session.published.contains { $0.topic == "meshsat/bridge/ios-test/health" && $0.qos == 0 } }
        XCTAssertTrue(health)
        await reporter.stop()
        XCTAssertEqual(session.published.last?.topic, "meshsat/bridge/ios-test/death")
        XCTAssertTrue(session.published.last?.payload.contains("\"reason\":\"shutdown\"") ?? false)
        XCTAssertEqual(reporter.state.value, .disconnected)
    }

    func testMoAcksAreValidatedAndCommandsForwarded() async {
        let session = FakeMQTTSession()
        let reporter = HubReporter(config: config, host: FakeHubHost(), makeSession: { _ in session })
        let acks = Changes()
        let commands = Changes()
        reporter.setMoAckCallback { imei, momsn in acks.add("\(imei):\(momsn)") }
        reporter.setCommandCallback { cmd in commands.add(cmd.cmd) }
        reporter.start()
        _ = await waitUntil { reporter.state.value == .connected }
        session.deliver("meshsat/bridge/ios-test/mo/ack", "{\"imei\":\"300434067943980\",\"momsn\":219}")
        session.deliver("meshsat/bridge/ios-test/mo/ack", "{\"imei\":\"12345\",\"momsn\":1}")
        session.deliver("meshsat/bridge/ios-test/mo/ack", "{\"imei\":\"300434067943980\",\"momsn\":70000}")
        session.deliver("meshsat/bridge/ios-test/cmd", "{\"cmd\":\"reboot\",\"request_id\":\"r9\"}")
        let got = await waitUntil { !commands.list.isEmpty }
        XCTAssertTrue(got)
        XCTAssertEqual(acks.list, ["300434067943980:219"])
        XCTAssertEqual(commands.list, ["reboot"])
        await reporter.stop()
    }

    func testAFailedFirstConnectIsTriedAgain() async {
        let clock = VirtualClock()
        let session = FakeMQTTSession(failConnect: "Unable to connect to server")
        let attempts = Changes()
        let reporter = HubReporter(
            config: config, host: FakeHubHost(),
            makeSession: { _ in
                attempts.add("try")
                return session
            }, clock: clock)
        reporter.start()
        let failed = await waitUntil { reporter.state.value == .error || attempts.list.count >= 2 }
        XCTAssertTrue(failed)
        XCTAssertEqual(reporter.lastError.value, "Unable to connect to server")
        let retried = await waitUntil { attempts.list.count >= 2 }
        XCTAssertTrue(retried, "a second attempt after the backoff")
        await reporter.stop()
    }

    func testSosGoesOnBothTopicsAndATestOnlyOnTheEvent() async {
        let session = FakeMQTTSession()
        let reporter = HubReporter(config: config, host: FakeHubHost(), makeSession: { _ in session })
        reporter.start()
        _ = await waitUntil { reporter.state.value == .connected }
        let ok = await reporter.publishSos(
            deviceId: "300434067943980", id: "sos-1", text: "SOS: flaneur needs help", sos: true, type: "sos", lat: 52.16, lon: 4.51)
        XCTAssertTrue(ok)
        let topics = session.published.suffix(2).map(\.topic)
        XCTAssertEqual(topics, ["meshsat/300434067943980/mo/decoded", "meshsat/300434067943980/sos"])
        XCTAssertTrue(session.published.last?.payload.contains("\"type\":\"sos\"") ?? false)
        _ = await reporter.publishSos(
            deviceId: "300434067943980", id: "t-1", text: "Test", sos: false, type: "test", lat: nil, lon: nil, asMessage: false)
        XCTAssertEqual(session.published.last?.topic, "meshsat/300434067943980/sos")
        XCTAssertFalse(session.published.last?.payload.contains("\"lat\"") ?? true)
        await reporter.stop()
    }

    /// The Hub checks a birth's signature over Go's re-marshalling of it (birthverify.go). The
    /// expected text is Go 1.24's json.Marshal of this map, produced on the runner: sorted keys,
    /// < > & and U+2028 escaped, 100.0 as 100, 1e-7 and 0.000001 in Go's spelling.
    func testCanonicalJsonIsByteForByteWhatGoMarshals() throws {
        // Fixtures/birth-input.json and birth-canonical-go.json (the latter written by Go 1.24).
        let fixtures = { (name: String) in Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")! }
        let input = try String(contentsOf: fixtures("birth-input"), encoding: .utf8)
        let go = try String(contentsOf: fixtures("birth-canonical-go"), encoding: .utf8)
        var body = JSONBody.parse(Data(input.utf8))!
        body.remove("signature")
        XCTAssertEqual(body.text(sortedKeys: true), go)
    }

    func testNumbersInGosSpelling() {
        XCTAssertEqual(JSONBody.number(1e-7), "1e-7")
        XCTAssertEqual(JSONBody.number(0.000001), "0.000001")
        XCTAssertEqual(JSONBody.number(1.5e21), "1.5e+21")
        XCTAssertEqual(JSONBody.number(123456789012345678.0), "123456789012345680")
        XCTAssertEqual(JSONBody.number(-0.25), "-0.25")
        XCTAssertEqual(JSONBody.number(52.370216), "52.370216")
    }

    func testACustomerTenantsTopicsHangOffItsPrefix() {
        let t = HubTopics(prefix: "meshsat/acme")
        XCTAssertEqual(t.bridgeCmd("b-1"), "meshsat/acme/bridge/b-1/cmd")
        XCTAssertEqual(t.devicePosition("+31612345678"), "meshsat/acme/%2B31612345678/position")
        XCTAssertFalse(t.mayReceiveTakBroadcast)
        XCTAssertEqual(HubTopics(prefix: "").prefix, "meshsat")
        XCTAssertEqual(HubTopics(prefix: "meshsat/acme/").prefix, "meshsat/acme")
    }
}
