// Mirrors HubBirthOrderTest.kt (MESHSAT-1623, r33 review R33-R1): the review's schedules A1, its
// control, and A2 on the real HubReporter. Births go out one at a time, an older birth the broker
// took cannot clear a newer one that failed, a stamp always labels the snapshot built with it, and
// the current declaration goes out by itself. The broker is the fake session, which holds or fails
// each birth on cue and counts those in flight. [MESHSAT-1624]
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatNet
import XCTest

final class HubBirthOrderTests: XCTestCase {
    private let imei = "300000000000001"

    private func eventually(_ timeoutMs: Int = 10_000, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await cond()
    }

    /// A reporter on the fake broker whose host carries the 9704 with its IMEI, its chain from
    /// `provider`.
    private func make(clock: PacedClock = PacedClock(), _ provider: @escaping @Sendable () -> String?) -> (HubReporter, FakeMQTTSession) {
        let session = FakeMQTTSession()
        let host = FakeHubHost()
        host.setInterfaces([
            InterfaceInfo(name: "ble_mesh_0", type: "meshtastic", status: "online"),
            InterfaceInfo(name: "iridium_imt_0", type: "iridium_imt", status: "online", imei: imei),
        ])
        let reporter = HubReporter(
            config: HubReporterConfig(hubUrl: "wss://hub.example/mqtt", bridgeId: "ios-order-test", healthIntervalSec: 1), host: host,
            makeSession: { _ in session }, clock: clock, birthStamps: StampStore())
        reporter.setImtEgressFormat(provider)
        return (reporter, session)
    }

    private func taken(_ session: FakeMQTTSession) -> [String] {
        session.published.filter { $0.topic.hasSuffix("/birth") }.map(\.payload)
    }

    private func json(_ birth: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(birth.utf8))) as? [String: Any] ?? [:]
    }

    /// What the birth declares for the modem, "" for nothing.
    private func format(_ birth: String) -> String {
        let interfaces = json(birth)["interfaces"] as? [[String: Any]] ?? []
        let modem = interfaces.first { $0["imei"] as? String == imei }
        return modem?["egress_format"] as? String ?? ""
    }

    private func stamp(_ birth: String) -> BirthStamp? {
        (json(birth)["timestamp"] as? String).flatMap { try? BirthStamper.parse($0) }
    }

    private func assertOrdered(_ births: [String], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(births, births.dropFirst()) {
            guard let sa = stamp(a), let sb = stamp(b) else { return XCTFail("a birth without a stamp", file: file, line: line) }
            XCTAssertGreaterThan(sb, sa, "\(BirthStamper.format(sb)) after \(BirthStamper.format(sa))", file: file, line: line)
        }
    }

    /// A1: the first birth (plain) is held at the broker; the chain turns sealed; the next birth
    /// fails; then the held one is taken. Nothing changes after that, and the sealed birth must still
    /// go out by itself, with no two births in flight at any time.
    func testAnOlderBirthTakenLateDoesNotClearANewerOneThatFailed() async {
        let mode = LockedText(SatelliteChain.modePlain)
        let (reporter, session) = make { SatelliteChain.egressFormat(mode.value) }
        let release = Gate()
        session.scriptBirths([.hold(release, thenTake: true), .fail])
        reporter.start()
        let reached = await eventually { session.birthAttempts >= 1 }
        XCTAssertTrue(reached, "the first birth reached the broker")
        mode.value = SatelliteChain.modeSealed
        // Health ticks (1 s on the paced clock, 10 ms for real) ask for the sealed birth while the plain one is held.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.birthAttempts, 1, "nothing else goes out while a birth is in flight")
        await release.open()
        let sealed = await eventually(30_000) {
            let t = self.taken(session)
            return t.count >= 2 && self.format(t[t.count - 1]) == "sealed"
        }
        XCTAssertTrue(sealed, "the sealed birth went out by itself")
        XCTAssertEqual(session.maxBirthsInFlight, 1, "one birth at a time")
        XCTAssertGreaterThanOrEqual(session.birthAttempts, 3, "the failed sealed birth was tried again")
        XCTAssertEqual(taken(session).first.map(format), "plain")
        assertOrdered(taken(session))
        await reporter.stop()
    }

    /// The control for A1: the newer birth fails first, then everything is taken.
    func testAFailedBirthIsTriedAgainUntilTheCurrentDeclarationIsTaken() async {
        let (reporter, session) = make { SatelliteChain.egressFormat(SatelliteChain.modeSealed) }
        session.scriptBirths([.fail, .fail])
        reporter.start()
        let sealed = await eventually(40_000) {
            let t = self.taken(session)
            return !t.isEmpty && self.format(t[t.count - 1]) == "sealed"
        }
        XCTAssertTrue(sealed, "sealed taken after two failures")
        XCTAssertGreaterThanOrEqual(session.birthAttempts, 3)
        XCTAssertEqual(session.maxBirthsInFlight, 1)
        assertOrdered(taken(session))
        await reporter.stop()
    }

    /// A2: the first birth pauses after its stamp, while its snapshot is being built (inside the
    /// declaration provider). The chain turns sealed meanwhile. No other birth may start or take a
    /// stamp in between; when it resumes, every birth taken carries its own snapshot, the stamps go
    /// up in the order they were sent, and the last one declares what is current. The clock runs a
    /// tenth for real here, so the birth's snapshot is the provider's first call, before the first
    /// health tick.
    func testAStampAlwaysLabelsTheSnapshotBuiltWithIt() async {
        let mode = LockedText(SatelliteChain.modePlain)
        let calls = CallCounter()
        let inProvider = Collected<Bool>()
        let resume = DispatchSemaphore(value: 0)
        let (reporter, session) = make(clock: PacedClock(realDivisor: 10)) {
            if calls.next() == 1 {
                inProvider.add(true)
                _ = resume.wait(timeout: .now() + 60)
            }
            return SatelliteChain.egressFormat(mode.value)
        }
        reporter.start()
        let paused = await eventually { !inProvider.list.isEmpty }
        XCTAssertTrue(paused, "the first birth paused in its snapshot")
        mode.value = SatelliteChain.modeSealed
        // Health ticks (100 ms for real) ask for a birth while the first is paused.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(session.birthAttempts, 0, "no birth was sent while one was being built")
        resume.signal()
        let sealed = await eventually(30_000) {
            let t = self.taken(session)
            return !t.isEmpty && self.format(t[t.count - 1]) == "sealed"
        }
        XCTAssertTrue(sealed, "the current declaration went out")
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(session.maxBirthsInFlight, 1)
        assertOrdered(taken(session))
        XCTAssertEqual(taken(session).last.map(format), "sealed")
        await reporter.stop()
    }
}

/// Counts calls from any thread; each caller learns its own number.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
