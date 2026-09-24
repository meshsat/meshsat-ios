// The sub-screens behind the routes (MeshSatUI.kt's NavHost composables), as a table: the
// title the SubScreen header shows and the screen under it. Two lookups, so neither grows past
// what a reader can take in.
import SwiftUI

struct RoutedScreen {
    let title: String
    let body: AnyView
    init(_ title: String, _ body: some View) {
        self.title = title
        self.body = AnyView(body)
    }
}

extension RootView {
    static func subScreen(for route: Route) -> RoutedScreen? {
        expertScreen(for: route) ?? settingsScreen(for: route)
    }

    private static func expertScreen(for route: Route) -> RoutedScreen? {
        switch route {
        case .sos: RoutedScreen("SOS", SosScreen())
        case .rules: RoutedScreen("Routing rules", RulesScreen())
        case .interfaces: RoutedScreen("Links", InterfacesScreen())
        case .topology: RoutedScreen("Mesh topology", TopologyScreen())
        case .audit: RoutedScreen("Audit log", AuditScreen())
        case .decrypt: RoutedScreen("Encrypt or decrypt text", DecryptScreen())
        case .credentials: RoutedScreen("Certificates and keys", CredentialsScreen())
        case .deliveries: RoutedScreen("Message queue", DeliveryScreen())
        case .setupAdvanced: RoutedScreen("Advanced", AdvancedScreen())
        case .about: RoutedScreen("About", AboutScreen())
        case .geofence: RoutedScreen("Zones", GeofenceScreen())
        case .passes: RoutedScreen(Route.passes.subScreenTitle ?? "Satellite passes", PassesScreen())
        default: nil
        }
    }

    private static func settingsScreen(for route: Route) -> RoutedScreen? {
        switch route {
        case .setupSection(.safety): RoutedScreen(SetupSection.safety.title, SettingsSafetySection())
        case .setupSection(.satellite): RoutedScreen(SetupSection.satellite.title, SettingsSatelliteSection())
        case .setupSection(.hub): RoutedScreen(SetupSection.hub.title, SettingsHubSection())
        case .setupSection(.messaging): RoutedScreen(SetupSection.messaging.title, SettingsMessagingSection())
        case .setupSection(.sms): RoutedScreen(SetupSection.sms.title, SettingsSmsSection())
        case .setupSection(.diagnostics): RoutedScreen(SetupSection.diagnostics.title, SettingsDiagnosticsSection())
        case .setupSection(.node): RoutedScreen(SetupSection.node.title, SettingsNodeSection())
        case .setupSection(.maps): RoutedScreen(SetupSection.maps.title, SettingsMapsSection())
        default: nil
        }
    }
}
