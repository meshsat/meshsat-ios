// Mirrors WelcomeGate.kt and the welcome half of MainActivity.kt (MESHSAT-1834): the permissions
// the welcome page explains before iOS asks for them, each once. iOS has two to explain here,
// location and notifications; Bluetooth is asked when the node is paired (Setup > Your MeshSat
// node's Continue, App Review's guideline 5.1.1). A permission iOS has already decided, or one the
// welcome asked for before and the person refused, is not asked again: Setup's rows and the
// phone's Settings remain the way to allow it later.
import Foundation
import MeshSatEngine
import UserNotifications

extension GatewayController {
    public static let welcomeLocation = "location"
    public static let welcomeNotifications = "notifications"

    /// What the welcome asked for on this phone (WelcomeGate.KEY_ASKED).
    private var welcomeAsked: Set<String> {
        Set(settings.get(SettingsKey.welcomeAsked).split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// WelcomeGate.toAsk: the permissions still undecided that the welcome never asked for, in the
    /// order the page lists them. Empty = no welcome.
    public func welcomePending() async -> [String] {
        let asked = welcomeAsked
        var pending: [String] = []
        if location.isUndetermined, !asked.contains(Self.welcomeLocation) { pending.append(Self.welcomeLocation) }
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if notifications == .notDetermined, !asked.contains(Self.welcomeNotifications) { pending.append(Self.welcomeNotifications) }
        return pending
    }

    /// Before the gateway starts: the location question waits for the welcome when the welcome
    /// still has to explain it (`LocationProvider.askOnStart`).
    func holdLocationQuestionForWelcome() {
        location.askOnStart = !(location.isUndetermined && !welcomeAsked.contains(Self.welcomeLocation))
    }

    /// The app delegate at launch: a phone past its welcome gets the notification question as
    /// before (iOS never asks twice, so a decided one is a no-op); a phone that still owes a
    /// welcome gets it from the welcome's Continue.
    public func requestPermissionsIfAlreadyAsked() {
        Task { [self] in
            guard await welcomePending().isEmpty else { return }
            requestNotificationPermission()
        }
    }

    /// The welcome's Continue (MainActivity's permissionLauncher.launch): remember what was
    /// explained, then let iOS ask.
    public func welcomeContinue(_ pending: [String]) {
        let asked = welcomeAsked.union(pending)
        settings.set(SettingsKey.welcomeAsked, asked.sorted().joined(separator: ","))
        if pending.contains(Self.welcomeLocation) {
            location.askOnStart = true
            location.requestAuthorization()
        }
        if pending.contains(Self.welcomeNotifications) { requestNotificationPermission() }
    }

    /// Android's POST_NOTIFICATIONS: without it the SOS, warning and message notifications never show (MESHSAT-1823).
    public func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            self?.notificationsAnswered(granted)
        }
    }
}
