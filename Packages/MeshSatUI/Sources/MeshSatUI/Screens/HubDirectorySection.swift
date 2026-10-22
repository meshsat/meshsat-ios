// Mirrors ui/screens/HubDirectorySection.kt (MESHSAT-1642): the organisation's contacts and groups
// from the Hub (HeMB-NG C9.5), read-only, signed by the Hub's directory key that this phone pinned
// when it was provisioned. Hidden on a phone with no Hub key. Collapsed to one line until tapped,
// so the nodes stay on screen. MESHSAT-1643.
import MeshSatHub
import SwiftUI

struct HubDirectorySection: View {
    @Environment(GatewayModel.self) private var model
    @State private var dir = DirectoryState()
    @State private var open = false

    var body: some View {
        Group {
            if !dir.pinnedKey.isEmpty { card }
        }
        .task {
            for await state in model.gateway.hubDirectory.changes.subscribe() { dir = state }
        }
    }

    private var summary: String {
        if dir.appliedAt == 0 && dir.refusedReason.isEmpty { return "Not read from the Hub yet." }
        let counts = "\(Words.count(dir.contacts.count, "contact")), \(Words.count(dir.groups.count, "group")) from the Hub"
        return open ? counts : counts + ". Tap to show."
    }

    private var footer: String {
        var s = "Version \(dir.version) · key \(dir.keyId.prefix(12)) (\(dir.pinSource))"
        if dir.checkedAt > 0 {
            let when = Date(timeIntervalSince1970: Double(dir.checkedAt) / 1000)
            s += " · checked " + when.formatted(date: .omitted, time: .shortened)
        }
        return s
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your organisation").msText(.titleMedium)
            Text(summary).msText(.bodySmall, color: MSColors.textMuted).padding(.top, 4)
            if !dir.refusedReason.isEmpty {
                Text("Last update refused: \(dir.refusedReason). \(dir.refusedDetail)")
                    .msText(.bodySmall, color: MSColors.red).padding(.top, 4)
            }
            if open {
                ForEach(dir.groups, id: \.id) { g in
                    let names = g.memberIds.compactMap { id in dir.contacts.first { $0.id == id }?.displayName }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(g.name) · \(g.kind.lowercased())").msText(.bodyLarge)
                        Text(names.isEmpty ? "No members" : names.joined(separator: ", "))
                            .msText(.bodySmall, color: MSColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                }
                ForEach(dir.contacts, id: \.id) { c in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.displayName).msText(.bodyLarge)
                        let roles = [c.role, c.team, c.org].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !roles.isEmpty { Text(roles).msText(.bodySmall, color: MSColors.textMuted) }
                        ForEach(Array(c.addresses.enumerated()), id: \.offset) { _, a in
                            Text("\(a.kind.lowercased()) \(a.value)" + (a.label.isEmpty ? "" : " (\(a.label))"))
                                .msText(.bodySmall, mono: true, color: MSColors.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                }
                Text(footer).msText(.bodySmall, mono: true, color: MSColors.textMuted).padding(.top, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
    }
}
