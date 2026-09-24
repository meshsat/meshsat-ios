// Mirrors map/MBTilesReader.kt: a read-only accessor for MBTiles (SQLite) map tile files.
// MBTiles spec: https://github.com/mapbox/mbtiles-spec/blob/master/1.3/spec.md. The tiles table
// uses TMS y (origin bottom-left) while MapKit's tile paths use XYZ (origin top-left); this
// class flips it.
import Foundation
import GRDB

public struct MBTilesError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

public final class MBTilesReader: Sendable {
    private let queue: DatabaseQueue
    public let metadata: [String: String]

    public static func open(_ url: URL) throws -> MBTilesReader {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MBTilesError("MBTiles file not found: \(url.path)") }
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        let (tables, meta) = try queue.read { db -> (Set<String>, [String: String]) in
            let tables = Set(
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('tiles','metadata')"))
            guard tables.contains("tiles") else { throw MBTilesError("Not a valid MBTiles file: missing 'tiles' table") }
            guard tables.contains("metadata") else { throw MBTilesError("Not a valid MBTiles file: missing 'metadata' table") }
            var meta: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT name, value FROM metadata") {
                if let k: String = row[0] { meta[k] = row[1] ?? "" }
            }
            return (tables, meta)
        }
        _ = tables
        return MBTilesReader(queue: queue, metadata: meta)
    }

    private init(queue: DatabaseQueue, metadata: [String: String]) {
        self.queue = queue
        self.metadata = metadata
    }

    /// Tile bytes for the given XYZ (slippy map) coordinates, or nil when the file has none.
    public func tile(z: Int, x: Int, y: Int) -> Data? {
        let tmsY = (1 << z) - 1 - y
        return try? queue.read { db in
            try Data.fetchOne(
                db, sql: "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", arguments: [z, x, tmsY])
        }
    }

    public var name: String { metadata["name"] ?? "" }
    public var descriptionText: String { metadata["description"] ?? "" }
    public var minZoom: Int? { metadata["minzoom"].flatMap { Int($0) } }
    public var maxZoom: Int? { metadata["maxzoom"].flatMap { Int($0) } }
    public var bounds: String? { metadata["bounds"] }
    public var format: String { metadata["format"] ?? "png" }
    public var isVector: Bool { format.lowercased() == "pbf" }
    public var mimeType: String {
        switch format.lowercased() {
        case "pbf": "application/x-protobuf"
        case "jpg", "jpeg": "image/jpeg"
        default: "image/png"
        }
    }
}
