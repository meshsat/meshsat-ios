// Mirrors HubTenantTopicsTest.kt and HubTenantWiringTest.kt (MESHSAT-1467, HeMB-NG contract C13):
// the bundle's topic root is "meshsat" or "meshsat/{tenant}" and nothing else, a bad one stops the
// Hub reporter before it connects, and the MQTT transport and its Reticulum interface publish and
// subscribe under the tenant's root.
import Foundation
import MeshSatHub
import MeshSatMQTT
import MeshSatNet
import MeshSatReticulum
import XCTest

final class HubTenantTests: XCTestCase {
    func testABundlesTopicRootIsMeshsatOrMeshsatSlashTenantAndNothingElse() {
        for (prefix, root) in ["": "meshsat", "meshsat": "meshsat", " meshsat/acme ": "meshsat/acme", "meshsat/t-1_x": "meshsat/t-1_x"] {
            XCTAssertEqual(HubTopics.checked(prefix)?.prefix, root, prefix)
        }
        let bad = [
            "acme", "meshsat/", "meshsat/acme/x", "meshsat/+", "meshsat/#", "meshsat/a.b", "meshsat/a b",
            "meshsat/bridge", "meshsat/broadcast", "meshsat/hub", "meshsat/relay", "meshsat/reticulum",
            "other/acme", "meshsat/" + String(repeating: "a", count: 65), "meshsat/é",
        ]
        for prefix in bad {
            XCTAssertNil(HubTopics.checked(prefix), prefix)
        }
    }

    func testABadTopicRootStopsTheReporterBeforeItConnects() {
        let session = FakeMQTTSession()
        let config = HubReporterConfig(hubUrl: "wss://hub.example/mqtt", bridgeId: "ios-test", topicPrefix: "meshsat/+")
        let reporter = HubReporter(config: config, host: FakeHubHost(), makeSession: { _ in session })
        reporter.start()
        XCTAssertEqual(reporter.state.value, .error)
        XCTAssertTrue(reporter.lastError.value.contains("meshsat/+"), reporter.lastError.value)
        XCTAssertTrue(session.published.isEmpty)
    }

    func testTheMqttTransportAndItsReticulumInterfaceUseTheTenantsRoot() async throws {
        let session = FakeMQTTSession()
        let t = MqttTransport(makeSession: { _ in session })
        t.connect(endpoint: MqttEndpoint.parse("tcp://broker:1883", clientId: "c")!, deviceId: "dev1", topicRoot: "meshsat/acme")
        XCTAssertEqual(t.topicRoot, "meshsat/acme")
        XCTAssertEqual(t.topicPosition, "meshsat/acme/dev1/position")
        XCTAssertEqual(
            t.subscriptions,
            [
                "meshsat/acme/dev1/mt/send", "meshsat/acme/dev1/tak/cot/in", "meshsat/acme/broadcast/tak/cot/in",
                "meshsat/acme/dev1/config/update", "meshsat/acme/dev1/sms/outbound", "meshsat/acme/dev1/reticulum/rx",
                "meshsat/reticulum/routes",
            ])
        let link = RootedLink(root: t.topicRoot)
        let rns = RnsMqttInterface(mqtt: link, deviceId: { "dev1" })
        let sent = await rns.send([1, 2, 3])
        XCTAssertNil(sent)
        XCTAssertEqual(link.topics, ["meshsat/acme/dev1/reticulum/tx"])
        t.disconnect()
    }
}

/// A Reticulum MQTT link with a tenant root, recording what it is asked to publish.
private final class RootedLink: RnsMqttLink, @unchecked Sendable {
    let topicRoot: String
    private let lock = NSLock()
    private var published: [String] = []
    init(root: String) { topicRoot = root }
    var isConnected: Bool { true }
    var topics: [String] {
        lock.lock()
        defer { lock.unlock() }
        return published
    }
    func publishRaw(topic: String, qos: Int, retained: Bool, payload: String) async throws {
        lock.withLock { published.append(topic) }
    }
}
