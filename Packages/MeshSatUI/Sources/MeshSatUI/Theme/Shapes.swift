// Mirrors the Shapes in ui/theme/Theme.kt ("the Bridge's radii": 4 / 4 / 8 / 12 / 16 dp) and the
// radii the screens use directly. Cards are flat: a surface colour with a 1 pt border, no shadow.
import SwiftUI

public enum MSRadius {
    /// extraSmall and small
    public static let control: CGFloat = 4
    /// medium: every card
    public static let card: CGFloat = 8
    /// large: the pass banner and the hold-to-send button
    public static let sheet: CGFloat = 12
    /// extraLarge: dialogs and the bottom sheet's top corners
    public static let dialog: CGFloat = 16
    /// the pill-style tab strips
    public static let pillTab: CGFloat = 6
    public static let tag: CGFloat = 4
    public static let queueBar: CGFloat = 3
}

public enum MSSpace {
    public static let screen: CGFloat = 16
    public static let passesScreen: CGFloat = 12
    public static let list: CGFloat = 12
    public static let card: CGFloat = 12
    public static let navRow: CGFloat = 64
    public static let lane: CGFloat = 76
    public static let touch: CGFloat = 48
    public static let groupTitleSides: CGFloat = 16
    public static let groupTitleTop: CGFloat = 20
    public static let groupTitleBottom: CGFloat = 4
    public static let statusStrip: CGFloat = 36
    public static let subScreenHeader: CGFloat = 56
}

struct MSCardModifier: ViewModifier {
    let border: Color
    func body(content: Content) -> some View {
        content
            .background(MSColors.surface, in: RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous).stroke(border, lineWidth: 1))
    }
}

public extension View {
    /// A Compose `Card(colors = surface, border = 1.dp Border, shape = medium)`.
    func msCard(border: Color = MSColors.border) -> some View {
        modifier(MSCardModifier(border: border))
    }
}
