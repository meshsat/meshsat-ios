// Mirrors map/MapTiles.kt (MESHSAT-1249, B5): where the map's tiles come from, so the Map tab
// and Zones behave the same off-grid:
//
// 1. the user's detailed MBTiles file, when one is chosen in Setup > Maps;
// 2. OpenStreetMap tiles saved from earlier online use, then downloaded ones when there is
//    internet (URLCache on disk, so the tiles seen once stay);
// 3. the bundled world overview (world.mbtiles, Natural Earth, zoom 0 to 3) when a download
//    fails, so the map is never blank without a network. Deeper zooms are scaled up from it.
//
// "Offline" is what the tile downloader reports, not the system: three failed downloads in a
// row mark the map offline, one success clears it. Every tile goes through the dark matrix
// (light OSM tiles inverted, hue turned, toned to the app's surfaces); the world overview is
// stored through that matrix's inverse, so it comes out as drawn. Night mode is one more matrix
// in the same pipeline, since a SwiftUI colour effect never reaches a UIKit-hosted map.
#if canImport(UIKit)
import CoreImage
import Foundation
import Logging
import MapKit
import MeshSatNet
import MeshSatStore
import UIKit

/// A detailed offline map the user added in Setup > Maps, checked to be one the map can draw.
public struct DetailedMap: Sendable, Equatable {
    public let file: URL
    public let name: String
}

public enum MapTiles {
    private static let log = Logger(label: "MapTiles")
    static let failuresBeforeOffline = 3
    private static let failures = NSLock()
    nonisolated(unsafe) private static var consecutiveFailures = 0

    /// True while online tiles cannot be downloaded and the offline tiles stand in.
    public static let offline = StateBroadcast<Bool>(false)

    /// The map's dark theme (MESHSAT-1249): light tiles are inverted, their hue turned by 180
    /// degrees so colours keep their meaning, then toned to the app's surfaces (x 0.88, + 10).
    /// Rows of Android's 4 x 5 ColorMatrix, here as CIColorMatrix vectors on 0...1.
    static let darkRows: [[CGFloat]] = [
        [0.5051, -1.2584, -0.1267, 0], [-0.3749, -0.3784, -0.1267, 0], [-0.3749, -1.2584, 0.7533, 0],
    ]
    static let darkBias: CGFloat = 234.40 / 255

    /// The chosen detailed map, or nil when the file is missing, unreadable or holds vector tiles
    /// (the map draws raster tiles only). Opens the file, so call it off the main thread.
    public static func detailedMap(_ filename: String) -> DetailedMap? {
        if filename.isEmpty || filename == MBTilesManager.bundledWorldMap { return nil }
        guard let file = MBTilesManager.file(filename) else { return nil }
        do {
            let reader = try MBTilesReader.open(file)
            if reader.isVector { return nil }
            let name = reader.name.isEmpty ? String(filename.dropLast(".mbtiles".count)) : reader.name
            return DetailedMap(file: file, name: name)
        } catch {
            log.warning("Cannot use offline map \(filename): \(error)")
            return nil
        }
    }

    static func reportDownload(ok: Bool) {
        failures.lock()
        var flip: Bool?
        if ok {
            consecutiveFailures = 0
            if offline.value { flip = false }
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= failuresBeforeOffline, !offline.value { flip = true }
        }
        failures.unlock()
        if let flip { offline.send(flip) }
    }

    /// A tile overlay on the MeshSat sources; the map view sets `canReplaceMapContent`.
    public static func newOverlay(detailed: URL?, night: Bool) -> MeshSatTileOverlay {
        MeshSatTileOverlay(world: MBTilesManager.worldFile(), detailed: detailed, night: night)
    }
}

