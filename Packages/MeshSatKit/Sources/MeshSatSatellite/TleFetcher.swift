// Mirrors satellite/TleFetcher.kt: Iridium orbital elements for pass prediction, offline first.
// Predictions use the elements downloaded last or the snapshot shipped in the app, whichever is
// newer; a download only refreshes that data (CelesTrak first, then the public TLE API, sorted
// and de-duplicated per catalogue number, MESHSAT-1304), and a failed one keeps what is there.
// Persistence and HTTP are protocols so this file runs on Linux in the tests.
import Foundation

public enum TleSource: Sendable, Equatable {
    case downloaded, bundled, none
}

public struct TleSet: Sendable, Equatable {
    public let tles: [TleElements]
    public let source: TleSource
    public let newestEpoch: UnixSeconds

    public init(tles: [TleElements], source: TleSource, newestEpoch: UnixSeconds) {
        self.tles = tles
        self.source = source
        self.newestEpoch = newestEpoch
    }

    /// Age of the newest element set in seconds, or -1 without data.
    public func ageSec(now: UnixSeconds = UnixSeconds(Date())) -> Double {
        tles.isEmpty ? -1 : max(0, now.value - newestEpoch.value)
    }
}

/// What the app keeps between runs: the last download (tle_cache in Android's Room database).
public protocol TleCacheStore: Sendable {
    func load() async -> (tles: [TleElements], fetchedAt: UnixSeconds?)
    func replace(with tles: [TleElements], fetchedAt: UnixSeconds) async
}

public protocol TleHttp: Sendable {
    /// Returns (status, body) for a GET with the given headers, or throws on a transport error.
    func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> (Int, Data)
}

public enum TleSets {
    public static let celestrakIridiumURL = "https://celestrak.org/NORAD/elements/gp.php?GROUP=iridium-NEXT&FORMAT=3le"
    /// Sorted, because without an order the API shuffles between requests (MESHSAT-1304).
    public static let tleApiURL = "https://tle.ivanstanojevic.me/api/tle/?search=IRIDIUM&page-size=100&sort=id&sort-dir=asc&page="
    public static let tleApiMaxPages = 6
    public static let userAgent = "MeshSat-iOS (+https://meshsat.net)"
    public static let fetchTimeoutSeconds = 20.0
    public static let cacheMaxAgeSec = 86400.0

    /// "IRIDIUM 100" to "IRIDIUM 199": the name search also returns the first generation and debris.
    public static func isIridiumNext(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.hasPrefix("IRIDIUM 1"), n.count == 11 else { return false }
        return n.dropFirst(8).allSatisfy(\.isNumber)
    }

    /// One element set per satellite, the newest, ordered by name.
    public static func onePerSatellite(_ tles: [TleElements]) -> [TleElements] {
        var newest = [Int: TleElements]()
        for t in tles {
            if let have = newest[t.catalogNumber], have.epochJd >= t.epochJd { continue }
            newest[t.catalogNumber] = t
        }
        return newest.values.sorted { $0.name < $1.name }
    }

    /// Newest element epoch, or 0 for an empty set.
    public static func newestEpoch(_ tles: [TleElements]) -> UnixSeconds {
        UnixSeconds(tles.map(\.epoch.value).max() ?? 0)
    }

    /// The downloaded set, unless the bundled one is newer.
    public static func choose(downloaded: [TleElements], bundled: [TleElements]) -> TleSet {
        let d = newestEpoch(downloaded)
        let b = newestEpoch(bundled)
        if !downloaded.isEmpty, d.value >= b.value {
            return TleSet(tles: downloaded, source: .downloaded, newestEpoch: d)
        }
        if !bundled.isEmpty {
            return TleSet(tles: bundled, source: .bundled, newestEpoch: b)
        }
        return TleSet(tles: [], source: .none, newestEpoch: UnixSeconds(0))
    }

