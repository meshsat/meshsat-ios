// Mirrors ui/screens/SetupScreen.kt: the "Setup" title, then NavRows in three groups, "Get
// connected" (node, satellite, Hub, SMS, each with a coloured icon and a state dot), "Using
// MeshSat" (Safety, Messaging, Maps, Ham radio, TAK and Reticulum, Mesh radio settings) and
// "For experts" (Advanced, About). The state dots read the gateway once MESHSAT-1322 lands.
import SwiftUI

public struct SetupScreen: View {
    @Environment(Router.self) private var router
    @Environment(GatewayModel.self) private var model

    public init() {}

    private var nodeDot: Color {
        switch model.meshState {
        case .connected: MSColors.green
        case .connecting, .scanning: MSColors.amber
        case .disconnected: MSColors.textMuted
        }
    }

    private var hubDetail: String {
        guard model.hubSetUp else { return "Not set up" }
        switch model.interfaces["hub_0"]?.state {
        case .online: return "Connected"
        case .connecting: return "Connecting"
        case .error: return "Cannot reach the Hub"
        default: return "Not connected"
        }
    }

    private var hubDot: Color {
        switch model.interfaces["hub_0"]?.state {
        case .online: MSColors.green
        case .connecting: MSColors.amber
        case .error: MSColors.red
        default: MSColors.textMuted
        }
    }

    private var modemDot: Color {
        switch model.modemState {
        case .connected: MSColors.green
        case .connecting: MSColors.amber
        case .disconnected: MSColors.textMuted
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Setup").msText(.headlineMedium).padding(MSSpace.screen)

                GroupTitle("Get connected")
                NavRow(
                    icon: MSIcon.bluetooth, tint: MSColors.mesh, title: "Your MeshSat node",
                    detail: model.meshStatusText, dot: nodeDot
                ) { router.navigate(.setupSection(.node)) }
                NavRow(
                    icon: MSIcon.transportSatellite, tint: MSColors.iridium, title: "Satellite",
                    detail: model.modemStatusText, dot: modemDot
                ) { router.navigate(.setupSection(.satellite)) }
                NavRow(
                    icon: MSIcon.cloud, tint: MSColors.hub, title: "Hub",
                    detail: hubDetail, dot: hubDot
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
                NavRow(icon: MSIcon.info, title: "Diagnostics", detail: "Link health, crash reports, the background service") {
                    router.navigate(.setupSection(.diagnostics))
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
