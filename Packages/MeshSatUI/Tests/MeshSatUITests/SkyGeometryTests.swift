// Mirrors app/src/test/java/net/meshsat/android/SkyGeometryTest.kt.
import MeshSatSatellite
import XCTest

@testable import MeshSatUI

final class SkyGeometryTests: XCTestCase {
    private func pass(_ aos: Int64, _ los: Int64, _ peak: Double) -> PassPrediction {
        PassPrediction(
            satellite: "IRIDIUM 122", aos: UnixSeconds(Double(aos)), los: UnixSeconds(Double(los)), durationMin: Double(los - aos) / 60,
            peakElevDeg: peak, peakAzimuthDeg: 88, isActive: false)
    }

    func testAnEightyDegreePassPeaksAtEightyDegreesNotHalf() {
        let t = SkyGeometry.triangle(pass(1_000, 1_600, 80), 0, 3_600, left: 0, width: 3600, bottom: 900, height: 900)
        XCTAssertEqual(t.peakY, 900 - 800, accuracy: 0.001)
        XCTAssertEqual(t.xMid, 1_300, accuracy: 0.001)
    }

    func testAPassOffTheChartIsClippedThenItsApexSitsBetweenTheClippedEnds() {
        let t = SkyGeometry.triangle(pass(-300, 300, 45), 0, 3_600, left: 10, width: 3600, bottom: 90, height: 90)
        XCTAssertEqual(t.x1, 10, accuracy: 0.001)
        XCTAssertEqual(t.x2, 310, accuracy: 0.001)
        XCTAssertEqual(t.xMid, 160, accuracy: 0.001)
    }

    func testSignalColoursFollowTheBridge() {
        XCTAssertEqual(SkyGeometry.signalRgb(5), 0x10B981)
        XCTAssertEqual(SkyGeometry.signalRgb(3), 0x10B981)
        XCTAssertEqual(SkyGeometry.signalRgb(2), 0xF59E0B)
        XCTAssertEqual(SkyGeometry.signalRgb(1), 0xF59E0B)
        XCTAssertEqual(SkyGeometry.signalRgb(0), 0xEF4444)
    }

    func testBarsAndDegreesShareThePlot() {
        XCTAssertEqual(SkyGeometry.barsY(0, bottom: 100, height: 50), 100, accuracy: 0.001)
        XCTAssertEqual(SkyGeometry.barsY(5, bottom: 100, height: 50), 50, accuracy: 0.001)
        XCTAssertEqual(SkyGeometry.elevY(90, bottom: 100, height: 50), 50, accuracy: 0.001)
    }

    func testLabelsFallOnWholeHoursInsideTheWindow() {
        XCTAssertEqual(SkyGeometry.ticks(1_800, 9_000, stepSec: 3_600), [3_600, 7_200])
    }

    func testOnlyPassesThatTouchTheWindowAreDrawn() {
        XCTAssertTrue(SkyGeometry.overlaps(pass(900, 1_500, 30), 1_000, 2_000))
        XCTAssertFalse(SkyGeometry.overlaps(pass(100, 900, 30), 1_000, 2_000))
        XCTAssertFalse(SkyGeometry.overlaps(pass(2_000, 2_600, 30), 1_000, 2_000))
    }

    func testReadingsAreAveragedToWhatTheWidthCanShow() {
        let raw = (0..<720).map { SkySignal(atSec: Int64($0) * 60, bars: $0 % 2 == 0 ? 0 : 5) }
        let step = SkyGeometry.stepFor(spanSec: 12 * 3600, widthPx: 900, minGapPx: 9)
        XCTAssertEqual(step, 432)
        let avg = SkyGeometry.averaged(raw, stepSec: step)
        XCTAssertTrue((90...110).contains(avg.count), "\(avg.count)")
        XCTAssertTrue(avg.allSatisfy { (2.0...3.0).contains($0.bars) })
    }

    func testAtAMinuteAStepNothingIsAveraged() {
        let raw = [SkySignal(atSec: 120, bars: 3), SkySignal(atSec: 60, bars: 1)]
        let avg = SkyGeometry.averaged(raw, stepSec: 60)
        XCTAssertEqual(avg.map(\.atSec), [60, 120])
        XCTAssertEqual(avg.map(\.bars), [1, 3])
    }
}
