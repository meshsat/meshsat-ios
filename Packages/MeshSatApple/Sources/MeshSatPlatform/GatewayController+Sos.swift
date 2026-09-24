// Mirrors the SOS parts of GatewayService (MESHSAT-1249, MESHSAT-1328): the SosController's
// environment, the dispatcher hooks that let it veto and follow deliveries, the local
// notification with the routes' state, and the SMS composer lane's manual channel (iOS has no
// SMS API: sms_0 deliveries wait for the person to tap Send in Messages).
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatStore
import MeshSatWire
import UserNotifications

#if canImport(MessageUI)
import MessageUI
#endif

/// The settings the run lives in, on the SettingsRepository.
final class SosSettingsAdapter: SosSettings, @unchecked Sendable {
    private let settings: SettingsRepository
    init(_ settings: SettingsRepository) { self.settings = settings }
    var sosRunJson: String {
        get { settings.get(SettingsKey.sosRun) }
        set { settings.set(SettingsKey.sosRun, newValue) }
    }
    var sosName: String { settings.get(SettingsKey.sosName) }
    var hubCallsign: String { settings.get(SettingsKey.hubCallsign) }
    var sosContacts: [EmergencyContact] { settings.sosContacts }
}

/// The delivery DAO's by-prefix queries as the controller wants them.
public struct SosDeliveryQueriesAdapter: SosDeliveryQueries {
    public let dao: MessageDeliveryDao
    public init(dao: MessageDeliveryDao) { self.dao = dao }
    public func getByRefPrefix(_ prefix: String) async throws -> [MessageDelivery] { try await dao.getByRefPrefix(prefix) }
    public func cancelWaitingByRefPrefix(_ prefix: String) async throws -> Int { try await dao.cancelWaitingByRefPrefix(prefix) }
    public func observeByRefPrefix(_ prefix: String) -> AsyncStream<[MessageDelivery]> {
        let observation = dao.observeByRefPrefix(prefix)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await rows in observation { continuation.yield(rows) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The gateway as the controller's environment.
final class SosEnvAdapter: SosEnv, @unchecked Sendable {
    weak var gateway: GatewayController?
    var dispatcher: Dispatcher? { gateway?.dispatcher }
    var hubReporter: HubReporter? { gateway?.hubReporter }

    func modemImei() async -> String {
        guard let gateway else { return "" }
        let now = await gateway.driver.modemInfo.imei
        if !now.isEmpty { return now }
        return gateway.settings.get(SettingsKey.lastModemImei)
    }

    func meshPaired() async -> Bool { !(gateway?.settings.meshtasticBleAddress ?? "").isEmpty }

    func location() -> (fix: SosMessages.Fix, altitudeM: Double)? {
        guard let f = gateway?.location.phoneLocation.value else { return nil }
        return (SosMessages.Fix(lat: f.latitude, lon: f.longitude, accuracyM: Float(f.horizontalAccuracyM), timeMs: f.timeMs), f.altitude)
    }

    func canSendSms() -> Bool {
        #if canImport(MessageUI)
        return MFMessageComposeViewController.canSendText()
        #else
        return false
        #endif
    }

    func tak(lat: Double, lon: Double, alt: Double, reason: String) {
        // TAK CoT broadcast lands with MESHSAT-1327; the alarm is logged until then.
        GatewayController.log.warning("TAK: SOS at \(lat), \(lon) (\(reason)) not broadcast, TAK not ported yet")
    }

    func audit(event: String, detail: String) async {
        await gateway?.signingService?.auditEvent(event, detail: detail)
    }
}

extension GatewayController {
    static let sosNotificationId = "net.meshsat.ios.sos"
    /// The forwardedTo marks of an SMS the phone sent (sms/SmsStatusReceiver.kt).
    public static let smsSending = "sms:sending"
    public static let smsSent = "sms:sent"
    public static let smsDelivered = "sms:delivered"
    public static let smsFailed = "sms:failed"

    /// An SMS the user wrote in a chat: stored as a message and parked on sms_0 for the Messages
    /// composer (GatewayService.ACTION_SEND_SMS; iOS has no SMS API).
    public func queueSmsMessage(_ text: String, recipient: String) {
        Task { [self] in
            guard let disp = dispatcher else { return }
            let msgId = try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "sms", direction: "tx", sender: "self", recipient: recipient, text: text,
                    forwarded: true,
                    forwardedTo: Self.smsSending))
            _ = await disp.enqueueDirect(
                destInterface: "sms_0", payload: Array(text.utf8), textPreview: text,
                msgRef: msgId.map { "msg:\($0)" } ?? "sms:\(clock.nowMs())",
                priority: 1, recipient: recipient)
        }
    }

    /// The deliveries the person still has to send from the Messages composer.
    public func observeSmsAwaitingUser() -> AsyncStream<[MessageDelivery]> {
        let observation = db.deliveries.observeByChannelAndStatus("sms_0", Dispatcher.awaitingUser)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await rows in observation { continuation.yield(rows) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The SOS controller, made once the dispatcher exists (Android makes it in onCreate).
    func initSos() {
        let envAdapter = SosEnvAdapter()
        envAdapter.gateway = self
        let controller = SosController(
            deliveries: SosDeliveryQueriesAdapter(dao: db.deliveries), settings: SosSettingsAdapter(settings), env: envAdapter,
            log: { Self.log.warning("\($0)") })
        setSos(controller, env: envAdapter)
        controller.restore()
        keep(
            Task { [self] in
                for await n in controller.notification.subscribe() { await showSosNotification(n) }
            })
    }

    /// Start an SOS, or a test of the alarm.
    public func startSos(test: Bool, trigger: String = "button") {
        guard let sos else { return }
        Task { await sos.start(test: test, trigger: trigger) }
    }

    public func cancelSos() {
        guard let sos else { return }
        Task { await sos.cancel() }
    }

    /// The composer lane reports what the person did with a parked SMS.
    public func smsComposerFinished(deliveryId: Int64, sent: Bool) {
        guard let disp = dispatcher else { return }
        Task { [self] in
            if sent { await disp.userSent(deliveryId: deliveryId) } else { await disp.userDeclined(deliveryId: deliveryId) }
            if let del = try? await db.deliveries.getById(deliveryId), del.msgRef.hasPrefix("msg:"),
                let msgId = Int64(del.msgRef.dropFirst(4))
            {
                try? await db.messages.setForwardedTo(id: msgId, sent ? Self.smsSent : Self.smsFailed)
            }
        }
    }

    private func showSosNotification(_ n: (run: SosRun, statuses: [SosRouteStatus])?) async {
        let center = UNUserNotificationCenter.current()
        guard let n else {
            center.removeDeliveredNotifications(withIdentifiers: [Self.sosNotificationId])
            center.removePendingNotificationRequests(withIdentifiers: [Self.sosNotificationId])
            return
        }
        let words = SosController.notificationText(n.run, statuses: n.statuses)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.text
        content.userInfo = ["route": "sos"]
        content.interruptionLevel = n.run.test ? .active : .timeSensitive
        try? await center.add(UNNotificationRequest(identifier: Self.sosNotificationId, content: content, trigger: nil))
    }
}
