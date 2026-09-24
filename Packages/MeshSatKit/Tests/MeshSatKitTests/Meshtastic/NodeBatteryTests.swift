// Mirrors ble/NodeBatteryTest.kt: the node's battery as the phone shows it (MESHSAT-1315).
import MeshSatMeshtastic
import XCTest

final class NodeBatteryTests: XCTestCase {
    private let t0: Int64 = 1_790_000_000_000
    private func at(_ min: Int) -> Int64 { t0 + Int64(min) * 60_000 }

    /// A reading a minute from `fromMin` to `toMin`, falling `perHour` points an hour from `start`.
    private func falling(_ start: Double, _ perHour: Double, _ fromMin: Int, _ toMin: Int) -> [NodeBattery.Reading] {
        (fromMin...toMin).map { m in
            NodeBattery.Reading(atMs: at(m), level: Int(start - perHour * Double(m - fromMin) / 60.0))
        }
    }

    func testTimeLeftFollowsTheMeasuredRateOfDrop() {
        // 100 % falling 6 points an hour: after 60 min it reads 94 %, so about 15-16 h left.
        let hours = NodeBattery.hoursLeft(falling(100, 6, 0, 60), nowMs: at(60))
        XCTAssertNotNil(hours)
        XCTAssertEqual(hours ?? 0, 94.0 / 6.0, accuracy: 1.0)
    }

    func testNoEstimateFromTooLittleTimeOrTooLittleDrop() {
        XCTAssertNil(NodeBattery.hoursLeft(falling(100, 6, 0, 20), nowMs: at(20)), "20 min is too short")
        XCTAssertNil(NodeBattery.hoursLeft(falling(100, 1, 0, 60), nowMs: at(60)), "1 point of drop is noise")
        XCTAssertNil(NodeBattery.hoursLeft((0...90).map { NodeBattery.Reading(atMs: at($0), level: 88) }, nowMs: at(90)), "a flat level")
        XCTAssertNil(NodeBattery.hoursLeft([], nowMs: at(0)))
    }

    func testOnlyTheTimeSinceTheNodeCameOffUsbPowerCounts() {
        let onUsb = (0...40).map { NodeBattery.Reading(atMs: at($0), level: NodeBattery.externalPower) }
        let unpluggedShortly = falling(100, 6, 41, 60)
        XCTAssertNil(NodeBattery.hoursLeft(onUsb + unpluggedShortly, nowMs: at(60)), "19 min on battery")
        let unpluggedLonger = falling(100, 6, 41, 101)
        XCTAssertNotNil(NodeBattery.hoursLeft(onUsb + unpluggedLonger, nowMs: at(101)))
    }

    func testReadingsOlderThanTheWindowAreIgnored() {
        // A fast drop four hours ago, then a slow one: the estimate follows the recent rate.
        let old = falling(100, 30, 0, 30)
        let recent = falling(80, 4, 240, 330)
        let hours = NodeBattery.hoursLeft(old + recent, nowMs: at(330))
        XCTAssertEqual(hours ?? 0, 74.0 / 4.0, accuracy: 2.0)
    }

    func testWordsForTheScreen() {
        XCTAssertEqual(NodeBattery.describe(level: 101, voltage: 4.9, hoursLeft: nil), "On USB power")
        XCTAssertEqual(NodeBattery.describe(level: 82, voltage: 3.98, hoursLeft: 14.2), "82%, 3.98 V, about 14 h left")
        XCTAssertEqual(NodeBattery.describe(level: 82, voltage: 3.98, hoursLeft: 14.2, withVoltage: false), "82%, about 14 h left")
        XCTAssertEqual(NodeBattery.describe(level: 82, voltage: 0, hoursLeft: nil), "82%")
        XCTAssertNil(NodeBattery.describe(level: -1, voltage: 0, hoursLeft: nil))
        XCTAssertEqual(NodeBattery.timeLeftText(0.66), "about 40 min left")
        XCTAssertEqual(NodeBattery.timeLeftText(70.0), "about 3 days left")
        XCTAssertEqual(NodeBattery.cell(101), "USB")
        XCTAssertEqual(NodeBattery.cell(55), "55%")
        XCTAssertEqual(NodeBattery.cell(-1), "-")
    }
}
