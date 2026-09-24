// Mirrors ui/screens/SetupScreen.kt: the "Setup" title, then NavRows in three groups, "Get
// connected" (node, satellite, Hub, SMS, each with a coloured icon and a state dot), "Using
// MeshSat" (Safety, Messaging, Maps, Ham radio, TAK and Reticulum, Mesh radio settings) and
// "For experts" (Advanced, About). The state dots read the gateway once MESHSAT-1322 lands.
import SwiftUI

public struct SetupScreen: View {
    @Environment(Router.self) private var router

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Setup").msText(.headlineMedium).padding(MSSpace.screen)

                GroupTitle("Get connected")
                NavRow(
                    icon: MSIcon.bluetooth, tint: MSColors.mesh, title: "Your MeshSat node",
                    detail: "Not connected", dot: MSColors.textMuted
                ) { router.navigate(.setupSection(.node)) }
                NavRow(
                    icon: MSIcon.transportSatellite, tint: MSColors.iridium, title: "Satellite",
                    detail: "No modem", dot: MSColors.textMuted
                ) { router.navigate(.setupSection(.satellite)) }
                NavRow(
                    icon: MSIcon.cloud, tint: MSColors.hub, title: "Hub",
                    detail: "Not set up", dot: MSColors.textMuted
                ) { router.navigate(.setupSection(.hub)) }
                NavRow(
                    icon: MSIcon.sms, tint: MSColors.sms, title: "SMS",
                    detail: "Through the Messages app", dot: MSColors.textMuted
                ) { router.navigate(.setupSection(.sms)) }

                GroupTitle("Using MeshSat")
                NavRow(icon: MSIcon.healthAndSafety, title: "Safety", detail: "SOS, check-in timer, zones") {
                    router.navigate(.setupSection(.safety))
                }
                NavRow(icon: MSIcon.lock, title: "Messaging", detail: "Encryption, compression, quick messages") {
                    router.navigate(.setupSection(.messaging))
                }
                NavRow(icon: MSIcon.map, title: "Maps", detail: "Offline maps for when there is no internet") {
                    router.navigate(.setupSection(.maps))
                }
                NavRow(icon: MSIcon.radio, title: "Ham radio, TAK and Reticulum", detail: "Other networks MeshSat can bridge") {
                    router.navigate(.setupSection(.integrations))
                }
                NavRow(icon: MSIcon.tune, title: "Mesh radio settings", detail: "Region, channels, transmit power") {
                    router.navigate(.radioConfig)
                }

                GroupTitle("For experts")
                NavRow(icon: MSIcon.build, title: "Advanced", detail: "Routing rules, links, queue, logs") {
                    router.navigate(.setupAdvanced)
                }
                NavRow(icon: MSIcon.info, title: "About", detail: "MeshSat iOS \(AppVersion.marketing)") {
                    router.navigate(.about)
                }
                MSDivider().padding(.top, 8)
            }
        }
        .background(MSColors.bg)
    }
}

public enum AppVersion {
    public static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
