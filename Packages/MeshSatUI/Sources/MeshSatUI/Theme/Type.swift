// Mirrors ui/theme/Type.kt: IBM Plex Sans for text, IBM Plex Mono for numbers, times and ids,
// on a 1.25 scale over a 16 pt body. The Android app ships the five TTFs in res/font and the
// app target here ships the same files (UIAppFonts); their PostScript names are the ones below.
// A "bold" request uses the SemiBold file, and Plex Mono's semibold and bold use the Medium
// file, as in Type.kt. Never apply a bold or a font-weight modifier on these fonts: iOS would
// synthesise a bold that Android never shows (a SwiftLint rule enforces this).
import SwiftUI

public enum MSFont {
    public enum Weight: Sendable {
        case regular, medium, semiBold, bold
    }

    static let sansRegular = "IBMPlexSans"
    static let sansMedium = "IBMPlexSans-Medm"
    static let sansSemiBold = "IBMPlexSans-SmBld"
    static let monoRegular = "IBMPlexMono"
    static let monoMedium = "IBMPlexMono-Medm"

    public static func sans(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .regular: name = sansRegular
        case .medium: name = sansMedium
        case .semiBold, .bold: name = sansSemiBold
        }
        return .custom(name, size: size, relativeTo: style)
    }

    public static func mono(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .regular: name = monoRegular
        case .medium, .semiBold, .bold: name = monoMedium
        }
        return .custom(name, size: size, relativeTo: style)
    }
}

/// One entry of the Material type scale as Type.kt sets it: size and line height in sp (1 sp = 1 pt).
public struct MSTextStyle: Sendable, Equatable {
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let weight: MSFont.Weight
    public let relativeTo: Font.TextStyle

    public init(_ size: CGFloat, _ lineHeight: CGFloat, _ weight: MSFont.Weight = .regular, relativeTo: Font.TextStyle = .body) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.relativeTo = relativeTo
    }

    public static let displaySmall = MSTextStyle(32, 40, .semiBold, relativeTo: .largeTitle)
    public static let headlineLarge = MSTextStyle(28, 34, .semiBold, relativeTo: .title)
    public static let headlineMedium = MSTextStyle(22, 28, .semiBold, relativeTo: .title2)
    public static let headlineSmall = MSTextStyle(20, 26, .semiBold, relativeTo: .title3)
    public static let titleLarge = MSTextStyle(18, 24, .semiBold, relativeTo: .headline)
    public static let titleMedium = MSTextStyle(16, 22, .medium, relativeTo: .headline)
    public static let titleSmall = MSTextStyle(14, 20, .medium, relativeTo: .subheadline)
    public static let bodyLarge = MSTextStyle(16, 24, .regular, relativeTo: .body)
    public static let bodyMedium = MSTextStyle(14, 20, .regular, relativeTo: .callout)
    public static let bodySmall = MSTextStyle(12, 16, .regular, relativeTo: .footnote)
    public static let labelLarge = MSTextStyle(14, 20, .medium, relativeTo: .subheadline)
    public static let labelMedium = MSTextStyle(12, 16, .medium, relativeTo: .footnote)
    public static let labelSmall = MSTextStyle(12, 16, .medium, relativeTo: .caption)

    /// IBM Plex's natural line box is about 1.3 x size (ascender 1025 + descender 275 per 1000).
    /// SwiftUI can only add to it, so the extra is what Compose's fixed lineHeight adds on top.
    var extraLineSpacing: CGFloat { max(0, lineHeight - 1.3 * size) }
}

struct MSTextModifier: ViewModifier {
    let style: MSTextStyle
    let mono: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(
                mono
                    ? MSFont.mono(style.size, style.weight, relativeTo: style.relativeTo)
                    : MSFont.sans(style.size, style.weight, relativeTo: style.relativeTo)
            )
            .lineSpacing(style.extraLineSpacing)
            .foregroundStyle(color)
    }
}

public extension View {
    /// The equivalent of `Text(..., style = MaterialTheme.typography.x, color = y)` in Compose.
    func msText(_ style: MSTextStyle, mono: Bool = false, color: Color = MSColors.textPrimary) -> some View {
        modifier(MSTextModifier(style: style, mono: mono, color: color))
    }
}
