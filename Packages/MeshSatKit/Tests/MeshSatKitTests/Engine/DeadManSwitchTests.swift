// DeadManSwitch has no Android unit test; these pin the Kotlin behaviour: nothing while
// disabled, one SOS per timeout, a touch that resets both the timer and the trigger, and the
// newest stored position on the callback.
import XCTest

@testable import MeshSatEngine

final class DeadManSwitchTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1_000_000_000
        var now: Int64 {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    private struct Call: Equatable {
        let lat: Double
        let lon: Double
        let seen: Int64
    }

    private actor Fired {
        var calls: [Call] = []
        func add(_ lat: Double, _ lon: Double, _ seen: Int64) { calls.append(Call(lat: lat, lon: lon, seen: seen)) }
    }

    func testFiresOnceAfterTimeoutAndResetsOnTouch() async {
        let clock = Clock()
        let fired = Fired()
        let dms = DeadManSwitch(timeoutSec: 7200, latestPosition: { (52.3676, 4.9041) }, now: { clock.now }, sleep: { _ in })
        dms.setSosCallback { lat, lon, seen in await fired.add(lat, lon, seen) }
        XCTAssertFalse(dms.isEnabled)
        XCTAssertEqual(dms.lastActivity, 1_000_000)
        // Disabled: never.
        clock.now += 3 * 3600 * 1000
        await dms.check()
        XCTAssertFalse(dms.isTriggered)
        // Enabled, but touched just now: not yet.
        dms.setEnabled(true)
        dms.touch()
        clock.now += 7200 * 1000
        await dms.check()
        XCTAssertFalse(dms.isTriggered)
        // One second past the timeout: once, with the stored position and the last activity.
        clock.now += 1000
        await dms.check()
        await dms.check()
        XCTAssertTrue(dms.isTriggered)
        let calls = await fired.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.lat, 52.3676)
        XCTAssertEqual(calls.first?.lon, 4.9041)
        XCTAssertEqual(calls.first?.seen, dms.lastActivity)
        // A touch clears the trigger and the timer runs again from now.
        dms.touch()
        XCTAssertFalse(dms.isTriggered)
        XCTAssertEqual(dms.lastActivity, clock.now / 1000)
        clock.now += 7201 * 1000
        await dms.check()
        let second = await fired.calls.count
        XCTAssertEqual(second, 2)
    }

    func testTimeoutChangeAndNoPosition() async {
        let clock = Clock()
        let fired = Fired()
        let dms = DeadManSwitch(timeoutSec: 7200, latestPosition: { nil }, now: { clock.now }, sleep: { _ in })
        dms.setSosCallback { lat, lon, seen in await fired.add(lat, lon, seen) }
        dms.setEnabled(true)
        dms.timeoutSec = 60
        XCTAssertEqual(dms.timeoutSec, 60)
        clock.now += 61 * 1000
        await dms.check()
        let calls = await fired.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.lat, 0)
        XCTAssertEqual(calls.first?.lon, 0)
    }

    func testLoopSleepsCheckInterval() async throws {
        let slept = AprsReceived<Int64>()
        let dms = DeadManSwitch(timeoutSec: 10, latestPosition: { nil }, now: { 0 }, sleep: { slept.add($0) })
        dms.start()
        _ = try await slept.first(timeoutMs: 2000)
        dms.stop()
        XCTAssertEqual(slept.all.first, DeadManSwitch.checkIntervalMs)
    }
}
