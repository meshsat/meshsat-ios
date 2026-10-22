// Mirrors test hubmsg/SessionReadinessTest.kt: the Hub app route starts its walk only once a session's
// subscriptions hold (r13 review, PH-R2). On the reporter: a refused subscribe is tried again on the
// same session without a reconnect, the route's connected hook and its publishes wait for it, a
// reconnect makes the session unready at once, and a drop during setup ends that session's attempts.
// On the route: nothing is published or spent before readiness, and lost status is recovered after.
// [MESHSAT-1584]
import Foundation
import MeshSatMQTT
import MeshSatNet
import XCTest

@testable import MeshSatHub

final class HubMsgReadinessTests: XCTestCase {
    /// Every sleep a short real wait: the retry and the health loop run, nothing spins.
    struct ShortClock: DriverClock {
        func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
        func sleep(ms: Int64) async { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() {
            lock.lock()
            n += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return n
        }
    }

    private let config = HubReporterConfig(hubUrl: "wss://hub.example/mqtt", bridgeId: "ios-test", healthIntervalSec: 1)

    private func waitUntil(_ ms: Int = 3_000, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await cond()
    }

    private func reporter(_ session: FakeMQTTSession, _ connected: Count) -> HubReporter {
        let r = HubReporter(config: config, host: FakeHubHost(), makeSession: { _ in session }, clock: ShortClock())
        r.setMsgCallbacks(onIn: { _ in }, onStatus: { _ in }, onConnected: { connected.add() })
        return r
    }

    func testARefusedFirstSubscribeIsTriedAgainOnTheSameSessionAndTheWalkWaits() async {
        let session = FakeMQTTSession()
        session.refuseSubscribes = 1
        let connected = Count()
        let r = reporter(session, connected)
        r.start()
        let up = await waitUntil { r.state.value == .connected }
        XCTAssertTrue(up)
        // Connected but not ready: the route's hook has not run and nothing of the route goes out.
        if !r.isMsgReady {
            XCTAssertEqual(0, connected.value)
            let sent = await r.publishMsg(kind: "out", payload: "{}")
            XCTAssertEqual(.notSent, sent)
        }
        // Ready is set first and the announce follows it: wait for both.
        let ready = await waitUntil { r.isMsgReady && connected.value == 1 }
        XCTAssertTrue(ready, "tried again without a reconnect")
        XCTAssertEqual(2, session.subscribeAttempts)
        XCTAssertEqual(1, connected.value)
        XCTAssertTrue(session.subscribed.contains("meshsat/bridge/ios-test/msg/status"))
        // The birth is asked for once ready and goes out from the birth worker (r33 review R33-R1).
        let born = await waitUntil { session.published.contains { $0.topic == "meshsat/bridge/ios-test/birth" } }
        XCTAssertTrue(born, "announced once ready")
        let sent = await r.publishMsg(kind: "out", payload: "{}")
        XCTAssertEqual(.ok, sent)
        await r.stop()
    }

    func testARefusedSubscribeNeitherStartsTheWalkNorLetsTheRoutePublish() async {
        let session = FakeMQTTSession()
        session.refuseSubscribes = 1_000
        let connected = Count()
        let r = reporter(session, connected)
        r.start()
        let tried = await waitUntil { session.subscribeAttempts >= 2 }
        XCTAssertTrue(tried, "tried again on the same session")
        XCTAssertEqual(.connected, r.state.value)
        XCTAssertEqual(0, connected.value, "the walk started on a session without its subscriptions")
        let sent = await r.publishMsg(kind: "out", payload: "{}")
        XCTAssertEqual(.notSent, sent, "the route published on a session without its subscriptions")
        await r.stop()
    }

