// Mirrors map/MBTilesManager.kt: MBTiles file import, listing, deletion and the bundled world
// overview. Files live in Application Support/MeshSat/mbtiles/ (excluded from nothing: a map
// the user added is theirs to keep across backups, as on Android's internal storage).
import Foundation
import Logging

public struct MBTilesInfo: Sendable, Equatable, Identifiable {
    public let filename: String
    public let sizeBytes: Int64
    public let name: String
    public let format: String
    public let isVector: Bool
    public let minZoom: Int?
    public let maxZoom: Int?
    public let bounds: String?
    public var id: String { filename }
}

public enum MBTilesManager {
    private static let log = Logger(label: "MBTilesManager")
    public static let bundledWorldMap = "world.mbtiles"
    /// Bumped whenever the bundled world.mbtiles changes, so an update replaces the copy made at
    /// first launch. 2: tiles stored through the inverse of MapTiles' dark matrix (MESHSAT-1249).
    public static let bundledWorldMapVersion = "2"

    public static func directory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("MeshSat/mbtiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies the bundled world overview (about 250 KB) next to the added maps: on first launch,
    /// when the file is missing, and when the bundled version changed.
    public static func ensureBundledMap(from bundle: Bundle = .main) {
        guard let dir = try? directory() else { return }
        let dest = dir.appendingPathComponent(bundledWorldMap)
        let marker = dir.appendingPathComponent("\(bundledWorldMap).version")
        let current = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if FileManager.default.fileExists(atPath: dest.path), current == bundledWorldMapVersion { return }
        guard let src = bundle.url(forResource: "world", withExtension: "mbtiles") else {
            log.warning("No bundled world map in the app bundle")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            try bundledWorldMapVersion.write(to: marker, atomically: true, encoding: .utf8)
            log.info("Extracted bundled world map v\(bundledWorldMapVersion)")
        } catch {
            log.warning("Could not extract the bundled world map: \(error)")
        }
    }

    /// The world overview's file, extracting it first if needed.
    public static func worldFile() -> URL? {
        ensureBundledMap()
        return file(bundledWorldMap)
    }

    /// Imports a file the user picked (the caller holds its security scope) and returns its
    /// filename here. A file that is not MBTiles is removed again.
    public static func importFile(from src: URL) throws -> String {
        let filename = sanitize(src.lastPathComponent)
        let dest = try directory().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: src, to: dest)
        do {
            _ = try MBTilesReader.open(dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw MBTilesError("Invalid MBTiles file: \(error)")
        }
        log.info("Imported MBTiles \(filename)")
        return filename
    }

    /// Every .mbtiles file here with its metadata, by name.
    public static func listFiles() -> [MBTilesInfo] {
        guard let dir = try? directory(), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".mbtiles") }.compactMap { name -> MBTilesInfo? in
            let url = dir.appendingPathComponent(name)
            guard let reader = try? MBTilesReader.open(url) else {
                log.warning("Skipping invalid MBTiles \(name)")
                return nil
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return MBTilesInfo(
                filename: name, sizeBytes: size, name: reader.name.isEmpty ? String(name.dropLast(".mbtiles".count)) : reader.name,
                format: reader.format, isVector: reader.isVector, minZoom: reader.minZoom, maxZoom: reader.maxZoom, bounds: reader.bounds)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func delete(_ filename: String) {
        guard let url = file(filename) else { return }
        try? FileManager.default.removeItem(at: url)
        log.info("Deleted MBTiles \(filename)")
    }

    public static func file(_ filename: String) -> URL? {
        guard let dir = try? directory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sanitize(_ name: String) -> String {
        let base = String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" })
        return base.hasSuffix(".mbtiles") ? base : base + ".mbtiles"
    }
}
