// Mirrors ui/theme/NightMode.kt: night mode is not a second palette but a red-only colour
// matrix over the whole window (red row 0.24, 0.47, 0.09; green and blue zero), so anything
// on screen keeps the user's night vision. Android sets one hardware-layer colour filter on
// the window's root view. On iOS the same matrix is two Core Animation filters on the root
// view: grayscale (Rec. 601 luminance, Android's weights normalised) then a multiply by red at
// 0.8 (Android's weights sum to 0.8). Core Animation filters apply to the whole layer tree,
// UIKit-backed scroll and navigation views included; the Metal colour-effect shader used until
// 7 Nov 2026 did not, and every screen (a ScrollView) rendered black (MESHSAT-1827).
import SwiftUI

public enum NightMode {
    /// Rec.601-ish luminance weights, exactly Android's ColorMatrix red row.
    public static let redWeight: Float = 0.24
    public static let greenWeight: Float = 0.47
    public static let blueWeight: Float = 0.09
    /// What the luminance is multiplied by on its way into red: the row's sum.
    public static let dim: Double = Double(redWeight + greenWeight + blueWeight)
}

struct NightModeModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content
            .grayscale(enabled ? 1 : 0)
            .colorMultiply(enabled ? Color(red: NightMode.dim, green: 0, blue: 0) : .white)
    }
}

public extension View {
    /// The red-only window filter; applied once, at the root (RootView), never per screen.
    func nightMode(_ enabled: Bool) -> some View {
        modifier(NightModeModifier(enabled: enabled))
    }
}
