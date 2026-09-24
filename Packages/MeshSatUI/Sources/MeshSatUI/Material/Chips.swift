// The Material 3 FilterChip as Android draws it: a 32 dp pill with a 1 dp outline, the
// container and label colours the screens pass in when selected.
import SwiftUI

public struct MSFilterChip: View {
    let label: String
    let selected: Bool
    let selectedContainer: Color
    let selectedLabel: Color
    let action: () -> Void

    public init(
        _ label: String, selected: Bool, selectedContainer: Color = MSColors.surfaceLight, selectedLabel: Color = MSColors.offWhite,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.selected = selected
        self.selectedContainer = selectedContainer
        self.selectedLabel = selectedLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .msText(.bodySmall, color: selected ? selectedLabel : MSColors.textSecondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(selected ? selectedContainer : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.clear : MSColors.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Material's IconButton: a 48 dp touch target around a 24 dp glyph (or the size given).
public struct MSIconButton: View {
    let image: Image
    let label: String
    let tint: Color
    let size: CGFloat
    let glyph: CGFloat
    let enabled: Bool
    let action: () -> Void

    public init(
        _ image: Image, label: String, tint: Color = MSColors.textSecondary, size: CGFloat = 48, glyph: CGFloat = 24, enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.image = image
        self.label = label
        self.tint = tint
        self.size = size
        self.glyph = glyph
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            image.resizable().scaledToFit().frame(width: glyph, height: glyph).foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
