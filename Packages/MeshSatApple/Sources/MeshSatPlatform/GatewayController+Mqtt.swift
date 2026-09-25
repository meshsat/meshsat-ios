// Mirrors initMqtt, handleMqttInbound and the mqtt branches of the connect and disconnect
// callbacks in service/GatewayService.kt: the device's own MQTT connection (mqtt_0) to a
// broker of the user's choosing, with the Reticulum MQTT interface on top (MESHSAT-354). The
// Hub session (hub_0) stays separate, as on Android.
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatMQTT
import MeshSatNet
import MeshSatReticulum
import MeshSatStore

/// The transport, one locked value (the GatewayController body is at the lint limit).
final class MqttParts: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MqttTransport?
    var transport: MqttTransport? {
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
}

/// RnsMqttInterface publishes through the transport (mqtt/MqttTransport.kt's publishRaw).
extension MqttTransport: RnsMqttLink {}

extension GatewayController {
    public var mqttTransport: MqttTransport? { mqtt.transport }

    /// GatewayService.initMqtt: nothing unless enabled with a broker and a device id.
    func initMqtt() {
        guard settings.get(SettingsKey.mqttEnabled) else {
            Self.log.debug("MQTT Hub disabled in settings")
            return
        }
        _ = mqttConnect()
    }

    /// The manager's connect callback for mqtt_0: the settings read again, the transport reused.
    func mqttConnect() -> String? {
        let brokerUrl = settings.get(SettingsKey.mqttBrokerUrl).trimmingCharacters(in: .whitespaces)
        let deviceId = settings.get(SettingsKey.mqttDeviceId).trimmingCharacters(in: .whitespaces)
        guard !brokerUrl.isEmpty, !deviceId.isEmpty else { return "mqtt not configured" }
        guard var endpoint = MqttEndpoint.parse(brokerUrl, clientId: MqttTransport.clientId(deviceId: deviceId)) else {
            return "mqtt broker URL not understood"
        }
        endpoint.username = settings.get(SettingsKey.mqttUsername)
        endpoint.password = settings.mqttPassword
        endpoint.certPins = [settings.mqttCertPin, settings.mqttCertPinBackup].filter { !$0.isEmpty }
        endpoint.clientCertPem = settings.get(SettingsKey.hubClientCertPem)
        endpoint.clientKeyPem = settings.hubClientKeyPem
        endpoint.caCertPem = settings.get(SettingsKey.hubCaCertPem)
        let transport: MqttTransport
        if let existing = mqtt.transport {
            transport = existing
        } else {
            transport = MqttTransport(makeSession: { MqttNioSession(endpoint: $0) })
            transport.setMessageCallback { [weak self] topic, payload in
                Task { await self?.handleMqttInbound(topic: topic, payload: payload) }
            }
            // Subscribed before the first connect, so no state is missed.
            let states = transport.state.subscribe()
            keep(
                Task { [self] in
                    for await state in states {
                        switch state {
                        case .connected: interfaceManager.setOnline("mqtt_0")
                        case .disconnected: interfaceManager.setOffline("mqtt_0")
                        case .error: interfaceManager.setError("mqtt_0", "MQTT connection error")
                        case .connecting: interfaceManager.setConnecting("mqtt_0")
                        }
                    }
                })
            mqtt.transport = transport
            // The Reticulum interface over it (mqtt_rns_0), into the node's map.
            let rns = RnsMqttInterface(mqtt: transport, deviceId: { deviceId }, log: { Self.log.debug("\($0)") })
            rns.setReceiveCallback { [weak self] ifaceId, raw in self?.rnsNode?.onPacketReceived(sourceInterface: ifaceId, raw) }
            updateRnsParts { $0.mqtt = rns }
            Self.log.info("RNS MQTT interface initialized for device \(deviceId)")
        }
        transport.connect(endpoint: endpoint, deviceId: deviceId)
        return nil
    }

    func mqttDisconnect() { mqtt.transport?.disconnect() }

    func stopMqtt() {
        mqtt.transport?.disconnect()
        mqtt.transport = nil
        updateRnsParts { $0.mqtt = nil }
    }

    /// GatewayService.handleMqttInbound: the reverse-path topics.
    func handleMqttInbound(topic: String, payload: String) async {
        if topic.hasSuffix(RnsMqttInterface.topicRxSuffix) {
            _ = rnsParts.mqtt?.processIncomingMessage(topic: topic, payload: payload)
        } else if topic == MqttTransport.topicRoutes {
            // Route hints from the Hub (MESHSAT-354): logged, as Android logs them.
            if let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                let routes = obj["routes"] as? [[String: Any]]
            {
                for r in routes where (r["dest_hash"] as? String)?.count == 32 {
                    Self.log.debug("Route hint: \(r["dest_hash"] ?? "") via MQTT (hops=\(r["hops"] ?? 1), cost=\(r["cost"] ?? 0))")
                }
                Self.log.info("Received \(routes.count) route hints from Hub")
            }
        } else if topic.contains("/mt/send") {
            // An MT from the Hub: stored, then through the access rules.
            let text = JSONBody.parse(Data(payload.utf8))?.string("text") ?? ""
            guard !text.isEmpty else { return }
            try? await db.messages.insert(
                MessageRecord(timestamp: clock.nowMs(), transport: "mqtt", direction: "rx", sender: "hub", text: text))
            _ = await dispatcher?.dispatchAccess(
                sourceInterface: "mqtt_0", msg: RouteMessage(text: text, from: "hub", portNum: 1, visited: ["mqtt_0"]),
                payload: Array(text.utf8))
            interfaceManager.recordActivity("mqtt_0")
        } else if topic.contains("/sms/outbound") {
            // The Hub asks the phone to send an SMS (MESHSAT-196): iOS has no SMS API, so it
            // is parked for the Messages composer, as a typed SMS is (queueSmsMessage).
            let body = JSONBody.parse(Data(payload.utf8))
            let to = body?.string("to") ?? ""
            let text = body?.string("text") ?? ""
            guard !to.isEmpty, !text.isEmpty else { return }
            queueSmsMessage(text, recipient: to)
            Self.log.info("Hub asked for an SMS to \(to): parked for the composer (iOS has no SMS API)")
        } else if topic.contains("/tak/cot/in") {
            await onTakCotInbound(payload)
        } else if topic.contains("/config/update") {
            let body = JSONBody.parse(Data(payload.utf8)) ?? JSONBody()
            if let v = body.int("health_interval") { settings.set(SettingsKey.hubHealthInterval, String(v)) }
            if let v = body.bool("deadman_enabled") { settings.set(SettingsKey.deadmanEnabled, v) }
            if let v = body.int("deadman_timeout_min") { settings.set(SettingsKey.deadmanTimeoutMin, String(v)) }
            applyDeadManSettings()
            Self.log.info("Config update applied from MQTT")
        }
    }
}
