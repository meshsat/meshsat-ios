// Mirrors the MeshSatUI composable in ui/MeshSatUI.kt: the top-bar stack (StatusStrip, then
// the SOS and node-link banners), one navigation stack per tab, the Map kept alive outside
// the stacks and shown by opacity, and the custom bottom bar. The screens themselves land
// one by one under MESHSAT-1321; until a screen is ported its placeholder names the Kotlin
// file it mirrors.
import MeshSatPlatform
import SwiftUI

public struct RootView: View {
    @State private var router = Router()
    @State private var model: GatewayModel
    @State private var messages: MessagesModel
    @State private var settings: SettingsModel
    @State private var nightMode = false
    @State private var mapFocus = MapFocus()

    public init(gateway: GatewayController) {
        _model = State(initialValue: GatewayModel(gateway: gateway))
        _messages = State(initialValue: MessagesModel(gateway: gateway))
        _settings = State(initialValue: SettingsModel(gateway: gateway))
    }

    /// What the strip shows, from the gateway: the mesh and satellite states and counts.
    private var strip: StatusStripModel {
        var m = StatusStripModel()
        switch model.meshState {
        case .connected: m.mesh = .working
        case .connecting, .scanning: m.mesh = .trying
        case .disconnected: m.mesh = .off
        }
        m.meshNodes = model.nodes.count
        switch model.modemState {
        case .connected: m.satellite = model.modemSignal > 0 ? .working : .trying
        case .connecting: m.satellite = .trying
        case .disconnected: m.satellite = .off
        }
        m.satelliteBars = model.modemSignal
        return m
    }

    public var body: some View {
        // Night mode is a colour effect, and SwiftUI cannot apply one through the UIKit-backed
        // page TabView and NavigationStacks (it silently draws nothing red, seen on the phone
        // 24 Sep 2026). So the effect goes on every leaf that is SwiftUI: the strip, the banner,
        // each screen and destination, the map, the bottom bar and the overlays. Sheets from
        // UIKit (the Messages composer, the contact picker) stay as they are.
        VStack(spacing: 0) {
            StatusStrip(model: strip).nightMode(nightMode)
            SosBanner { router.navigate(.sos) }.nightMode(nightMode)
            NodeLinkBanner { router.selectTab(.setup) }.nightMode(nightMode)
            ZStack {
                // One NavigationStack per tab, all alive, the selected one visible: Android's
                // saveState/restoreState per tab without a UIKit page controller. The page-style
                // TabView used before stopped every ScrollView inside it from scrolling on the
                // phone (25 Sep 2026); this is the same pattern the map already uses.
                ForEach(Tab.allCases, id: \.self) { tab in
                    let shown = router.selectedTab == tab
                    NavigationStack(path: pathBinding(tab)) {
                        root(for: tab)
                            .nightMode(nightMode)
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationDestination(for: Route.self) { route in
                                // On the destination itself, or iOS 26 still floats its own
                                // round back button above the SubScreen's "<- Title" row.
                                destination(route).nightMode(nightMode)
                                    .toolbar(.hidden, for: .navigationBar)
                                    .navigationBarBackButtonHidden(true)
                            }
                    }
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                }
                MapScreen(visible: router.selectedTab == .map, nightMode: nightMode)
                    .opacity(router.selectedTab == .map ? 1 : 0)
                    .allowsHitTesting(router.selectedTab == .map)
            }
            MSNavigationBar(selected: router.selectedTab) { router.selectTab($0) }.nightMode(nightMode)
        }
        .overlay {
            // MainActivity's ProvisionLinkDialog and ProvisionClaimHost: over every screen.
            ZStack {
                if let link = model.provisionLink {
                    ProvisionLinkDialog(url: link) { model.provisionLinkHandled() }
                }
                ProvisionClaimHost()
                if let toast = model.toast { MSToast(toast) }
            }
            .nightMode(nightMode)
            SmsComposerHost()
        }
        .background(MSColors.bg.ignoresSafeArea())
        .environment(router)
        .environment(model)
        .environment(messages)
        .environment(settings)
        .environment(mapFocus)
        .preferredColorScheme(.dark)
    }

    private func pathBinding(_ tab: Tab) -> Binding<[Route]> {
        Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })
    }

    @ViewBuilder
    private func root(for tab: Tab) -> some View {
        switch tab {
        case .home: DashboardScreen(nightMode: $nightMode)
        case .messages: MessagesScreen()
        case .map: Color.clear
        case .people:
            PeersScreen(
                onConnect: { router.navigate(.setupSection(.node)) },
                onMessage: { router.navigate(.chat(peer: $0)) },
                onShowOnMap: { num in
                    mapFocus.show(Int64(num))
                    router.selectTab(.map)
                })
        case .setup: SetupScreen()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        if case .chat(let peer) = route {
            ConversationChatView(peer: peer)
        } else if let screen = Self.subScreen(for: route) {
            SubScreen(screen.title, onBack: { router.back() }, content: { screen.body })
        } else if let title = route.subScreenTitle {
            SubScreen(
                title,
                onBack: { router.back() },
                content: { ScreenPlaceholder(title: title, mirrors: "ui/screens (route \(route.string))") }
            )
        } else {
            ScreenPlaceholder(title: route.string, mirrors: "ui/screens (route \(route.string))")
        }
    }
}

/// A screen not ported yet. It says which Kotlin file it mirrors, so the gap is visible.
struct ScreenPlaceholder: View {
    let title: String
    let mirrors: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).msText(.headlineMedium)
            Text("Not built yet. Mirrors \(mirrors) in MeshSat Android.").msText(.bodyMedium, color: MSColors.textSecondary)
            Spacer()
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
    }
}
