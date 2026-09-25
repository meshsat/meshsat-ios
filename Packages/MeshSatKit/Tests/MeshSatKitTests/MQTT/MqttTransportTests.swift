// MqttTransport has no Android unit test (Paho is mocked nowhere); these pin the Kotlin
// behaviour on the fake session: the topics, the subscriptions, the publishes, the inbound
// callback, and the reconnect with backoff after a drop.
import MeshSatNet
import XCTest

@testable import MeshSatMQTT

final class MqttTransportTests: XCTestCase {
    private let endpoint = MqttEndpoint(
        host: "broker.test", port: 1883, useTLS: false, useWebSockets: false, clientId: "meshsat-ios-12345678")

    private func waitUntil(_ cond: @escaping @Sendable () async -> Bool, ms: Int = 2000) async -> Bool {
        for _ in 0..<(ms / 5) {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }

    func testTopicsAndClientId() {
        let t = MqttTransport(makeSession: { _ in FakeMQTTSession() })
        XCTAssertEqual(MqttTransport.clientId(deviceId: "300434067943980"), "meshsat-ios-67943980")
        t.connect(endpoint: endpoint, deviceId: "dev1")
        XCTAssertEqual(t.topicPosition, "meshsat/dev1/position")
        XCTAssertEqual(t.topicHealth, "meshsat/dev1/status/health")
        XCTAssertEqual(
            t.subscriptions,
            [
                "meshsat/dev1/mt/send", "meshsat/dev1/tak/cot/in", "meshsat/broadcast/tak/cot/in", "meshsat/dev1/config/update",
                "meshsat/dev1/sms/outbound", "meshsat/dev1/reticulum/rx", "meshsat/reticulum/routes",
            ])
        t.disconnect()
    }

    func testConnectSubscribesPublishesAndDelivers() async throws {
        let session = FakeMQTTSession()
        let t = MqttTransport(makeSession: { _ in session }, now: { 1_700_000_000_000 })
        let received = AprsReceived<String>()
        t.setMessageCallback { topic, payload in received.add("\(topic)|\(payload)") }
        t.connect(endpoint: endpoint, deviceId: "dev1")
        let connected = await waitUntil { t.state.value == .connected }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.subscribed.count, 7)
        XCTAssertTrue(t.isConnected)
        await t.publishPosition(lat: 52.5, lon: 4.25, alt: 3)
        await t.publishSOS(triggered: true, lat: 1, lon: 2)
        await t.publishHealth(batteryPct: 80, uptime: 120)
        await t.publishSmsInbound(sender: "+31", text: "hi", rawText: "raw", wasEncrypted: true)
        try await t.publishRaw(topic: "meshsat/dev1/reticulum/tx", qos: 1, retained: false, payload: "AAEC")
        let published = session.published
        XCTAssertEqual(
            published.map(\.topic),
            [
                "meshsat/dev1/position", "meshsat/dev1/sos", "meshsat/dev1/status/health", "meshsat/dev1/sms/inbound",
                "meshsat/dev1/reticulum/tx",
            ])
        XCTAssertEqual(published[0].payload, "{\"alt\":3,\"lat\":52.5,\"lon\":4.25,\"source\":\"gps\",\"timestamp\":1700000000}")
        XCTAssertEqual(published[1].payload, "{\"lat\":1,\"lon\":2,\"timestamp\":1700000000,\"triggered\":true}")
        XCTAssertEqual(
            published[3].payload,
            "{\"compressed\":false,\"encrypted\":true,\"raw\":\"raw\",\"sender\":\"+31\",\"text\":\"hi\",\"timestamp\":1700000000}")
        session.deliver("meshsat/dev1/mt/send", "{\"text\":\"hello\"}")
        let first = try await received.first(timeoutMs: 2000)
        XCTAssertEqual(first, "meshsat/dev1/mt/send|{\"text\":\"hello\"}")
        t.disconnect()
        XCTAssertEqual(t.state.value, .disconnected)
        do {
            try await t.publishRaw(topic: "x", qos: 1, retained: false, payload: "y")
            XCTFail("disconnected")
        } catch {
            XCTAssertEqual(error as? MqttTransportError, .notConnected)
        }
    }

    func testReconnectsWithBackoffAfterADrop() async {
        let sessions = AprsReceived<FakeMQTTSession>()
        let slept = AprsReceived<Int64>()
        let t = MqttTransport(
            makeSession: { _ in
                let s = FakeMQTTSession()
                sessions.add(s)
                return s
            }, sleep: { slept.add($0) })
        t.connect(endpoint: endpoint, deviceId: "dev1")
        let first = await waitUntil { t.state.value == .connected }
        XCTAssertTrue(first)
        sessions.all[0].drop("broker went away")
        let again = await waitUntil { sessions.all.count >= 2 && t.state.value == .connected }
        XCTAssertTrue(again)
        XCTAssertEqual(slept.all.first, MqttTransport.connectRetryMinMs)
        t.disconnect()
    }

    func testFailedConnectRetriesAndBacksOff() async {
        let attempts = AprsReceived<Int>()
        let slept = AprsReceived<Int64>()
        let t = MqttTransport(
            makeSession: { _ in
                attempts.add(1)
                return FakeMQTTSession(failConnect: "refused")
            }, sleep: { slept.add($0) })
        t.connect(endpoint: endpoint, deviceId: "dev1")
        let tried = await waitUntil { attempts.all.count >= 3 }
        XCTAssertTrue(tried)
        t.disconnect()
        XCTAssertEqual(Array(slept.all.prefix(2)), [5_000, 10_000])
        XCTAssertEqual(t.state.value, .disconnected)
    }

    func testBlankConfigurationIsRefused() {
        let t = MqttTransport(makeSession: { _ in FakeMQTTSession() })
        t.connect(endpoint: MqttEndpoint(host: "", port: 1, useTLS: false, useWebSockets: false, clientId: "c"), deviceId: "d")
        XCTAssertEqual(t.state.value, .disconnected)
        t.connect(endpoint: endpoint, deviceId: "")
        XCTAssertEqual(t.state.value, .disconnected)
    }
}
