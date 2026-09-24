// The pass scheduler's modes (satellite/PassScheduler.kt): which mode each moment is in, and
// that entering Active flushes the burst queue and polls the signal at the mode's interval.
import MeshSatNet
import MeshSatSatellite
import XCTest

final class PassSchedulerTests: XCTestCase {
    private func pass(_ aos: Double, _ los: Double) -> PassPrediction {
        PassPrediction(
            satellite: "IRIDIUM 100", aos: UnixSeconds(aos), los: UnixSeconds(los), durationMin: (los - aos) / 60, peakElevDeg: 40,
            peakAzimuthDeg: 180, isActive: false)
    }

    func testModeForEachMoment() {
        let passes = [pass(1000, 1600), pass(5000, 5600)]
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 100).mode, .idle)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 100).next?.aos.value, 1000)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 850).mode, .preWake)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 1000).mode, .active)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 1300).mode, .active)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 1700).mode, .postPass)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 1700).next?.aos.value, 5000)
        XCTAssertEqual(PassScheduler.modeFor(passes: passes, now: 3000).mode, .idle)
        XCTAssertEqual(PassScheduler.modeFor(passes: [], now: 3000).mode, .idle)
        XCTAssertNil(PassScheduler.modeFor(passes: [], now: 3000).next)
        XCTAssertEqual(PassScheduler.timing(for: .active).signalPollIntervalMs, 5_000)
        XCTAssertTrue(PassScheduler.timing(for: .postPass).burstFlushOnEntry)
        XCTAssertFalse(PassScheduler.timing(for: .preWake).burstFlushOnEntry)
        XCTAssertEqual(PassScheduler.timing(for: .idle).signalPollIntervalMs, 120_000)
    }

    func testEnteringActiveFlushesOnceAndPolls() async {
        let clock = VirtualClock()
        let flushes = Changes()
        let polls = Changes()
        let passes = [pass(1_700_000_000_100, 1_700_000_000_700)]
        let scheduler = PassScheduler(
            passProvider: { passes },
            signalPoller: { polls.add("poll") },
            burstFlusher: { flushes.add("flush") },
            clock: clock)
        // VirtualClock starts at 1_700_000_000_000 ms = 1_700_000_000 s; the pass is far off.
        await scheduler.updateMode()
        XCTAssertEqual(scheduler.mode.value, .idle)
        clock.advance(ms: 1_700_000_000_100 * 1000 - 1_700_000_000_000 + 1000)
        await scheduler.updateMode()
        XCTAssertEqual(scheduler.mode.value, .active)
        for _ in 0..<50 where polls.list.isEmpty || flushes.list.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(flushes.list, ["flush"])
        XCTAssertFalse(polls.list.isEmpty)
        scheduler.stop()
        XCTAssertEqual(scheduler.mode.value, .idle)
    }
}
