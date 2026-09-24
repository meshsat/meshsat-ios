// MqttNioSession against a real broker (MESHSAT-1324). The fakes in HubTests stand in for the
// session, so they could not see that received messages never reached `inbound`: mqtt-nio's
// AsyncSequence listener unregistered itself as soon as it was freed. Runs only when
// MESHSAT_TEST_MQTT_HOST names a plain MQTT broker on port 1883, e.g.
//   docker run -d --rm -p 1883:1883 eclipse-mosquitto:2 mosquitto -c /mosquitto-no-auth.conf
import Foundation
import MeshSatMQTT
import MeshSatNet
import XCTest

private struct Timeout: Error {}

final class MqttNioSessionBrokerTests: XCTestCase {
    func testAMessageOnASubscribedTopicReachesInboundAndARepliesGoesOut() async throws {
        guard let host = ProcessInfo.processInfo.environment["MESHSAT_TEST_MQTT_HOST"] else {
            throw XCTSkip("no MESHSAT_TEST_MQTT_HOST")
        }
        let phone = MqttNioSession(
            endpoint: MqttEndpoint(host: host, port: 1883, useTLS: false, useWebSockets: false, clientId: "phone-test"))
        let hub = MqttNioSession(endpoint: MqttEndpoint(host: host, port: 1883, useTLS: false, useWebSockets: false, clientId: "hub-test"))
        try await phone.connect(will: nil)
        try await hub.connect(will: nil)
        let phoneIn = phone.inbound.subscribe()
        let hubIn = hub.inbound.subscribe()
        try await phone.subscribe(["meshsat/bridge/t1/cmd"], qos: 1)
        try await hub.subscribe(["meshsat/bridge/t1/cmd/response"], qos: 1)

        // The phone answers every command it receives, as HubReporter answers a ping.
        let answer = Task {
            for await m in phoneIn {
                try? await phone.publish(topic: m.topic + "/response", payload: m.payload, qos: 1, retain: false)
                return m.topic
            }
            return ""
        }
        let reply = Task {
            for await m in hubIn { return String(decoding: m.payload, as: UTF8.self) }
            return ""
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await hub.publish(topic: "meshsat/bridge/t1/cmd", payload: Array(#"{"cmd":"ping"}"#.utf8), qos: 1, retain: false)

        let got = try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask { await reply.value }
            g.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw Timeout()
            }
            let first = try await g.next() ?? ""
            g.cancelAll()
            return first
        }
        let heard = await answer.value
        XCTAssertEqual(heard, "meshsat/bridge/t1/cmd")
        XCTAssertEqual(got, #"{"cmd":"ping"}"#)
        await phone.disconnect()
        await hub.disconnect()
    }
}
