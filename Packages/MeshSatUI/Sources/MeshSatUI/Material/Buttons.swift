// The Material 3 filled button as Android draws it: a pill, the container colour, ink text,
// bodySmall label, a 10 percent pressed layer. Native iOS buttons are not used (parity rule).
import SwiftUI

public struct MSFilledButton: View {
    let title: String
    let container: Color
    let fullWidth: Bool
    let action: () -> Void

    let labelColor: Color

    public init(
        _ title: String, container: Color = MSColors.signalOrange, labelColor: Color = MSColors.ink, fullWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.container = container
        self.labelColor = labelColor
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .msText(.bodySmall, color: labelColor)
                .padding(.horizontal, 24)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 40)
                .background(container, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(MSPressedStyle())
    }
}

/// The 10 percent state layer of a pressed Material button.
struct MSPressedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0)))
    }
}

/// The Material 3 text button: label only, the primary colour, the same pill hit area.
public struct MSTextButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    public init(_ title: String, color: Color = MSColors.signalOrange, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .msText(.labelLarge, color: color)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(MSPressedStyle())
    }
}

/// The Material 3 outlined button: a pill with a 1 dp outline and no fill.
public struct MSOutlinedButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .msText(.bodySmall, color: enabled ? MSColors.offWhite : MSColors.textMuted)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: 40)
                .overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(MSPressedStyle())
        .disabled(!enabled)
    }
}
