// Mirrors MainActivity.kt and MeshSatApp.kt of MeshSat Android: the app entry, the welcome
// gate (MESHSAT-1321), the meshsat://provision deep link and the notification routes. The
// gateway (MeshSatPlatform.GatewayController) is created by the app delegate so it exists when
// iOS relaunches the app headless for Bluetooth.
import MeshSatUI
import SwiftUI

@main
struct MeshSatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(gateway: appDelegate.gateway)
                .onOpenURL { url in
                    appDelegate.handle(url: url)
                }
        }
    }
}
