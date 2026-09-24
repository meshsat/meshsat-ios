// The Material 3 ExposedDropdownMenuBox as the rule editor uses it: a read-only outlined field
// with a label, the chosen value and a trailing arrow; a tap opens the menu of options, and a
// supporting line (red on error) sits under it. The menu is SwiftUI's Menu, styled as the field.
import SwiftUI

public struct MSDropdownField: View {
    let label: String
    let value: String
    let options: [String]
    let display: (String) -> String
    let supportingText: String?
    let isError: Bool
    let onSelect: (String) -> Void

    public init(
        label: String, value: String, options: [String], display: @escaping (String) -> String = { $0 }, supportingText: String? = nil,
        isError: Bool = false, onSelect: @escaping (String) -> Void
    ) {
        self.label = label
        self.value = value
        self.options = options
        self.display = display
        self.supportingText = supportingText
        self.isError = isError
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).msText(.bodySmall, color: isError ? MSColors.red : MSColors.textMuted)
            Menu {
                ForEach(options, id: \.self) { o in
                    Button(display(o)) { onSelect(o) }
                }
            } label: {
                HStack {
                    Text(display(value)).msText(.bodyMedium).lineLimit(1)
                    Spacer(minLength: 0)
                    MSIcon.expandMore.resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(MSColors.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: MSRadius.control, style: .continuous).stroke(
                        isError ? MSColors.red : MSColors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .accessibilityLabel(label)
            .accessibilityValue(display(value))
            if let supportingText {
                Text(supportingText).msText(.bodySmall, color: isError ? MSColors.red : MSColors.textMuted)
            }
        }
    }
}
