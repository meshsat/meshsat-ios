// Mirrors the MeshSatUI composable in ui/MeshSatUI.kt: the top-bar stack (StatusStrip, then
// the SOS and node-link banners), one navigation stack per tab, the Map kept alive outside
// the stacks and shown by opacity, and the custom bottom bar. The screens themselves land
// one by one under MESHSAT-1321; until a screen is ported its placeholder names the Kotlin
// file it mirrors.
import SwiftUI

public struct RootView: View {
    @State private var router = Router()
    @State private var strip = StatusStripModel()
    @State private var nightMode = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            StatusStrip(model: strip)
            ZStack {
                TabView(selection: $router.selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        NavigationStack(path: pathBinding(tab)) {
                            root(for: tab)
                                .navigationDestination(for: Route.self) { route in destination(route) }
                        }
                        .toolbar(.hidden, for: .navigationBar)
                        .tag(tab)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .toolbar(.hidden, for: .tabBar)
                .scrollDisabled(true)
                MapPlaceholder()
                    .opacity(router.selectedTab == .map ? 1 : 0)
                    .allowsHitTesting(router.selectedTab == .map)
            }
            MSNavigationBar(selected: router.selectedTab) { router.selectTab($0) }
        }
        .background(MSColors.bg.ignoresSafeArea())
        .environment(router)
        .nightMode(nightMode)
        .preferredColorScheme(.dark)
    }

    private func pathBinding(_ tab: Tab) -> Binding<[Route]> {
        Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })
    }

    @ViewBuilder
    private func root(for tab: Tab) -> some View {
        switch tab {
        case .home: DashboardScreen(nightMode: $nightMode)
        case .messages: ScreenPlaceholder(title: "Messages", mirrors: "ui/screens/MessagesScreen.kt")
        case .map: Color.clear
        case .people: ScreenPlaceholder(title: "People", mirrors: "ui/screens/PeersScreen.kt")
        case .setup: SetupScreen()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        if let title = route.subScreenTitle {
            SubScreen(title, onBack: { router.back() }) {
                ScreenPlaceholder(title: title, mirrors: "ui/screens (route \(route.string))")
            }
        } else {
            ScreenPlaceholder(title: route.string, mirrors: "ui/screens (route \(route.string))")
        }
    }
}

struct MapPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Map").msText(.headlineMedium).padding(MSSpace.screen)
            RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous)
                .fill(MSColors.surface)
                .overlay(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous).stroke(MSColors.border, lineWidth: 1))
                .overlay(Text("MapKit tile overlay lands with MESHSAT-1321").msText(.bodySmall, color: MSColors.textMuted))
                .padding(.horizontal, MSSpace.screen)
                .padding(.bottom, MSSpace.screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
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
