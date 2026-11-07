// Mirrors the MeshSatUI composable in ui/MeshSatUI.kt: the top-bar stack (StatusStrip, then
// the SOS and node-link banners), one navigation stack per tab, the Map kept alive outside
// the stacks and shown by opacity once it was first opened (MESHSAT-1752), and the custom bottom bar. The screens themselves land
// one by one under MESHSAT-1321; until a screen is ported its placeholder names the Kotlin
// file it mirrors.
import MeshSatEngine
import MeshSatPlatform
import SwiftUI
import UIKit

public struct RootView: View {
    @State private var router = Router()
    @State private var model: GatewayModel
    @State private var messages: MessagesModel
    @State private var settings: SettingsModel
    /// Kept in settings as Android's `night_mode` (SettingsRepository.nightMode), so it survives a restart.
    @State private var nightMode: Bool
    @State private var mapFocus = MapFocus()
    /// The map is built the first time its tab is opened, then kept (MESHSAT-1752, as MeshSatUI.kt's
    /// mapOpened): its tile overlay asks tile.openstreetmap.org the moment the view exists, and nothing
    /// may go online before the user asks for it.
    @State private var mapOpened = false

    public init(gateway: GatewayController) {
        _model = State(initialValue: GatewayModel(gateway: gateway))
        _messages = State(initialValue: MessagesModel(gateway: gateway))
        _settings = State(initialValue: SettingsModel(gateway: gateway))
        _nightMode = State(initialValue: gateway.settings.get(SettingsKey.nightMode))
    }

    /// What the strip shows, from the gateway (MeshSatUI.kt's StatusStrip): the mesh with the
    /// other nodes counted, the satellite from whichever modem the node carries (red for one that
    /// does not answer, MESHSAT-1826), SMS (the Messages app is always there), the Hub and the
    /// phone's fix.
    private var strip: StatusStripModel {
        var m = StatusStripModel()
        switch model.meshState {
        case .connected: m.mesh = .working
        case .connecting, .scanning: m.mesh = .trying
        case .disconnected: m.mesh = .off
        }
        m.meshNodes = model.nodes.filter { $0.nodeNum != model.myNodeNum }.count
        if model.imtState == .ready {
            m.satellite = .working
            m.satelliteBars = model.imtReading?.bars ?? 0
        } else if model.imtState != .disconnected {
            m.satellite = .trying
        } else {
            switch model.modemState {
            case .connected: m.satellite = model.modemSignal > 0 ? .working : .trying
            case .connecting: m.satellite = model.modemSilent ? .failed : .trying
            case .disconnected: m.satellite = .off
            }
            m.satelliteBars = model.modemSignal
        }
        m.sms = .working
        switch model.interfaces["hub_0"]?.state {
        case .online: m.hub = .working
        case .connecting: m.hub = .trying
        case .error: m.hub = .failed
        default: m.hub = model.hubSetUp ? .trying : .off
        }
        m.gps = model.phoneFix == nil ? .off : .working
        return m
    }

    public var body: some View {
        // The welcome page before iOS's own questions, once per permission (MESHSAT-1834, as
        // MainActivity.kt shows WelcomeScreen before permissionLauncher.launch).
        Group {
            if model.welcomePending.isEmpty {
                mainBody
            } else {
                WelcomeScreen(pending: model.welcomePending) { model.welcomeContinue() }
            }
        }
        .environment(model)
    }

    private var mainBody: some View {
        // Night mode is one colour filter on the root, as Android filters its window
        // (MESHSAT-1827): Core Animation filters reach the UIKit-backed scroll views and
        // navigation stacks under it. (A Metal colour-effect shader did not: the strip and the
        // bar came out red and every screen black, 24 Sep to 7 Nov 2026.) Sheets presented by
        // UIKit (the Messages and Mail composers, the share sheet, the camera) are their own
        // windows and stay as they are, as on Android.
        VStack(spacing: 0) {
            StatusStrip(model: strip)
            SosBanner { router.navigate(.sos) }
            NodeLinkBanner { router.selectTab(.setup) }
            ZStack {
                // One NavigationStack per tab, all alive, the selected one visible: Android's
                // saveState/restoreState per tab without a UIKit page controller. The page-style
                // TabView used before stopped every ScrollView inside it from scrolling on the
                // phone (25 Sep 2026); this is the same pattern the map already uses.
                ForEach(Tab.allCases, id: \.self) { tab in
                    let shown = router.selectedTab == tab
                    NavigationStack(path: pathBinding(tab)) {
                        root(for: tab)
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationDestination(for: Route.self) { route in
                                // On the destination itself, or iOS 26 still floats its own
                                // round back button above the SubScreen's "<- Title" row.
                                destination(route)
                                    .toolbar(.hidden, for: .navigationBar)
                                    .navigationBarBackButtonHidden(true)
                            }
                    }
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                }
                if mapOpened || router.selectedTab == .map {
                    MapScreen(visible: router.selectedTab == .map)
                        .opacity(router.selectedTab == .map ? 1 : 0)
                        .allowsHitTesting(router.selectedTab == .map)
                        .onAppear { mapOpened = true }
                }
            }
            MSNavigationBar(selected: router.selectedTab) { tab in
                // Compose drops the keyboard when the destination changes; SwiftUI keeps it.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                router.selectTab(tab)
            }
        }
        .nightMode(nightMode)
        .onChange(of: nightMode) { _, on in settings.set(SettingsKey.nightMode, on) }
        .overlay {
            // MainActivity's ProvisionLinkDialog and ProvisionClaimHost: over every screen.
            ZStack {
                if let link = model.provisionLink {
                    ProvisionLinkDialog(url: link) { model.provisionLinkHandled() }
                }
                ProvisionClaimHost()
                // A relayed public warning over every screen but the list itself (MESHSAT-1734).
                if router.selectedTab != .setup || router.paths[.setup]?.last != .warnings {
                    WarningOverlay { router.navigate(.warnings) }
                }
                if let toast = model.toast { MSToast(toast) }
            }
            .nightMode(nightMode)
            SmsComposerHost()
        }
        .background(MSColors.bg.ignoresSafeArea())
        .task {
            // A notification's tap (AppDelegate), also when it launched the app (MainActivity's EXTRA_ROUTE).
            for await route in NotificationRoutes.pending.subscribe() {
                guard let route else { continue }
                NotificationRoutes.pending.send(nil)
                router.openFromNotification(route)
            }
        }
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
