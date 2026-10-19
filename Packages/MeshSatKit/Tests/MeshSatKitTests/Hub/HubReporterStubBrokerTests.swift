// HubReporter over a real MqttNioSession against scripts/mqtt-stub-broker.py, which refuses chosen
// SUBACK codes and closes the socket on cue (r13 review, PH-R2): a filter refused on the first
// connect and on an automatic reconnect is tried again on the same connection, the route's walk and
// publishes wait for it, and a drop during setup ends that connection's attempts. The scenario is a
// word in the bridge id (see the script). Runs only when MESHSAT_TEST_STUB_MQTT_HOST names the stub
// (port MESHSAT_TEST_STUB_MQTT_PORT, default 18883):
//   scripts/mqtt-stub-broker.py 127.0.0.1 18883 600
// [MESHSAT-1584]
import Foundation
import MeshSatMQTT
import MeshSatNet
import XCTest

@testable import MeshSatHub

final class HubReporterStubBrokerTests: XCTestCase {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var hooks: [Bool] = []
        private var hookTimes: [Date] = []
        private var seen: [HubReporter.State] = []
        private var connectedTimes: [Date] = []
        let r: HubReporter
        private var watcher: Task<Void, Never>?

        init(host: String, port: Int, bridgeId: String) {
            let config = HubReporterConfig(hubUrl: "mqtt://\(host):\(port)", bridgeId: bridgeId, healthIntervalSec: 300)
            r = HubReporter(
                config: config, host: FakeHubHost(),
                makeSession: { c in
                    MqttNioSession(
                        endpoint: MqttEndpoint(host: host, port: port, useTLS: false, useWebSockets: false, clientId: c.clientId))
                })
            r.setMsgCallbacks(onIn: { _ in }, onStatus: { _ in }, onConnected: { [unowned self] in self.hook(self.r.isMsgReady) })
            watcher = Task { [unowned self] in
                while !Task.isCancelled {
                    self.see(self.r.state.value)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }

        private func hook(_ ready: Bool) {
            lock.lock()
            hooks.append(ready)
            hookTimes.append(Date())
            lock.unlock()
        }

        private func see(_ s: HubReporter.State) {
            lock.lock()
            if seen.last != s {
                seen.append(s)
                if s == .connected { connectedTimes.append(Date()) }
            }
            lock.unlock()
        }

        /// What isMsgReady read each time the route's connected hook ran.
        var readyAtHook: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return hooks
        }

        /// How long after the nth connect (0-based) the nth walk began.
        func walkDelay(_ n: Int) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            guard hookTimes.count > n, connectedTimes.count > n else { return -1 }
            return hookTimes[n].timeIntervalSince(connectedTimes[n])
        }

        /// The reporter's states in order, each change once.
        var states: [HubReporter.State] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func stop() async {
            watcher?.cancel()
            await r.stop()
        }
    }

    private func probe(_ word: String) throws -> Probe {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MESHSAT_TEST_STUB_MQTT_HOST"] else { throw XCTSkip("no MESHSAT_TEST_STUB_MQTT_HOST") }
        let port = Int(env["MESHSAT_TEST_STUB_MQTT_PORT"] ?? "") ?? 18883
        let run = UUID().uuidString.prefix(4).lowercased()
        return Probe(host: host, port: port, bridgeId: "i-\(word)-\(run)")
    }

    private func waitUntil(_ ms: Int, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await cond()
    }

    func testAFilterRefusedOnTheFirstConnectIsTriedAgainOnTheSameConnectionAndTheWalkWaits() async throws {
        let p = try probe("refuse1")
        p.r.start()
        let up = await waitUntil(10_000) { p.r.state.value == .connected }
        XCTAssertTrue(up)
        let t0 = Date()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(p.r.isMsgReady, "not ready on a refused SUBACK")
        XCTAssertEqual([], p.readyAtHook)
        let early = await p.r.publishMsg(kind: "out", payload: "{}")
        XCTAssertEqual(.notSent, early)
        let walked = await waitUntil(15_000) { p.readyAtHook.count == 1 }
        XCTAssertTrue(walked, "tried again without a reconnect")
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), 1.0, "after the retry's wait")
        XCTAssertEqual([true], p.readyAtHook)
        XCTAssertEqual(1, p.states.filter { $0 == .connected }.count, "the connection stayed up: \(p.states)")
        let sent = await p.r.publishMsg(kind: "out", payload: "{}")
        XCTAssertEqual(.ok, sent)
        await p.stop()
    }

    func testAnAutomaticReconnectIsUnreadyAtOnceAndItsRefusedResubscribeIsTriedAgain() async throws {
        let p = try probe("reconn1")
        p.r.start()
        let ready = await waitUntil(10_000) { p.readyAtHook.count == 1 && p.r.isMsgReady }
        XCTAssertTrue(ready)
        // The stub closes the socket 3 s after the SUBACK.
        let lost = await waitUntil(10_000) { !p.r.isMsgReady }
        XCTAssertTrue(lost, "unready on the loss")
        let gone = await p.r.publishMsg(kind: "out", payload: "{}")
        XCTAssertEqual(.notSent, gone)
        // The session reconnects by itself; its first resubscribe is refused, the next one holds.
        let back = await waitUntil(30_000) { p.states.filter { $0 == .connected }.count >= 2 }
        XCTAssertTrue(back, "reconnected: \(p.states)")
        XCTAssertEqual(1, p.readyAtHook.count, "no walk on the refused resubscribe")
        let again = await waitUntil(15_000) { p.readyAtHook.count == 2 }
        XCTAssertTrue(again, "tried again on the same connection")
        XCTAssertEqual([true, true], p.readyAtHook)
        XCTAssertGreaterThan(p.walkDelay(1), 1.0, "the second walk waited for the retry, not for the refused SUBACK")
        await p.stop()
    }

    func testADropWhileSubscribingEndsThatConnectionsAttemptsAndTheNextConnectionMakesItReady() async throws {
        let p = try probe("dropset")
        p.r.start()
        let up = await waitUntil(10_000) { p.r.state.value == .connected }
        XCTAssertTrue(up)
        // Connection 1 refuses every filter and is closed after its second SUBACK, about 2 s in.
        let walked = await waitUntil(40_000) { p.readyAtHook.count == 1 }
        XCTAssertTrue(walked)
        XCTAssertEqual([true], p.readyAtHook)
        XCTAssertGreaterThanOrEqual(p.states.filter { $0 == .connected }.count, 2, "through a reconnect: \(p.states)")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        XCTAssertEqual(1, p.readyAtHook.count, "one walk, on the second connection")
        await p.stop()
    }
}
