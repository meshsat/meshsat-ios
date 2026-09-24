// The Material 3 Switch as Android draws it (SwitchDefaults.colors(checkedTrackColor =
// MeshSatTeal)): a 52 x 32 dp track, the orange track with an ink thumb when on, the outlined
// track with a muted thumb when off. Native iOS toggles are not used (parity rule).
import SwiftUI

public struct MSSwitch: View {
    @Binding var isOn: Bool
    let label: String
    let enabled: Bool

    public init(isOn: Binding<Bool>, label: String, enabled: Bool = true) {
        _isOn = isOn
        self.label = label
        self.enabled = enabled
    }

    public var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? MSColors.signalOrange : MSColors.surfaceLight)
                    .overlay(Capsule().stroke(isOn ? Color.clear : MSColors.textMuted, lineWidth: 2))
                Circle().fill(isOn ? MSColors.ink : MSColors.textMuted)
                    .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                    .padding(isOn ? 4 : 8)
            }
            .frame(width: 52, height: 32)
            .opacity(enabled ? 1 : 0.38)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// SettingsScreen.kt's SettingRow: a label on the left, a control on the right.
public struct SettingRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    public init(_ label: String, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.control = control
    }

    public var body: some View {
        HStack {
            Text(label).msText(.bodyMedium)
            Spacer(minLength: 8)
            control()
        }
    }
}

/// The small selectable text chips Android's settings use for modes (compression, stages, timeouts).
public struct ModeChips: View {
    let options: [(key: String, label: String)]
    let selected: String
    let onSelect: (String) -> Void

    public init(_ options: [(key: String, label: String)], selected: String, onSelect: @escaping (String) -> Void) {
        self.options = options
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.key) { option in
                let on = option.key == selected
                Button {
                    onSelect(option.key)
                } label: {
                    Text(option.label).msText(.bodySmall, color: on ? MSColors.teal : MSColors.textMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            on ? MSColors.teal.opacity(0.15) : MSColors.surface,
                            in: RoundedRectangle(cornerRadius: MSRadius.tag, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