    /// Parse one page of the TLE API's JSON (`member` array of name/line1/line2, `view.next`).
    /// Returns the Iridium NEXT sets on the page and whether there is a next page.
    public static func parseTleApiPage(_ data: Data) -> (sets: [TleElements], hasNext: Bool)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let members = json["member"] as? [[String: Any]] ?? []
        var out = [TleElements]()
        for m in members {
            guard let name = m["name"] as? String, isIridiumNext(name),
                let l1 = m["line1"] as? String, let l2 = m["line2"] as? String,
                let set = try? TleParser.parse(name: name.trimmingCharacters(in: .whitespaces), line1: l1, line2: l2)
            else { continue }
            out.append(set)
        }
        let hasNext = (json["view"] as? [String: Any])?["next"] != nil
        return (out, hasNext)
    }
}

/// The fetcher itself: local first, network only when asked.
public actor TleFetcher {
    private let store: TleCacheStore
    private let http: TleHttp?
    private let bundled: [TleElements]

    public init(store: TleCacheStore, http: TleHttp?, bundled: [TleElements] = BundledTle.load()) {
        self.store = store
        self.http = http
        self.bundled = bundled
    }

    public func cachedTles() async -> [TleElements] {
        TleSets.onePerSatellite(await store.load().tles)
    }

    /// Seconds since the last successful download, or -1 if there was none.
    public func cacheAgeSec(now: UnixSeconds = UnixSeconds(Date())) async -> Double {
        guard let fetched = await store.load().fetchedAt else { return -1 }
        return now.value - fetched.value
    }

    /// True when the download is older than a day, there never was one, or it lacks satellites
    /// the snapshot has.
    public func isCacheStale(now: UnixSeconds = UnixSeconds(Date())) async -> Bool {
        let age = await cacheAgeSec(now: now)
        if age < 0 || age > TleSets.cacheMaxAgeSec { return true }
        return await cachedTles().count < TleSets.onePerSatellite(bundled).count
    }

    /// The elements to predict with. Never touches the network.
    public func localTles() async -> TleSet {
        TleSets.choose(downloaded: await cachedTles(), bundled: bundled)
    }

    /// CelesTrak, then the TLE API. nil when both failed; the cache is then left as it was.
    public func refreshFromNetwork(now: UnixSeconds = UnixSeconds(Date())) async -> [TleElements]? {
        var sets = await refreshFromCelestrak()
        if sets == nil { sets = await refreshFromTleApi() }
        guard let sets else { return nil }
        await store.replace(with: sets, fetchedAt: now)
        return sets
    }

    func refreshFromCelestrak() async -> [TleElements]? {
        guard let http else { return nil }
        guard
            let (status, body) = try? await http.get(
                TleSets.celestrakIridiumURL, headers: ["User-Agent": TleSets.userAgent], timeoutSeconds: TleSets.fetchTimeoutSeconds
            ), status == 200, let text = String(data: body, encoding: .utf8)
        else { return nil }
        let sets = TleSets.onePerSatellite(TleParser.parseMulti(text))
        return sets.isEmpty ? nil : sets
    }

    func refreshFromTleApi() async -> [TleElements]? {
        guard let http else { return nil }
        var found = [TleElements]()
        for page in 1...TleSets.tleApiMaxPages {
            guard
                let (status, body) = try? await http.get(
                    TleSets.tleApiURL + String(page),
                    headers: ["User-Agent": TleSets.userAgent, "Accept": "application/json"],
                    timeoutSeconds: TleSets.fetchTimeoutSeconds
                ), status == 200, let parsed = TleSets.parseTleApiPage(body)
            else { return nil }
            found.append(contentsOf: parsed.sets)
            if !parsed.hasNext { break }
        }
        let sets = TleSets.onePerSatellite(found)
        return sets.isEmpty ? nil : sets
    }

    /// Elements to predict with. With `forceRefresh` a download is tried first.
    public func tles(forceRefresh: Bool = false) async -> [TleElements] {
        if forceRefresh, let fresh = await refreshFromNetwork() { return fresh }
        return await localTles().tles
    }
}

/// An in-memory cache for tests and previews.
public actor MemoryTleCache: TleCacheStore {
    private var tles: [TleElements] = []
    private var fetchedAt: UnixSeconds?

    public init() {}

    public func load() async -> (tles: [TleElements], fetchedAt: UnixSeconds?) {
        (tles, fetchedAt)
    }

    public func replace(with tles: [TleElements], fetchedAt: UnixSeconds) async {
        self.tles = tles
        self.fetchedAt = fetchedAt
    }
}
