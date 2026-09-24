// Mirrors the navigation behaviour of ui/MeshSatUI.kt: one stack per tab (Android's
// popUpTo(start) { saveState } + restoreState), navigate() switches to the route's tab, and
// notification routes are limited to sos, messages and home.
import Observation
import SwiftUI

@MainActor
@Observable
public final class Router {
    public var selectedTab: Tab = .home
    public var paths: [Tab: [Route]] = [:]

    public init() {}

    public var path: [Route] {
        get { paths[selectedTab] ?? [] }
        set { paths[selectedTab] = newValue }
    }

    public var top: Route? { path.last }

    public func navigate(_ route: Route) {
        let tab = route.tab
        if tab != selectedTab { selectedTab = tab }
        var p = paths[tab] ?? []
        if p.last != route { p.append(route) }
        paths[tab] = p
    }

    public func selectTab(_ tab: Tab) {
        selectedTab = tab
    }

    public func back() {
        var p = paths[selectedTab] ?? []
        if !p.isEmpty { p.removeLast() }
        paths[selectedTab] = p
    }

    /// The intent extra net.meshsat.android.ROUTE accepted only these three.
    public func openFromNotification(_ string: String) {
        guard let route = Route(string: string), [.sos, .messages, .home].contains(route) else { return }
        if route == .home || route == .messages {
            selectedTab = route.tab
            paths[route.tab] = []
        } else {
            navigate(route)
        }
    }
}
