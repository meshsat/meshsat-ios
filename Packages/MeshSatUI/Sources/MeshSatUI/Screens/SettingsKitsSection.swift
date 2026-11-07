// Mirrors ui/screens/KitSettings.kt (MESHSAT-1738, iOS MESHSAT-1820): Setup > Field kits on your
// network, each kit this phone reaches directly, its address on the LAN and the API token the kit may
// ask for. The token is kept in the Keychain and sent as the Bearer on every direct request; a kit
// reached through the Hub relay needs none. Check asks the kit for /api/status; a 401 becomes the one
// line that asks for the token.
import MeshSatEngine
import MeshSatPlatform
import SwiftUI

public struct SettingsKitsSection: View {
    @Environment(GatewayModel.self) private var model
    @State private var kits: [KitConnection] = []

    public init() {}

    public var body: some View {
        ScrollView {
            SectionCard("Field kits on your network") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "A kit on the same WiFi answers at its address on port 6050. A kit with an API token set "
                            + "answers only with it; the token is kept on this phone, encrypted, and sent with every direct "
                            + "request to that kit. Through the Hub (Setup > Hub > Reach a kit through the Hub) no token is needed."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                    if kits.isEmpty { Text("No kit added yet.").msText(.bodySmall, color: MSColors.textMuted) }
                    ForEach(kits, id: \.id) { kit in
                        KitCard(kit: kit, reload: reload)
                    }
                    MSOutlinedButton("Add a kit") {
                        model.gateway.putKit(KitConnection.create())
                        reload()
                    }
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .onAppear(perform: reload)
    }

    private func reload() { kits = model.gateway.kits }
}

private struct KitCard: View {
    @Environment(GatewayModel.self) private var model
    let kit: KitConnection
    let reload: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var result: KitProbe.Result?
    @State private var checking = false

    private var resultColor: Color {
        guard let result else { return MSColors.textMuted }
        if KitProbe.asksForToken(result) { return MSColors.amber }
        if case .reachable = result { return MSColors.green }
        return MSColors.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MSOutlinedTextField(text: $name, placeholder: "tesseract", label: "Name")
            MSOutlinedTextField(text: $url, placeholder: "192.168.1.20 or kit-a.local:6050", label: "Address on the LAN", keyboard: .URL)
            MSOutlinedTextField(text: $token, label: "API token (only if the kit has one)", secure: !showToken) {
                EmptyView()
            } trailing: {
                MSIconButton(
                    showToken ? MSIcon.lock : MSIcon.lockOpen, label: showToken ? "Hide the token" : "Show the token",
                    tint: MSColors.textMuted, size: 40, glyph: 20
                ) { showToken.toggle() }
            }
            if let result { Text(KitProbe.line(result)).msText(.bodySmall, color: resultColor) }
            HStack(spacing: 8) {
                MSFilledButton("Save", fullWidth: false) {
                    model.gateway.setKitApiToken(kit.id, token)
                    var k = kit
                    k.name = name.trimmingCharacters(in: .whitespaces)
                    k.url = url.trimmingCharacters(in: .whitespaces)
                    model.gateway.putKit(k)
                    reload()
                }
                MSOutlinedButton(checking ? "Checking" : "Check", enabled: !checking && !url.trimmingCharacters(in: .whitespaces).isEmpty) {
                    checking = true
                    let u = url
                    let t = token
                    Task {
                        result = await model.gateway.checkKit(url: u, token: t)
                        checking = false
                    }
                }
                MSTextButton("Remove", color: MSColors.red) {
                    model.gateway.removeKit(kit.id)
                    reload()
                }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MSColors.border, lineWidth: 1))
        .onAppear {
            name = kit.name
            url = kit.url
            token = model.gateway.kitApiToken(kit.id)
        }
    }
}