    func testAReconnectMakesTheSessionUnreadyAtOnceAndARefusedResubscribeIsTriedAgain() async {
        let session = FakeMQTTSession()
        let connected = Count()
        let r = reporter(session, connected)
        r.start()
        let ready = await waitUntil { r.isMsgReady && connected.value == 1 }
        XCTAssertTrue(ready)
        // Refused until the test lets it through: with a single refusal the 20 ms retry could
        // succeed and walk before the assertion below ran, which failed 1 run in 10 on a loaded
        // host (r16 review) without the reporter doing anything wrong.
        session.refuseSubscribes = 1_000
        session.drop("the broker went away")
        let lost = await waitUntil { !r.isMsgReady }
        XCTAssertTrue(lost, "a lost session is not ready")
        let attempts = session.subscribeAttempts
        session.reconnect()
        let refused = await waitUntil { session.subscribeAttempts > attempts + 1 }
        XCTAssertTrue(refused, "a refused resubscribe is tried again")
        XCTAssertFalse(r.isMsgReady, "ready on a refused resubscribe")
        XCTAssertEqual(1, connected.value, "no walk on a refused resubscribe")
        session.refuseSubscribes = 0
        let again = await waitUntil { r.isMsgReady }
        XCTAssertTrue(again, "tried again on the same session")
        let walked = await waitUntil { connected.value == 2 }
        XCTAssertTrue(walked)
        await r.stop()
    }

    func testADropDuringSetupEndsThatSessionsAttempts() async {
        let session = FakeMQTTSession()
        session.refuseSubscribes = 1_000
        let connected = Count()
        let r = reporter(session, connected)
        r.start()
        let tried = await waitUntil { session.subscribeAttempts >= 2 }
        XCTAssertTrue(tried)
        session.drop("dropped while subscribing")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterDrop = session.subscribeAttempts
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThanOrEqual(session.subscribeAttempts, afterDrop + 1, "no attempts on a lost session")
        XCTAssertFalse(r.isMsgReady)
        XCTAssertEqual(0, connected.value)
        session.refuseSubscribes = 0
        session.reconnect()
        let ready = await waitUntil { r.isMsgReady && connected.value == 1 }
        XCTAssertTrue(ready, "the next session's subscribe makes it ready")
        await r.stop()
    }

    func testASessionReplacedWhileItsSubscribeIsInFlightIsNeverAnnounced() async {
        let session = FakeMQTTSession()
        let connected = Count()
        let r = reporter(session, connected)
        // The first subscribe is granted, but the client reconnects before its answer is used: the
        // new session subscribes and announces, the old one must not.
        session.onSubscribe = {
            session.reconnect()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        r.start()
        let ready = await waitUntil { r.isMsgReady && connected.value >= 1 }
        XCTAssertTrue(ready)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(1, connected.value, "announced for the replaced session too")
        XCTAssertEqual(1, session.published.filter { $0.topic == "meshsat/bridge/ios-test/birth" }.count)
        await r.stop()
    }

    func testTheSessionChecksEverySubackCode() {
        XCTAssertTrue(MqttNioSession.allGranted([.grantedQoS1, .grantedQoS0], filters: 2))
        XCTAssertFalse(MqttNioSession.allGranted([.grantedQoS1, .failure], filters: 2))
        XCTAssertFalse(MqttNioSession.allGranted([.grantedQoS1], filters: 2))
    }

    /// The route under a publisher that is not ready until the subscribe holds, as the reporter is.
    func testTheRouteSpendsNothingBeforeReadinessAndRecoversAfter() async throws {
        let p = HubMsgRouteTests.Pair()
        p.a.onConnected()
        await p.a.pass()
        let id = try await p.send("while the subscribe is refused")
        await p.hub.pumpOne()
        p.linkA.up = false
        await p.hub.pump()  // the completion, lost
        p.linkA.up = true
        XCTAssertEqual(HubMsgStatus.forwarded, p.statusA(id))
        // An automatic reconnect whose subscribe is refused: the reporter answers notSent.
        p.linkA.answer = .notSent
        for _ in 0..<2 {
            p.t += 60_000
            await p.a.pass()
            await p.hub.pump()
        }
        XCTAssertEqual(0, p.hub.replays, "nothing spent before the subscriptions hold")
        XCTAssertEqual(HubMsgStatus.forwarded, p.statusA(id))
        // The subscribe holds: ready, and the connected hook starts the walk.
        p.linkA.answer = .ok
        p.a.onConnected()
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(1, p.hub.replays)
        XCTAssertEqual(1, p.rxB().count)
    }
}
