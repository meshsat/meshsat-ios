// The broker URL forms Android's settings hold, parsed the way Paho read them.
import MeshSatMQTT
import XCTest

final class MqttEndpointTests: XCTestCase {
    func testSchemesAndDefaultPorts() {
        let wss = MqttEndpoint.parse("wss://hub.meshsat.net/mqtt", clientId: "c")
        XCTAssertEqual(wss?.host, "hub.meshsat.net")
        XCTAssertEqual(wss?.port, 443)
        XCTAssertEqual(wss?.useTLS, true)
        XCTAssertEqual(wss?.useWebSockets, true)
        XCTAssertEqual(wss?.webSocketPath, "/mqtt")
        let ssl = MqttEndpoint.parse("ssl://broker.example:8884", clientId: "c")
        XCTAssertEqual(ssl?.port, 8884)
        XCTAssertEqual(ssl?.useTLS, true)
        XCTAssertEqual(ssl?.useWebSockets, false)
        let tcp = MqttEndpoint.parse("tcp://10.42.24.5", clientId: "c")
        XCTAssertEqual(tcp?.port, 1883)
        XCTAssertEqual(tcp?.useTLS, false)
        XCTAssertEqual(MqttEndpoint.parse("ws://h", clientId: "c")?.port, 80)
        XCTAssertNil(MqttEndpoint.parse("http://h", clientId: "c"))
        XCTAssertNil(MqttEndpoint.parse("", clientId: "c"))
        XCTAssertFalse(tcp?.hasClientCertificate ?? true)
    }

    func testASessionRefusesToPublishBeforeConnecting() async {
        let session = MqttNioSession(endpoint: MqttEndpoint.parse("tcp://127.0.0.1:1", clientId: "c")!)
        let connected = await session.isConnected
        XCTAssertFalse(connected)
        do {
            try await session.publish(topic: "t", payload: [1], qos: 1, retain: false)
            XCTFail("published without a connection")
        } catch {
            XCTAssertEqual(error as? MqttNioSession.SessionError, .notConnected)
        }
        await session.disconnect()
    }
}