/// OpenStreetMap with two archives added: the user's detailed map in front of everything, and
/// the world overview after the downloader, so it answers only when a download fails.
public final class MeshSatTileOverlay: MKTileOverlay, @unchecked Sendable {
    private static let log = Logger(label: "MapTiles")
    public let detailedPath: String?
    public let night: Bool
    private let world: MBTilesReader?
    private let detailed: MBTilesReader?
    private let session: URLSession
    private let processed = NSCache<NSString, NSData>()
    // No colour management: Android's ColorMatrixColorFilter works on the stored sRGB values, and
    // Core Image would otherwise apply the matrix in linear light and lighten the result.
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    ])

    init(world: URL?, detailed: URL?, night: Bool) {
        self.detailedPath = detailed?.path
        self.night = night
        self.world = world.flatMap { try? MBTilesReader.open($0) }
        self.detailed = detailed.flatMap { try? MBTilesReader.open($0) }
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("osm-tiles")
        config.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 200 << 20, directory: cacheDir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        config.httpAdditionalHeaders = ["User-Agent": "MeshSat-iOS/\(version) (https://meshsat.net)"]
        session = URLSession(configuration: config)
        // No URL template: with one, MapKit fetches the tiles itself and never calls loadTile, so
        // the dark styling was skipped and the map came up in OpenStreetMap's daylight colours
        // (phone, 25 Sep 2026). The overlay builds the OSM URL by hand instead.
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 2
        maximumZ = 19
        processed.countLimit = 600
    }

    override public func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let key = "\(path.z)/\(path.x)/\(path.y)" as NSString
        if let hit = processed.object(forKey: key) {
            result(hit as Data, nil)
            return
        }
        if let detailed, let raw = detailed.tile(z: path.z, x: path.x, y: path.y) {
            deliver(Self.styled(raw, night: night), key, result)
            return
        }
        guard let tileURL = URL(string: "https://tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png") else {
            deliver(nil, key, result)
            return
        }
        var request = URLRequest(url: tileURL)
        request.cachePolicy = .returnCacheDataElseLoad
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, status == 200 || (status == 0 && !data.isEmpty) {
                MapTiles.reportDownload(ok: true)
                deliver(Self.styled(data, night: night), key, result)
            } else {
                MapTiles.reportDownload(ok: false)
                deliver(worldTile(path).flatMap { Self.styled($0, night: night) }, key, result)
            }
        }
        task.resume()
    }

    private func deliver(_ data: Data?, _ key: NSString, _ result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        if let data { processed.setObject(data as NSData, forKey: key) }
        result(data, data == nil ? MBTilesError("no tile") : nil)
    }

    /// The world overview at z <= 3, or that tile's quadrant scaled up for a deeper zoom.
    private func worldTile(_ path: MKTileOverlayPath) -> Data? {
        guard let world else { return nil }
        if path.z <= 3 { return world.tile(z: path.z, x: path.x, y: path.y) }
        let up = path.z - 3
        guard let raw = world.tile(z: 3, x: path.x >> up, y: path.y >> up), let img = UIImage(data: raw) else { return nil }
        let side = 256.0 / Double(1 << up)
        let ox = Double(path.x & ((1 << up) - 1)) * side
        let oy = Double(path.y & ((1 << up) - 1)) * side
        let scale = img.size.width / 256
        guard
            let cg = img.cgImage?.cropping(
                to: CGRect(x: ox * scale, y: oy * scale, width: max(1, side * scale), height: max(1, side * scale)))
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .low
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        return out.pngData()
    }

    /// The dark matrix, then night mode's red-only matrix, then back to PNG.
    public static func styled(_ raw: Data, night: Bool) -> Data? {
        guard let input = CIImage(data: raw) else { return nil }
        var image = input
        let dark = CIFilter(name: "CIColorMatrix")!
        dark.setValue(image, forKey: kCIInputImageKey)
        dark.setValue(CIVector(values: MapTiles.darkRows[0], count: 4), forKey: "inputRVector")
        dark.setValue(CIVector(values: MapTiles.darkRows[1], count: 4), forKey: "inputGVector")
        dark.setValue(CIVector(values: MapTiles.darkRows[2], count: 4), forKey: "inputBVector")
        dark.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        dark.setValue(CIVector(x: MapTiles.darkBias, y: MapTiles.darkBias, z: MapTiles.darkBias, w: 0), forKey: "inputBiasVector")
        guard let darkened = dark.outputImage else { return nil }
        image = darkened
        if night {
            let red = CIFilter(name: "CIColorMatrix")!
            red.setValue(image, forKey: kCIInputImageKey)
            red.setValue(CIVector(x: 0.24, y: 0.47, z: 0.09, w: 0), forKey: "inputRVector")
            red.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
            red.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
            red.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            red.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
            guard let reddened = red.outputImage else { return nil }
            image = reddened
        }
        guard let cg = ciContext.createCGImage(image, from: input.extent) else { return nil }
        return UIImage(cgImage: cg).pngData()
    }
}
#endif
