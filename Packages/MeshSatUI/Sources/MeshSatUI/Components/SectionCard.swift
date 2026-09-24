// Mirrors the settings components of ui/components (SectionCard, ConnectionStatusRow, InfoRow,
// DeviceRow) as ui/screens/SettingsScreen.kt uses them: a card with a titleMedium heading and
// 12 dp between rows; a status row with an 8 dp dot; a label/value row in bodySmall; a device
// row on the surface colour that connects on tap.
import SwiftUI

public struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MSSpace.list) {
            Text(title).msText(.titleMedium)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MSSpace.card)
        .msCard()
    }
}

public struct ConnectionStatusRow: View {
    let label: String
    let connected: Bool
    let statusText: String
    let color: Color

    public init(label: String, connected: Bool, statusText: String, color: Color) {
        self.label = label
        self.connected = connected
        self.statusText = statusText
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(label).msText(.bodyMedium, color: MSColors.textSecondary)
            Spacer(minLength: 8)
            Circle().fill(connected ? color : MSColors.textMuted).frame(width: 8, height: 8)
            Text(statusText).msText(.bodyMedium, color: connected ? color : MSColors.textSecondary)
        }
    }
}

public struct InfoRow: View {
    let label: String
    let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).msText(.bodySmall, color: MSColors.textMuted)
            Spacer(minLength: 8)
            Text(value).msText(.bodySmall).multilineTextAlignment(.trailing)
        }
    }
}

public struct DeviceRow: View {
    let name: String
    let address: String
    let action: () -> Void

    public init(name: String, address: String, action: @escaping () -> Void) {
        self.name = name
        self.address = address
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).msText(.bodyMedium)
                Text(address).msText(.bodySmall, color: MSColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(MSColors.surfaceLight, in: RoundedRectangle(cornerRadius: MSRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
