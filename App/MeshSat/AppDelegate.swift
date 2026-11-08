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
    /// The background windows and the lifecycle hand-offs (MESHSAT-1328).
    let background: BackgroundCoordinator

    override init() {
        // First, so every line the gateway writes can be read off the phone (MESHSAT-1324).
        AppLog.bootstrap()
        // A crash lands in a file now and in the telemetry table on the next launch (MESHSAT-494).
        CrashCapture.install(
            versionName: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            versionCode: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            deviceModel: UIDevice.current.model, osVersion: "iOS " + UIDevice.current.systemVersion)
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
        background = BackgroundCoordinator(gateway: gateway)
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(GatewayController.notificationCategories())
        // The notification permission is asked from the welcome page, which says what it is for
        // (MESHSAT-1834, as Android's welcome asks for POST_NOTIFICATIONS); a phone that has
        // answered already is asked nothing (MESHSAT-1823). iOS never asks twice.
        gateway.requestPermissionsIfAlreadyAsked()
        // Before launching finishes, as BGTaskScheduler requires.
        background.registerTasks()
        // A SwiftUI app runs in scenes, and UIKit never calls applicationDidEnterBackground on a scene-based
        // app's delegate: the background hand-off had never run (found on the iPhone, 8 Nov 2026, MESHSAT-1506).
        // The app-wide notifications are posted for scenes too, once the last one leaves or comes back.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.background.appDidEnterBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.background.appWillEnterForeground() }
        }
        gateway.start()
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
        if response.actionIdentifier == GatewayController.sosCancelAction {
            // "Cancel SOS" / "Stop test" on the SOS notification (MESHSAT-1830).
            gateway.cancelSos()
        }
        let route = response.notification.request.content.userInfo["route"] as? String
        if let route { NotificationRoutes.pending.send(route) }
        completionHandler()
    }

    /// While the app is open the notification still shows and sounds, as Android posts it whatever
    /// is on screen; a warning also fills the screen (WarningOverlay).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
