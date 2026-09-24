// Mirrors ui/theme/Color.kt (MeshSat Android, commit 69e213b, MESHSAT-1249): the MeshSat brand
// palette, Space Black with Signal Orange, with the same token names so the two files diff
// side by side. Values are literal ARGB, not asset-catalog colours, on purpose.
import SwiftUI

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

public enum MSColors {
    // Brand (MeshSat_Brand_Guide.pdf page 6)
    public static let spaceBlack = Color(hex: 0x040406)
    public static let signalOrange = Color(hex: 0xF96118)
    public static let offWhite = Color(hex: 0xF7F7F4)

    // Surfaces
    public static let bg = spaceBlack
    public static let surface = Color(hex: 0x15151B)
    public static let surfaceLight = Color(hex: 0x24242C)
    public static let border = Color(hex: 0x24242C)

    // Text
    public static let textPrimary = Color(hex: 0xEBEBEE)
    public static let textSecondary = Color(hex: 0xB4B4BD)
    public static let textMuted = Color(hex: 0x8A8A96)

    // Accent (the token is still called "teal" in the Kotlin, it has been Signal Orange since 19 Sep 2026)
    public static let teal = signalOrange
    public static let tealLight = Color(hex: 0xFF7C3B)
    /// Text on orange: always ink, never white.
    public static let ink = spaceBlack

    // States
    public static let green = Color(hex: 0x34D399)
    public static let amber = Color(hex: 0xFBBF24)
    public static let red = Color(hex: 0xF87171)
    public static let blue = Color(hex: 0x8FB8DE)

    // Signal quality
    public static let signalExcellent = green
    public static let signalGood = green
    public static let signalFair = amber
    public static let signalPoor = red

    // Transports
    public static let iridium = Color(hex: 0xB9A7E6)
    public static let mesh = Color(hex: 0xC8B89A)
    public static let cellular = Color(hex: 0xE0B458)
    public static let sms = cellular
    public static let hub = Color(hex: 0x8FB8DE)
    public static let radio = offWhite
}

/// The Material 3 colour roles Theme.kt derives from the tokens, for the components that read
/// them implicitly (dialogs, chips, outlines, error containers).
public enum MSScheme {
    public static let primary = MSColors.signalOrange
    public static let onPrimary = MSColors.ink
    public static let primaryContainer = Color(hex: 0x3D1405)
    public static let onPrimaryContainer = Color(hex: 0xFFC4A6)
    public static let secondary = MSColors.mesh
    public static let onSecondary = MSColors.ink
    public static let secondaryContainer = MSColors.surfaceLight
    public static let onSecondaryContainer = MSColors.textPrimary
    public static let tertiary = MSColors.iridium
    public static let onTertiary = MSColors.ink
    public static let background = MSColors.bg
    public static let surface = MSColors.surface
    public static let surfaceContainerLow = Color(hex: 0x0B0B0F)
    public static let surfaceContainerHigh = Color(hex: 0x1B1B22)
    public static let surfaceVariant = MSColors.surfaceLight
    public static let onSurface = MSColors.textPrimary
    public static let onSurfaceVariant = MSColors.textSecondary
    public static let inverseSurface = MSColors.offWhite
    public static let inverseOnSurface = MSColors.ink
    public static let inversePrimary = Color(hex: 0xBF450B)
    public static let outline = Color(hex: 0x3A3A44)
    public static let outlineVariant = MSColors.border
    public static let error = MSColors.red
    public static let onError = MSColors.ink
    public static let errorContainer = Color(hex: 0x3B1414)
    public static let onErrorContainer = Color(hex: 0xFCA5A5)
    public static let scrim = Color(hex: 0x000000, alpha: 0.70)
}
