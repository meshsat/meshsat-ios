// The Material 3 OutlinedTextField as Android draws it: a 4 dp corner outline, the border colour
// stronger when focused, an optional label line above and leading or trailing glyphs.
import SwiftUI

public struct MSOutlinedTextField<Leading: View, Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    let label: String?
    let secure: Bool
    let focusedBorder: Color
    let lineLimit: Int
    let keyboard: UIKeyboardType
    let submitLabel: SubmitLabel
    let onSubmit: () -> Void
    let leading: () -> Leading
    let trailing: () -> Trailing
    @FocusState private var focused: Bool

    public init(
        text: Binding<String>, placeholder: String = "", label: String? = nil, secure: Bool = false,
        focusedBorder: Color = MSColors.signalOrange,
        lineLimit: Int = 1, keyboard: UIKeyboardType = .default, submitLabel: SubmitLabel = .done, onSubmit: @escaping () -> Void = {},
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        _text = text
        self.placeholder = placeholder
        self.label = label
        self.secure = secure
        self.focusedBorder = focusedBorder
        self.lineLimit = lineLimit
        self.keyboard = keyboard
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).msText(.bodySmall, color: focused ? focusedBorder : MSColors.textMuted) }
            HStack(spacing: 8) {
                leading()
                Group {
                    if secure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text, axis: lineLimit > 1 ? .vertical : .horizontal).lineLimit(1...max(1, lineLimit))
                    }
                }
                .msText(.bodyMedium)
                .keyboardType(keyboard)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .focused($focused)
                .autocorrectionDisabled(secure || keyboard == .asciiCapable)
                trailing()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: MSRadius.control, style: .continuous).stroke(
                    focused ? focusedBorder : MSColors.border, lineWidth: focused ? 2 : 1))
        }
    }
}
