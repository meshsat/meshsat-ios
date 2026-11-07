// Mirrors GatewayService.onMeshWarning and warnings/WarningNotifier.kt (MESHSAT-1734, iOS
// MESHSAT-1819): a public warning a MeshSat kit relays over the mesh, on ALERT_APP or as a text
// with the kit's relay line, goes through WarningIntake into the warnings table, posts its alarm and
// fills the screen while the app is open (WarningOverlay); it is never a chat and never forwarded.
//
// iOS has no notification channels: an alert or an update plays the bundled warning_alarm.wav
// (Android's vibration rhythm as sound: three 600 ms tones, 250 ms apart) and is time-sensitive; a
// test and an all-clear use the default sound. Android lets the person grant the app Do Not Disturb
// access; the iOS equivalent is Apple's critical-alert entitlement, which this app does not have, so
// a warning follows the phone's Focus settings.
import Foundation
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatNet
import MeshSatStore
import UserNotifications

/// What the screens read of the warnings: the newest standing one not yet dismissed (the overlay),
/// and a counter that moves on every change (the list reloads on it).
public final class WarningParts: @unchecked Sendable {
    public let banner = StateBroadcast<WarningRecord?>(nil)
    public let changes = StateBroadcast<Int>(0)
}

extension GatewayController {
    /// The bundled alarm sound (App/MeshSat/Resources).
    static let warningAlarmSound = "warning_alarm.wav"

    private var warningIntake: WarningIntake { WarningIntake(store: db.warnings, now: { [clock] in clock.nowMs() }) }

    /// At start: rows older than 30 days go, as the kit's own table is pruned, and the banner is read.
    func initWarnings() {
        keep(
            Task { [self] in
                let gone = (try? await db.warnings.deleteOlderThan(clock.nowMs() - WarningIntake.keepMs)) ?? 0
                if gone > 0 { Self.log.info("Warnings: \(gone) older than 30 days removed") }
                await refreshWarnings()
            })
    }

    /// The answer to the notification prompt of the first start (MESHSAT-1823), in the log.
    public func notificationsAnswered(_ granted: Bool) {
        Self.log.notice(
            "Notifications \(granted ? "allowed" : "not allowed"): SOS and warning notifications \(granted ? "show" : "do not show")")
    }

    /// Every warning heard, newest first, for Setup > Safety > Warnings.
    public func recentWarnings(limit: Int = 200) async -> [WarningRecord] {
        (try? await db.warnings.recent(limit: limit)) ?? []
    }

    /// The person dismissed the overlay: the warning stands, it just stops asking.
    public func acknowledgeWarning(_ id: Int64) async {
        try? await warningIntake.acknowledge(id)
        await refreshWarnings()
    }

    func refreshWarnings() async {
        let banner = try? await db.warnings.unacknowledged()
        warningParts.banner.send(banner)
        warningParts.changes.update { $0 + 1 }
    }

    /// One packet that may be a warning: ALERT_APP always, a text only with the kit's relay line.
    func onMeshWarning(_ msg: MeshtasticProtocol.MeshTextMessage) async {
        let nodeId = MeshtasticProtocol.formatNodeId(msg.from)
        let name = central.radio.nodes.value.first { $0.nodeNum == msg.from }?.longName ?? ""
        let outcome: WarningIntake.Outcome
        do {
            outcome = try await warningIntake.onMesh(sender: nodeId, senderName: name, port: msg.portnum, raw: msg.text)
        } catch {
            Self.log.error("Warning from \(nodeId) could not be stored: \(error)")
            return
        }
        switch outcome {
        case .alarm(let w):
            Self.log.info("Warning from \(nodeId) on port \(msg.portnum): \(WarningWords.title(w))")
            await postWarning(w)
        case .cleared(let cancel, let cleared):
            Self.log.info("Warning cancelled from \(nodeId): \(cancel.event), \(cleared.count) cleared")
            let center = UNUserNotificationCenter.current()
            var gone = cleared.map { WarningWords.notificationId(event: $0.event, test: $0.test) }
            if gone.isEmpty { gone = [WarningWords.notificationId(event: cancel.event, test: cancel.test)] }
            center.removeDeliveredNotifications(withIdentifiers: gone)
            await postWarning(cancel)
        case .duplicate:
            Self.log.debug("Warning from \(nodeId) on port \(msg.portnum) heard already")
            return
        case .notAWarning:
            return
        }
        await refreshWarnings()
    }

    /// The alarm of a standing warning, or the all-clear of a cancel, under the event's identifier.
    private func postWarning(_ w: WarningRecord) async {
        let content = UNMutableNotificationContent()
        content.title = WarningWords.title(w)
        content.body = WarningWords.body(w)
        content.userInfo = ["route": "warnings"]
        let alarm = WarningWords.isAlarm(w)
        content.sound = alarm ? UNNotificationSound(named: UNNotificationSoundName(Self.warningAlarmSound)) : .default
        content.interruptionLevel = alarm ? .timeSensitive : .active
        let request = UNNotificationRequest(
            identifier: WarningWords.notificationId(event: w.event, test: w.test), content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Notifications not allowed: the overlay in the app still shows it.
            Self.log.info("Warning notification not shown: \(error)")
        }
    }
}
