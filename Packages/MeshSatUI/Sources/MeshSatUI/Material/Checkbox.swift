// The Material 3 Checkbox as Android draws it: an 18 dp box with 2 dp corners, the primary
// colour filled with an ink tick when checked, a 2 dp outline in the muted text colour when
// not, inside a 48 dp touch target. Native iOS toggles are not used (parity rule).
import SwiftUI

public struct MSCheckbox: View {
    let checked: Bool
    let label: String
    let enabled: Bool
    let onChange: ((Bool) -> Void)?

    /// `onChange` nil draws a checkbox that is not a control of its own (the row around it is).
    public init(checked: Bool, label: String, enabled: Bool = true, onChange: ((Bool) -> Void)? = nil) {
        self.checked = checked
        self.label = label
        self.enabled = enabled
        self.onChange = onChange
    }

    public var body: some View {
        if let onChange {
            Button {
                onChange(!checked)
            } label: {
                box.frame(width: MSSpace.touch, height: MSSpace.touch).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(label)
            .accessibilityValue(checked ? "On" : "Off")
        } else {
            box.frame(width: MSSpace.touch, height: MSSpace.touch).accessibilityHidden(true)
        }
    }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(checked ? MSColors.signalOrange : Color.clear).frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 2).stroke(checked ? MSColors.signalOrange : MSColors.textMuted, lineWidth: 2).frame(
                width: 18, height: 18)
            if checked {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(MSColors.ink)
            }
        }
        .opacity(enabled ? 1 : 0.38)
    }
}

/// The Material 3 RadioButton: a 20 dp ring, the primary colour with a dot when selected.
public struct MSRadioButton: View {
    let selected: Bool
    let enabled: Bool

    public init(selected: Bool, enabled: Bool = true) {
        self.selected = selected
        self.enabled = enabled
    }

    public var body: some View {
        ZStack {
            Circle().stroke(selected ? MSColors.signalOrange : MSColors.textMuted, lineWidth: 2).frame(width: 20, height: 20)
            if selected { Circle().fill(MSColors.signalOrange).frame(width: 10, height: 10) }
        }
        .frame(width: MSSpace.touch, height: MSSpace.touch)
        .opacity(enabled ? 1 : 0.38)
        .accessibilityHidden(true)
    }
}
