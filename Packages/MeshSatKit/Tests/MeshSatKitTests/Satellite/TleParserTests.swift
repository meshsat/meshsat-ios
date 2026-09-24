import MeshSatSatellite
import XCTest

final class TleParserTests: XCTestCase {
    // ISS, the canonical textbook example (Vallado); epoch 2008-09-20 12:25:40 UTC.
    let line1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927"
    let line2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537"

    func testParsesTheClassicSet() throws {
        let set = try TleParser.parse(name: "ISS (ZARYA)", line1: line1, line2: line2)
        XCTAssertEqual(set.name, "ISS (ZARYA)")
        XCTAssertEqual(set.catalogNumber, 25544)
        XCTAssertEqual(set.inclinationDeg, 51.6416, accuracy: 1e-9)
        XCTAssertEqual(set.raanDeg, 247.4627, accuracy: 1e-9)
        XCTAssertEqual(set.eccentricity, 0.0006703, accuracy: 1e-12)
        XCTAssertEqual(set.argPerigeeDeg, 130.5360, accuracy: 1e-9)
        XCTAssertEqual(set.meanAnomalyDeg, 325.0288, accuracy: 1e-9)
        XCTAssertEqual(set.meanMotion, 15.72125391, accuracy: 1e-9)
        XCTAssertEqual(set.bstar, -0.11606e-4, accuracy: 1e-12)
        // 2008-09-20 12:25:40.104 UTC
        XCTAssertEqual(set.epoch.value, 1_221_913_540.104, accuracy: 0.01)
    }

    func testExponentField() throws {
        XCTAssertEqual(try TleParser.parseExponent(" 12345-3"), 0.12345e-3, accuracy: 1e-15)
        XCTAssertEqual(try TleParser.parseExponent("-11606-4"), -0.11606e-4, accuracy: 1e-15)
        XCTAssertEqual(try TleParser.parseExponent(" 00000-0"), 0, accuracy: 1e-15)
        XCTAssertEqual(try TleParser.parseExponent(" 10000+1"), 1.0, accuracy: 1e-15)
    }

    func testJulianDayRoundTrip() {
        XCTAssertEqual(TleParser.julianDay(year: 2000, month: 1, day: 1), 2_451_544.5, accuracy: 1e-9)
        let t = UnixSeconds(1_700_000_000)
        // A Julian date near 2.46e6 days has about 10 microseconds of double resolution.
        XCTAssertEqual(TleParser.jdToUnix(TleParser.unixToJd(t)).value, t.value, accuracy: 1e-3)
    }

    func testBundledIridiumSetLoads() {
        let sets = BundledTle.load()
        XCTAssertGreaterThan(sets.count, 50, "the bundled iridium-next.3le should hold the constellation")
        XCTAssertTrue(sets.allSatisfy { $0.name.uppercased().contains("IRIDIUM") })
        XCTAssertEqual(Set(sets.map(\.catalogNumber)).count, sets.count, "one set per catalogue number")
    }

    func testMultiParserSkipsGarbage() {
        let text = "junk line\nISS (ZARYA)\n\(line1)\n\(line2)\n1 broken\n2 broken\n"
        let sets = TleParser.parseMulti(text)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.catalogNumber, 25544)
    }
}
