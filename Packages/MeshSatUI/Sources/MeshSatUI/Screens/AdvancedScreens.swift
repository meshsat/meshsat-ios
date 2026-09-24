// Mirrors AdvancedScreen in ui/screens/SetupScreen.kt (the tools an operator or a developer
// needs, kept out of everyone else's way) and ui/screens/AboutScreen.kt.
import SwiftUI

public struct AdvancedScreen: View {
    @Environment(Router.self) private var router

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NavRow(icon: MSIcon.altRoute, title: "Routing rules", detail: "Which messages go where, automatically") {
                    router.navigate(.rules)
                }
                NavRow(icon: MSIcon.link, title: "Links", detail: "Every way out, its state and its health") {
                    router.navigate(.interfaces)
                }
                NavRow(icon: MSIcon.outbox, title: "Message queue", detail: "Everything waiting, sent or given up") {
                    router.navigate(.deliveries)
                }
                NavRow(icon: MSIcon.hub, title: "Mesh topology", detail: "How the nodes you hear are linked") { router.navigate(.topology) }
                NavRow(icon: MSIcon.history, title: "Audit log", detail: "A signed record of what the gateway did") {
                    router.navigate(.audit)
                }
                NavRow(icon: MSIcon.key, title: "Certificates and keys", detail: "The Hub certificate and imported keys") {
                    router.navigate(.credentials)
                }
                NavRow(icon: MSIcon.lockOpen, title: "Encrypt or decrypt text", detail: "By hand, with a conversation key") {
                    router.navigate(.decrypt)
                }
                NavRow(icon: MSIcon.monitorHeart, title: "Diagnostics", detail: "Link health, batch queue, crash reports, service") {
                    router.navigate(.setupSection(.diagnostics))
                }
                MSDivider()
            }
        }
        .background(MSColors.bg)
    }
}

public struct AboutScreen: View {
    public init() {}

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    private var bundleId: String { Bundle.main.bundleIdentifier ?? "net.meshsat.ios" }
    private var buildType: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("MeshSat iOS").msText(.headlineMedium.weight(.bold))
                Text("v\(AppVersion.marketing) (\(build))").msText(.bodyLarge, color: MSColors.teal).padding(.top, 4)
                Text("Mobile gateway for Meshtastic mesh + Iridium satellite + SMS").msText(.bodyMedium, color: MSColors.textMuted)
                    .multilineTextAlignment(.center).padding(.top, 8).padding(.bottom, 16)
                VStack(spacing: 12) {
                    InfoSection("Transports") {
                        InfoItem("Meshtastic", "BLE (Bluetooth Low Energy)")
                        InfoItem("Iridium 9603N", "The MeshSat node's BLE pipe")
                        InfoItem("RockBLOCK 9704", "Not on iPhone: needs Bluetooth Classic")
                        InfoItem("Cellular SMS", "Through the Messages app")
                    }
                    InfoSection("Encryption") {
                        InfoItem("Algorithm", "AES-256-GCM")
                        InfoItem("Wire format", "[12B nonce][ciphertext+tag]")
                        InfoItem("SMS format", "Base64-encoded wire format")
                        InfoItem("Compatible with", "MeshSat Pi transform pipeline")
                    }
                    InfoSection("Build") {
                        InfoItem("Bundle", bundleId)
                        InfoItem("Build type", buildType)
                        InfoItem("Minimum", "iOS 17")
                    }
                    InfoSection("License") {
                        Text("GNU General Public License v3.0").msText(.bodyMedium)
                        Text("Part of the MeshSat project: meshsat.net").msText(.bodySmall, color: MSColors.textMuted).padding(.top, 4)
                    }
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).msText(.titleMedium)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }
}

private struct InfoItem: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(label).msText(.bodySmall, color: MSColors.textMuted)
            Spacer(minLength: 12)
            Text(value).msText(.bodySmall).multilineTextAlignment(.trailing)
        }
    }
}
