// The UIKit delegate: owns the gateway's lifetime, registers the background tasks and routes
// notification taps (net.meshsat.android.ROUTE in Android; here the userInfo key "route").
import MeshSatPlatform
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // GatewayController.shared.start() lands with MESHSAT-1322; the identifiers it registers:
        _ = MeshSatPlatform.hubSyncTaskIdentifier
        _ = MeshSatPlatform.refreshTaskIdentifier
        return true
    }

    func handle(url: URL) {
        guard url.scheme == MeshSatPlatform.provisionURLScheme, url.host == MeshSatPlatform.provisionURLHost else { return }
        // ProvisionLinkDialog (MESHSAT-1324) takes it from here.
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        _ = response.notification.request.content.userInfo["route"] as? String
        // Router.openFromNotification once the router is reachable from here (MESHSAT-1321).
    }
}
