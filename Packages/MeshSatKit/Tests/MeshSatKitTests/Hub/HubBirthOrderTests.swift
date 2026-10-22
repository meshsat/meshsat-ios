// Mirrors HubBirthOrderTest.kt (MESHSAT-1623, r33 review R33-R1): the review's schedules A1 and A2
// both ways (plain to sealed, sealed to plain), and A1's controls, on the real HubReporter. Births go out one at a time, an older birth the broker
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

    /// A1: the first birth (`from`) is held at the broker; the chain turns `to`; the next birth
    /// fails; then the held one is taken. Nothing changes after that, and the `to` birth must still
    /// go out by itself, with no two births in flight at any time.
    private func a1(from: String, to: String, file: StaticString = #filePath, line: UInt = #line) async {
        let mode = LockedText(from)
        let (reporter, session) = make { SatelliteChain.egressFormat(mode.value) }
        let want = SatelliteChain.egressFormat(to) ?? ""
        let release = Gate()
        session.scriptBirths([.hold(release, thenTake: true), .fail])
        reporter.start()
        let reached = await eventually { session.birthAttempts >= 1 }
        XCTAssertTrue(reached, "the first birth reached the broker", file: file, line: line)
        mode.value = to
        // Health ticks (1 s on the paced clock, 10 ms for real) ask for the new birth while the first is held.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.birthAttempts, 1, "nothing else goes out while a birth is in flight", file: file, line: line)
        await release.open()
        let current = await eventually(30_000) {
            let t = self.taken(session)
            return t.count >= 2 && self.format(t[t.count - 1]) == want
        }
        XCTAssertTrue(current, "the \(want) birth went out by itself", file: file, line: line)
        XCTAssertEqual(session.maxBirthsInFlight, 1, "one birth at a time", file: file, line: line)
        XCTAssertGreaterThanOrEqual(session.birthAttempts, 3, "the failed \(want) birth was tried again", file: file, line: line)
        XCTAssertEqual(taken(session).first.map(format), SatelliteChain.egressFormat(from), file: file, line: line)
        assertOrdered(taken(session), file: file, line: line)
        await reporter.stop()
    }

    func testAnOlderBirthTakenLateDoesNotClearANewerOneThatFailed() async {
        await a1(from: SatelliteChain.modePlain, to: SatelliteChain.modeSealed)
    }

    /// A1 the other way round: sealed held, the chain turns plain (r33: the inverse format change).
    func testAnOlderSealedBirthTakenLateDoesNotClearANewerPlainOneThatFailed() async {
        await a1(from: SatelliteChain.modeSealed, to: SatelliteChain.modePlain)
    }

    /// A1 with the completions the other way round (r33: the passing control): the first birth is
    /// taken at once, the chain turns sealed, and the sealed birth then fails. It is tried again
    /// until it is taken.
    func testAnOlderBirthTakenFirstAndANewerOneThatFailsAfterItIsTriedAgain() async {
        let mode = LockedText(SatelliteChain.modePlain)
        let (reporter, session) = make { SatelliteChain.egressFormat(mode.value) }
        session.scriptBirths([.take, .fail])
        reporter.start()
        let first = await eventually { self.taken(session).count == 1 }
        XCTAssertTrue(first, "the plain birth was taken")
        XCTAssertEqual(taken(session).first.map(format), "plain")
        mode.value = SatelliteChain.modeSealed
        let sealed = await eventually(30_000) {
            let t = self.taken(session)
            return t.count >= 2 && self.format(t[t.count - 1]) == "sealed"
        }
        XCTAssertTrue(sealed, "the sealed birth was taken after it failed")
        XCTAssertGreaterThanOrEqual(session.birthAttempts, 3, "the failed sealed birth was tried again")
        XCTAssertEqual(session.maxBirthsInFlight, 1)
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
    /// declaration provider). The chain turns from `from` to `to` meanwhile. No other birth may
    /// start or take a stamp in between; when it resumes, every birth taken carries its own
    /// snapshot, the stamps go up in the order they were sent, and the last one declares what is
    /// current. The clock runs a tenth for real here, so the birth's snapshot is the provider's
    /// first call, before the first health tick.
    private func a2(from: String, to: String, file: StaticString = #filePath, line: UInt = #line) async {
        let mode = LockedText(from)
        let calls = CallCounter()
        let inProvider = Collected<Bool>()
        let resume = DispatchSemaphore(value: 0)
        let want = SatelliteChain.egressFormat(to) ?? ""
        let (reporter, session) = make(clock: PacedClock(realDivisor: 10)) {
            if calls.next() == 1 {
                inProvider.add(true)
                _ = resume.wait(timeout: .now() + 60)
            }
            return SatelliteChain.egressFormat(mode.value)
        }
        reporter.start()
        let paused = await eventually { !inProvider.list.isEmpty }
        XCTAssertTrue(paused, "the first birth paused in its snapshot", file: file, line: line)
        mode.value = to
        // Health ticks (100 ms for real) ask for a birth while the first is paused.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(session.birthAttempts, 0, "no birth was sent while one was being built", file: file, line: line)
        resume.signal()
        let current = await eventually(30_000) {
            let t = self.taken(session)
            return !t.isEmpty && self.format(t[t.count - 1]) == want
        }
        XCTAssertTrue(current, "the current declaration went out", file: file, line: line)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(session.maxBirthsInFlight, 1, file: file, line: line)
        assertOrdered(taken(session), file: file, line: line)
        XCTAssertEqual(taken(session).last.map(format), want, file: file, line: line)
        await reporter.stop()
    }

    func testAStampAlwaysLabelsTheSnapshotBuiltWithIt() async {
        await a2(from: SatelliteChain.modePlain, to: SatelliteChain.modeSealed)
    }

    /// A2 the other way round: sealed first, the chain turns plain while the birth is paused.
    func testAStampLabelsItsSnapshotWhenTheChainTurnsPlain() async {
        await a2(from: SatelliteChain.modeSealed, to: SatelliteChain.modePlain)
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
