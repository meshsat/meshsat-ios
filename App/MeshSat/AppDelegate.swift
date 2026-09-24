// The UIKit delegate: owns the gateway's lifetime, registers the background tasks and routes
// notification taps (net.meshsat.android.ROUTE in Android; here the userInfo key "route").
import MeshSatPlatform
import MeshSatStore
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The gateway, made with the delegate so it exists before iOS hands back a restored
    /// Bluetooth central; started in didFinishLaunching, as GatewayService.onCreate.
    let gateway: GatewayController

    override init() {
        // First, so every line the gateway writes can be read off the phone (MESHSAT-1324).
        AppLog.bootstrap()
        let settings = SettingsRepository(secure: SecureKeyStore())
        let db: AppDatabase
        do {
            db = try AppDatabase.open(at: AppDatabase.defaultURL())
        } catch {
            // No usable file: an in-memory store keeps the app alive for this launch, and
            // nothing persists. SQLite itself failing as well leaves nothing to run on.
            do {
                db = try AppDatabase.inMemory()
            } catch {
                fatalError("MeshSat has no database: \(error)")
            }
        }
        gateway = GatewayController(settings: settings, db: db)
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        gateway.start()
        // The background task identifiers the BackgroundCoordinator registers (MESHSAT-1319):
        _ = MeshSatPlatform.hubSyncTaskIdentifier
        _ = MeshSatPlatform.refreshTaskIdentifier
        return true
    }

    func handle(url: URL) {
        guard url.scheme == MeshSatPlatform.provisionURLScheme, url.host == MeshSatPlatform.provisionURLHost else { return }
        // ProvisionLinkDialog confirms it, then the gateway's claim takes over (MESHSAT-1235, 1306).
        gateway.openProvisionLink(url.absoluteString)
    }

    // nonisolated with the completion-handler form: the delegate's parameters are not Sendable,
    // so Swift 6 refuses to hand them to a main-actor method. The route string is Sendable and
    // hops to the main actor by itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = response.notification.request.content.userInfo["route"] as? String
        Task { @MainActor in
            _ = route  // Router.openFromNotification once the router is reachable from here (MESHSAT-1321).
        }
        completionHandler()
    }
}
