// Mirrors Sgp4ReferenceTest.kt: the propagator against Vallado's reference (the `sgp4` Python
// package) for a real Iridium NEXT element set, and one pass over Leiden where the reference
// puts it (MESHSAT-1302).
import MeshSatSatellite
import XCTest

final class Sgp4ReferenceTests: XCTestCase {
    let l1 = "1 41922U 17003F   26263.65299469  .00000272  00000+0  90159-4 0  9996"
    let l2 = "2 41922  86.3951  48.5368 0002411  92.5475 267.5997 14.34220199506951"

    // TEME position in km from the reference, at minutes after the epoch
    let reference: [(Double, [Double])] = [
        (0.0, [4740.199, 5364.760, 0.003]),
        (10.0, [3640.600, 4518.023, 4182.265]),
        (60.0, [-3678.654, -4553.689, -4128.078]),
        (360.0, [-3934.896, -4779.299, -3602.570]),
        (1440.0, [-2686.306, -2413.308, 6169.477]),
    ]

    func testTheEpochIsReadAsTheReferenceReadsIt() throws {
        let tle = try TleParser.parse(name: "IRIDIUM 104", line1: l1, line2: l2)
        XCTAssertEqual(tle.epochJd, 2_461_304.15299469, accuracy: 1e-6)
        XCTAssertEqual(tle.meanMotionDot, 0.00000272, accuracy: 1e-12)
        XCTAssertEqual(tle.bstar, 0.90159e-4, accuracy: 1e-12)
    }

    func testPositionsAgreeWithTheReferenceToWithinAKilometre() throws {
        let tle = try TleParser.parse(name: "IRIDIUM 104", line1: l1, line2: l2)
        for (ts, ref) in reference {
            let p = try XCTUnwrap(Sgp4.propagate(tle, tsinceMinutes: ts))
            let d = ((p.x - ref[0]) * (p.x - ref[0]) + (p.y - ref[1]) * (p.y - ref[1]) + (p.z - ref[2]) * (p.z - ref[2])).squareRoot()
            XCTAssertLessThan(d, 1.0, "at \(ts) min the app is \(d) km from the reference")
        }
    }

    func testOneSatelliteGivesOnePassWhereTheReferencePutsIt() throws {
        // Leiden, 21 Sep 2026 04:30 to 06:00 UTC: the reference has one pass, 05:15 to 05:26 at 11 degrees.
        let tle = try TleParser.parse(name: "IRIDIUM 104", line1: l1, line2: l2)
        let start = UnixSeconds(1_789_965_000)  // 2026-09-21T04:30:00Z
        let passes = PassPredictor.predictPasses(
            tle, observer: Observer(latDeg: 52.1620, lonDeg: 4.5093), start: start,
            end: UnixSeconds(start.value + 90 * 60), minElevDeg: 0.0, now: start
        )
        XCTAssertEqual(passes.count, 1)
        let p = try XCTUnwrap(passes.first)
        XCTAssertEqual(p.aos.value, 1_789_967_700, accuracy: 60, "AOS 05:15:00Z")
        XCTAssertEqual(p.los.value, 1_789_968_360, accuracy: 60, "LOS 05:26:00Z")
        XCTAssertEqual(p.peakElevDeg, 11.0, accuracy: 1.0)
        XCTAssertFalse(p.isActive)
        XCTAssertGreaterThan(p.durationMin, 9)
    }

    func testPassesOverLeidenArePredictedFromTheSnapshotAlone() {
        // Mirrors OfflinePassPredictionTest: the bundled set predicts a full sky of passes.
        let bundled = BundledTle.load()
        XCTAssertGreaterThanOrEqual(bundled.count, 66)
        let newest = bundled.map(\.epoch).max()!
        let observer = Observer(latDeg: 52.16, lonDeg: 4.51)
        let sixHours = UnixSeconds(newest.value + 6 * 3600)
        let all = PassPredictor.predictAllPasses(bundled, observer: observer, start: newest, end: sixHours, minElevDeg: 5.0, now: newest)
        let high = PassPredictor.predictAllPasses(bundled, observer: observer, start: newest, end: sixHours, minElevDeg: 60.0, now: newest)
        XCTAssertGreaterThan(all.count, 20, "got \(all.count) passes in 6 h")
        XCTAssertFalse(high.isEmpty)
        XCTAssertLessThan(high.count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.los > $0.aos })
        XCTAssertEqual(all, all.sorted { $0.aos < $1.aos })
    }
}
