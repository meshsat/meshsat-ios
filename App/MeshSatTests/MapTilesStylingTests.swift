import MeshSatPlatform
import UIKit
import XCTest

// The map's dark theme (MESHSAT-1249) is a colour matrix run over every tile. A daylight
// OpenStreetMap tile must come out dark, as it does on Android with the same matrix.
final class MapTilesStylingTests: XCTestCase {
    private func tile(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData()!
    }

    private struct RGB {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
    }

    private func centerPixel(_ data: Data) -> RGB {
        let image = UIImage(data: data)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image.cgImage!, in: CGRect(x: -4, y: -4, width: 8, height: 8))
        return RGB(r: CGFloat(pixel[0]) / 255, g: CGFloat(pixel[1]) / 255, b: CGFloat(pixel[2]) / 255)
    }

    func testADaylightTileComesOutDark() throws {
        // OSM Carto's land colour.
        let land = tile(UIColor(red: 0.949, green: 0.937, blue: 0.914, alpha: 1))
        let styled = try XCTUnwrap(MeshSatTileOverlay.styled(land, night: false))
        let p = centerPixel(styled)
        XCTAssertLessThan(max(p.r, p.g, p.b), 0.2, "land \(p)")
    }

    func testWaterKeepsItsHueDarkened() throws {
        // OSM Carto's water: after inversion and the 180 degree hue turn it must stay bluish.
        let water = tile(UIColor(red: 0.667, green: 0.827, blue: 0.875, alpha: 1))
        let styled = try XCTUnwrap(MeshSatTileOverlay.styled(water, night: false))
        let p = centerPixel(styled)
        XCTAssertLessThan(max(p.r, p.g, p.b), 0.45, "water \(p)")
        XCTAssertGreaterThan(p.b, p.r, "water should stay blue, got \(p)")
    }

    func testNightModeLeavesRedOnly() throws {
        let land = tile(UIColor(red: 0.949, green: 0.937, blue: 0.914, alpha: 1))
        let styled = try XCTUnwrap(MeshSatTileOverlay.styled(land, night: true))
        let p = centerPixel(styled)
        XCTAssertEqual(p.g, 0, accuracy: 0.01)
        XCTAssertEqual(p.b, 0, accuracy: 0.01)
    }
}
