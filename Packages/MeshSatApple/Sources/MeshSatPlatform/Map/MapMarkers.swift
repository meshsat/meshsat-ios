// Mirrors map/MapMarkers.kt (MESHSAT-1249): the map's markers drawn as images. A diamond for a
// node, with its full name under it on a dark pill, cut with an ellipsis only when it is wider
// than `maxLabelPt`; a round dot for this phone. Colours come in from the theme tokens; the
// caller passes them through the night matrix when night mode is on, since a SwiftUI colour
// effect never reaches the map view.
#if canImport(UIKit)
import UIKit

/// A marker image and the point of it that sits on the position (fractions of its size).
public struct MarkerIcon: @unchecked Sendable {
    public let image: UIImage
    public let anchorU: CGFloat
    public let anchorV: CGFloat
    /// MapKit's centre offset so that the anchor point sits on the coordinate.
    public var centerOffset: CGPoint {
        CGPoint(x: (0.5 - anchorU) * image.size.width, y: (0.5 - anchorV) * image.size.height)
    }
}

public final class MarkerPainter: @unchecked Sendable {
    private let labelPt: CGFloat
    private let maxLabelPt: CGFloat
    private let font: UIFont
    private let bg: UIColor
    private let textPrimary: UIColor
    private let textMuted: UIColor
    private var cache: [String: MarkerIcon] = [:]
    private let lock = NSLock()

    /// `labelPt` is the label size in points (12 sp on Android, so it follows the user's font
    /// size when the caller scales it); the theme's background and text colours are given so the
    /// night variant can pass them already reddened.
    public init(labelPt: CGFloat, maxLabelPt: CGFloat, font: UIFont, bg: UIColor, textPrimary: UIColor, textMuted: UIColor) {
        self.labelPt = labelPt
        self.maxLabelPt = maxLabelPt
        self.font = font
        self.bg = bg
        self.textPrimary = textPrimary
        self.textMuted = textMuted
    }

    /// A node: a diamond in `fill`, faded when `stale`, with `label` under it.
    public func node(label: String, fill: UIColor, stale: Bool) -> MarkerIcon {
        let key = "node|\(label)|\(fill.hashValue)|\(stale)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        if cache.count > 300 { cache.removeAll() }
        lock.unlock()

        let symbol: CGFloat = 22
        let stroke: CGFloat = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let text = Self.ellipsize(label, attrs: attrs, maxWidth: maxLabelPt)
        let padH: CGFloat = 6
        let padV: CGFloat = 3
        let gap: CGFloat = 2
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillW = textSize.width + 2 * padH
        let pillH = textSize.height + 2 * padV
        let width = ceil(max(symbol, pillW))
        let height = ceil(symbol + gap + pillH)
        let cx = width / 2
        let cy = symbol / 2
        let r = symbol / 2 - stroke
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            let diamond = UIBezierPath()
            diamond.move(to: CGPoint(x: cx, y: cy - r))
            diamond.addLine(to: CGPoint(x: cx + r, y: cy))
            diamond.addLine(to: CGPoint(x: cx, y: cy + r))
            diamond.addLine(to: CGPoint(x: cx - r, y: cy))
            diamond.close()
            fill.withAlphaComponent(stale ? 115.0 / 255 : 1).setFill()
            diamond.fill()
            bg.setStroke()
            diamond.lineWidth = stroke
            diamond.stroke()
            // Name on a dark pill, so it reads on any tile.
            let top = symbol + gap
            let left = (width - pillW) / 2
            bg.withAlphaComponent(0.8).setFill()
            UIBezierPath(roundedRect: CGRect(x: left, y: top, width: pillW, height: pillH), cornerRadius: 4).fill()
            var textAttrs = attrs
            textAttrs[.foregroundColor] = stale ? textMuted : textPrimary
            (text as NSString).draw(at: CGPoint(x: left + padH, y: top + padV), withAttributes: textAttrs)
            _ = ctx
        }
        let icon = MarkerIcon(image: image, anchorU: 0.5, anchorV: cy / height)
        lock.lock()
        cache[key] = icon
        lock.unlock()
        return icon
    }

    /// A round dot in `fill` with a dark ring, anchored at its centre (this phone, a zone's centre).
    public func dot(fill: UIColor, sizePt: CGFloat) -> MarkerIcon {
        let key = "dot|\(fill.hashValue)|\(sizePt)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let stroke: CGFloat = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: sizePt, height: sizePt)).image { _ in
            bg.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: sizePt, height: sizePt)).fill()
            fill.setFill()
            UIBezierPath(ovalIn: CGRect(x: stroke, y: stroke, width: sizePt - 2 * stroke, height: sizePt - 2 * stroke)).fill()
        }
        let icon = MarkerIcon(image: image, anchorU: 0.5, anchorV: 0.5)
        lock.lock()
        cache[key] = icon
        lock.unlock()
        return icon
    }

    static func ellipsize(_ text: String, attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> String {
        if (text as NSString).size(withAttributes: attrs).width <= maxWidth { return text }
        var s = text
        while !s.isEmpty {
            s.removeLast()
            let candidate = s + "\u{2026}"
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth { return candidate }
        }
        return "\u{2026}"
    }
}

extension UIColor {
    /// Night mode's red-only matrix (red row 0.24, 0.47, 0.09): the same as the window's shader.
    public func nightRed() -> UIColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: 0.24 * r + 0.47 * g + 0.09 * b, green: 0, blue: 0, alpha: a)
    }
}
#endif
