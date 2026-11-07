// Mirrors media/PhotoShrinker.kt (MESHSAT-1735): a photo from the picker down to a WebP that fits
// an LXMF message. The long edge at most 640 px, then the quality (70, 50, 35, 20) and the edge
// (halved down to 64 px) come down until the bytes fit the budget. What every client writes is
// "webp", so the far end shows it as it is. ImageIO reads the picture (applying its rotation and
// decoding straight to the small size); libwebp writes the WebP, because ImageIO cannot.
import CoreGraphics
import Foundation
import ImageIO
import libwebp

public enum PhotoShrinker {
    public static let maxEdge = 640
    private static let qualities: [Float] = [70, 50, 35, 20]

    /// The WebP bytes within `budgetBytes`, or nil when the picture cannot be read or never fits.
    public static func shrink(_ data: Data, budgetBytes: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var edge = maxEdge
        while edge >= 64 {
            guard let image = thumbnail(source, edge: edge) else { return nil }
            for q in qualities {
                if let bytes = webp(image, quality: q), bytes.count <= budgetBytes { return bytes }
            }
            edge /= 2
        }
        return nil
    }

    private static func thumbnail(_ source: CGImageSource, edge: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// One lossy WebP of `image` at `quality` (0-100).
    public static func webp(_ image: CGImage, quality: Float) -> [UInt8]? {
        let w = image.width
        let h = image.height
        let stride = w * 4
        var rgba = [UInt8](repeating: 0, count: stride * h)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var output: UnsafeMutablePointer<UInt8>?
        let size = rgba.withUnsafeBufferPointer { WebPEncodeRGBA($0.baseAddress, Int32(w), Int32(h), Int32(stride), quality, &output) }
        guard size > 0, let output else { return nil }
        defer { WebPFree(output) }
        return Array(UnsafeBufferPointer(start: output, count: size))
    }
}
