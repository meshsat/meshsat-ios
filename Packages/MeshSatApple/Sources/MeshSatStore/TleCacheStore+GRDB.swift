// The tle_cache table as the TLE fetcher's store (satellite/TleFetcher.kt reads the same Room
// table): rows are the three lines and the fetch time in Unix seconds; a replace clears the
// table and writes the new set.
import Foundation
import MeshSatEngine
import MeshSatSatellite

extension TleCacheDao: TleCacheStore {
    public func load() async -> (tles: [TleElements], fetchedAt: UnixSeconds?) {
        guard let rows = try? await getAll() else { return ([], nil) }
        let tles = rows.compactMap { try? TleParser.parse(name: $0.satelliteName, line1: $0.line1, line2: $0.line2) }
        let oldest = rows.map(\.fetchedAt).min()
        return (tles, oldest.map { UnixSeconds(Double($0)) })
    }

    public func replace(with tles: [TleElements], fetchedAt: UnixSeconds) async {
        let at = Int64(fetchedAt.value)
        let entries = tles.map { TleCacheEntry(satelliteName: $0.name, line1: $0.line1, line2: $0.line2, fetchedAt: at) }
        try? await deleteAll()
        try? await insertAll(entries)
    }
}
