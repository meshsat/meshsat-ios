// Mirrors the TAK parts of service/GatewayService.kt (MESHSAT-191, 451, 1708): the TakIntegration
// built next to the MQTT transport, the CoT PLI on every phone fix, the SOS and dead-man
// events, inbound CoT from the Hub (reporter.onTakCot and the "/tak/cot/in" branch of the
// MQTT transport) onto the map, and a dispatcher's chat to this phone (onTakChatIn, sendTakChat). Android publishes through its generic
// MQTT transport (mqtt_0); iOS has none yet, so the Hub session carries the events, on the
// same topic under the tenant's prefix. There is no ATAK intent on iOS (README).
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatStore
import MeshSatTak

/// The TAK lane's state, one locked value (the GatewayController body is at the lint limit).
final class TakParts: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TakIntegration?
    /// Message ids of the TAK chats already shown, oldest first: the Hub delivers at least once.
    private var seen: [String] = []
    var integration: TakIntegration? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    /// True the first time a chat id is seen; the last 256 are kept.
    func firstSight(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if seen.contains(id) { return false }
        seen.append(id)
        if seen.count > 256 { seen.removeFirst(seen.count - 256) }
        return true
    }
}

extension GatewayController {
    /// GatewayService.initMqtt's TAK block: the integration always exists (it parses inbound
    /// events); it publishes only when TAK is enabled in the settings.
    func initTak() {
        let enabled = settings.get(SettingsKey.takEnabled)
        let prefixSetting = settings.get(SettingsKey.takCallsignPrefix).trimmingCharacters(in: .whitespaces)
        let prefix = prefixSetting.isEmpty ? "MESHSAT" : prefixSetting
        let configuredId = settings.get(SettingsKey.hubBridgeId)
        let deviceId = configuredId.isEmpty ? "ios-" + String(deviceIdentifier().prefix(12)) : configuredId
        var publish: TakIntegration.Publisher?
        if enabled {
            publish = { [weak self] xml in
                guard let self, let hub = hubReporter else { return }
                _ = await hub.publishRaw(topic: hub.topics.takCotOut(deviceId), payload: Array(xml.utf8))
            }
        }
        let integration = TakIntegration(
            deviceId: deviceId, callsignPrefix: prefix, mqttExportEnabled: settings.get(SettingsKey.takMqttExport), publish: publish,
            log: { Self.log.debug("TAK: \($0)") })
        tak.integration = integration
        if enabled {
            Self.log.info("TAK/CoT integration initialized: callsign=\(integration.callsign) mqtt=\(integration.mqttExportEnabled)")
        } else {
            Self.log.debug("TAK/CoT disabled in settings")
        }
    }

    func stopTak() { tak.integration = nil }

    /// The CoT PLI on each phone fix (locationListener).
    func takSendPosition(_ fix: PhoneFix) async {
        guard let integration = tak.integration else { return }
        await integration.sendPosition(lat: fix.latitude, lon: fix.longitude, alt: fix.altitude, course: fix.courseDeg, speed: fix.speedMps)
    }

    /// The SOS as a CoT emergency (SosController's env.tak).
    func takSendSOS(lat: Double, lon: Double, alt: Double, reason: String) async {
        await tak.integration?.sendSOS(lat: lat, lon: lon, alt: alt, reason: reason)
    }

    /// The dead man's switch alarm.
    func takSendDeadman(lat: Double, lon: Double, timeoutSec: Int) async {
        await tak.integration?.sendDeadman(lat: lat, lon: lon, timeoutSec: timeoutSec)
    }

    /// A CoT event from the Hub: with coordinates, a position on the map under the sender's
    /// callsign. A position goes on the map only, as on Android (MESHSAT-1708); anything else is
    /// also a line in the message list.
    func onTakCotInbound(_ xml: String) async {
        let integration = tak.integration
        let event = integration?.parseInbound(xml) ?? CotXml.parse(xml)
        let sender = event?.detail?.contact?.callsign ?? event?.uid ?? "tak-server"
        let hasPoint = event.map { $0.point.lat != 0 && $0.point.lon != 0 } ?? false
        if !(hasPoint && event?.type.hasPrefix("a-") == true) {
            let text = event.flatMap { integration?.formatForDisplay($0) } ?? String(xml.prefix(500))
            try? await db.messages.insert(
                MessageRecord(timestamp: clock.nowMs(), transport: "tak", direction: "rx", sender: sender, text: text))
        }
        if let ev = event, hasPoint {
            try? await db.nodePositions.insert(
                NodePosition(
                    timestamp: clock.nowMs(), nodeId: Self.aprsNodeId(sender), nodeName: sender, latitude: ev.point.lat,
                    longitude: ev.point.lon,
                    altitude: Int(ev.point.hae)))
            Self.log.info("TAK position stored from Hub: \(sender)")
        }
    }

    /// A chat a dispatcher on TAK, or an operator on the Hub's map, wrote to this phone
    /// (MESHSAT-1708): a message in its conversation and a notification. Anything else on the
    /// topic, or a chat seen already, is dropped.
    func onTakChatIn(_ xml: String) async {
        guard let integration = tak.integration, let ev = integration.parseInbound(xml), let chat = integration.chatFor(ev) else { return }
        let messageId = ev.detail?.chat?.messageId ?? ""
        guard tak.firstSight(messageId.isEmpty ? ev.uid : messageId) else { return }
        try? await db.messages.insert(
            MessageRecord(
                timestamp: clock.nowMs(), transport: "tak", direction: "rx",
                sender: TakChats.peer(uid: chat.fromUid, callsign: chat.fromCallsign),
                recipient: integration.uid, text: chat.text))
        messageNotifications.send((title: chat.fromCallsign.isEmpty ? "TAK" : chat.fromCallsign, text: chat.text))
        Self.log.info("TAK chat from \(chat.fromCallsign) stored")
    }

    /// Answer a TAK contact ("tak:<uid>#<callsign>"): a GeoChat to it on the Hub session (MESHSAT-1708).
    public func sendTakChat(to recipient: String, text: String) async {
        let integration = tak.integration
        let uid = TakChats.uid(ofPeer: recipient)
        let online = await hubReporter?.isConnected ?? false
        let sent = integration?.canExport == true && !uid.isEmpty && online
        if sent, let integration {
            await integration.sendChat(to: uid, callsign: TakChats.callsign(ofPeer: recipient), text: text)
        } else {
            Self.log.warning("TAK reply not sent: TAK export off or no Hub session")
        }
        _ = try? await db.messages.insert(
            MessageRecord(
                timestamp: clock.nowMs(), transport: "tak", direction: "tx", sender: integration?.uid ?? "", recipient: recipient,
                text: text,
                forwarded: sent, forwardedTo: sent ? Self.takSent : Self.takNotSent))
    }

    /// A reply to a TAK contact went out on the Hub session, or could not (MESHSAT-1708).
    public static let takSent = "tak:sent"
    public static let takNotSent = "tak:not_sent"
}
