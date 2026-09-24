// Mirrors OfflinePassPredictionTest.kt (MESHSAT-1240, MESHSAT-1304): the bundled snapshot, the
// Iridium NEXT filter, choosing the newer set, and one set per satellite.
import MeshSatSatellite
import XCTest

final class TleSetsTests: XCTestCase {
    let bundled = BundledTle.load()

    func testTheShippedSnapshotHoldsTheIridiumNextConstellation() {
        XCTAssertGreaterThanOrEqual(bundled.count, 66, "got \(bundled.count)")
        XCTAssertTrue(bundled.allSatisfy { $0.name.hasPrefix("IRIDIUM") })
        XCTAssertTrue(bundled.allSatisfy { TleSets.isIridiumNext($0.name) }, "the filter reproduces CelesTrak's group")
    }

    func testTheIridiumNextFilter() {
        XCTAssertTrue(TleSets.isIridiumNext("IRIDIUM 106"))
        XCTAssertTrue(TleSets.isIridiumNext("IRIDIUM 180 "))
        XCTAssertFalse(TleSets.isIridiumNext("IRIDIUM 7"))
        XCTAssertFalse(TleSets.isIridiumNext("IRIDIUM 33 DEB"))
        XCTAssertFalse(TleSets.isIridiumNext("IRIDIUM 97"))
    }

    func testTheNewerSetWinsAndTheSnapshotFillsIn() {
        let older = bundled.map { shifted($0, days: -30) }
        XCTAssertEqual(TleSets.choose(downloaded: [], bundled: bundled).source, .bundled)
        XCTAssertEqual(TleSets.choose(downloaded: older, bundled: bundled).source, .bundled)
        XCTAssertEqual(TleSets.choose(downloaded: bundled, bundled: older).source, .downloaded)
        XCTAssertEqual(TleSets.choose(downloaded: [], bundled: []).source, TleSource.none)
    }

    func testADownloadHoldingASatelliteTwiceKeepsItsNewestSetOnly() throws {
        let i138 = try XCTUnwrap(bundled.first { $0.name == "IRIDIUM 138" })
        let repeated = bundled + [i138, shifted(i138, days: -2)]
        let kept = TleSets.onePerSatellite(repeated)
        XCTAssertEqual(kept.count, bundled.count)
        XCTAssertEqual(kept.filter { $0.name == "IRIDIUM 138" }, [i138])
        XCTAssertEqual(kept.map(\.name), kept.map(\.name).sorted())

        let start = TleSets.newestEpoch(bundled)
        let observer = Observer(latDeg: 52.16, lonDeg: 4.51)
        func passes(_ tles: [TleElements]) -> Int {
            PassPredictor.predictAllPasses(
                tles, observer: observer, start: start, end: UnixSeconds(start.value + 6 * 3600), minElevDeg: 5.0, now: start
            ).count
        }
        XCTAssertGreaterThan(passes(repeated), passes(bundled), "repeated sets predict passes twice")
        XCTAssertEqual(passes(bundled), passes(kept))
    }

    func testTleApiPageParsing() throws {
        let json = """
            {"member":[{"name":"IRIDIUM 104","line1":"\(l1)","line2":"\(l2)"},{"name":"IRIDIUM 33 DEB","line1":"\(l1)","line2":"\(l2)"}],
             "view":{"next":"https://x/?page=2"}}
            """
        let page = try XCTUnwrap(TleSets.parseTleApiPage(Data(json.utf8)))
        XCTAssertEqual(page.sets.map(\.name), ["IRIDIUM 104"])
        XCTAssertTrue(page.hasNext)
        XCTAssertNil(TleSets.parseTleApiPage(Data("not json".utf8)))
    }

    func testFetcherPrefersTheCacheAndFallsBackToTheSnapshot() async {
        let cache = MemoryTleCache()
        let fetcher = TleFetcher(store: cache, http: nil, bundled: bundled)
        let local = await fetcher.localTles()
        XCTAssertEqual(local.source, .bundled)
        let stale = await fetcher.isCacheStale()
        XCTAssertTrue(stale)
        let none = await fetcher.refreshFromNetwork()
        XCTAssertNil(none, "no HTTP means no refresh, and no failure")
        let newer = bundled.map { shifted($0, days: 1) }
        let t = UnixSeconds(1_800_000_000)
        await cache.replace(with: newer, fetchedAt: t)
        let after = await fetcher.localTles()
        XCTAssertEqual(after.source, .downloaded)
        let freshAge = await fetcher.isCacheStale(now: UnixSeconds(t.value + 3600))
        XCTAssertFalse(freshAge)
        let oldAge = await fetcher.isCacheStale(now: UnixSeconds(t.value + 2 * 86400))
        XCTAssertTrue(oldAge)
    }

    private let l1 = "1 41922U 17003F   26263.65299469  .00000272  00000+0  90159-4 0  9996"
    private let l2 = "2 41922  86.3951  48.5368 0002411  92.5475 267.5997 14.34220199506951"

    private func shifted(_ t: TleElements, days: Double) -> TleElements {
        TleElements(
            name: t.name, line1: t.line1, line2: t.line2, catalogNumber: t.catalogNumber, epochJd: t.epochJd + days,
            bstar: t.bstar, meanMotionDot: t.meanMotionDot, meanMotionDDot: t.meanMotionDDot,
            inclinationDeg: t.inclinationDeg, raanDeg: t.raanDeg, eccentricity: t.eccentricity,
            argPerigeeDeg: t.argPerigeeDeg, meanAnomalyDeg: t.meanAnomalyDeg, meanMotion: t.meanMotion
        )
    }
}
