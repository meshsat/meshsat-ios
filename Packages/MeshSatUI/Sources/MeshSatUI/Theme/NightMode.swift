// Mirrors ui/theme/NightMode.kt: night mode is not a second palette but a red-only colour
// matrix over the whole window (red row 0.24, 0.47, 0.09; green and blue zero), so anything
// on screen keeps the user's night vision. On iOS the same matrix runs as a colour effect
// shader over the root view (iOS 17). UIKit-hosted content (the map, the camera preview)
// applies the matrix inside its own pipeline.
import SwiftUI

public enum NightMode {
    /// Rec.601-ish luminance weights, exactly Android's ColorMatrix red row.
    public static let weights: (r: Float, g: Float, b: Float) = (0.24, 0.47, 0.09)
}

struct NightModeModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.colorEffect(ShaderLibrary.bundle(.module).redOnly())
        } else {
            content
        }
    }
}

public extension View {
    func nightMode(_ enabled: Bool) -> some View {
        modifier(NightModeModifier(enabled: enabled))
    }
}
