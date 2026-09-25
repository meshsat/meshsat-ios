// The Hub half of GatewayController (GatewayService.initHubReporter, handleHubCommand,
// onHubReceipt, the hub_0 delivery and the position publish): the phone as a mobile field node
// in the Hub fleet, over the HubReporter on an mqtt-nio session.
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatMQTT
import MeshSatNet
import MeshSatStore
import MeshSatWire

extension GatewayController {
    /// The Hub's name for the link a message arrived on (MESHSAT-1274): the Hub stores it
    /// verbatim as the source of the message. An empty bearer means it was written here.
    static func hubChannel(of sourceBearer: String) -> String {
        if sourceBearer.hasPrefix("sms") { return "sms" }
        if sourceBearer.hasPrefix("mesh") { return "mesh" }
        if sourceBearer.hasPrefix("iridium9704") { return "iridium_imt" }
        if sourceBearer.hasPrefix("iridium") { return "iridium" }
        if sourceBearer.hasPrefix("aprs") { return "aprs" }
        return "mqtt"
    }

    func initHubReporter() {
        guard settings.get(SettingsKey.hubEnabled) else {
            Self.log.debug("Hub Reporter disabled in settings")
            return
        }
        let hubUrl = settings.get(SettingsKey.hubUrl)
        guard !hubUrl.isEmpty else {
            Self.log.warning("Hub Reporter: URL not configured")
            return
        }
        var bridgeId = settings.get(SettingsKey.hubBridgeId)
        if bridgeId.isEmpty { bridgeId = "ios-" + String(deviceIdentifier().prefix(12)) }
        let config = HubReporterConfig(
            hubUrl: hubUrl, bridgeId: bridgeId, callsign: settings.get(SettingsKey.hubCallsign),
            username: settings.get(SettingsKey.hubUsername),
            password: settings.hubPassword, certPin: settings.mqttCertPin, certPinBackup: settings.mqttCertPinBackup,
            healthIntervalSec: Int(settings.get(SettingsKey.hubHealthInterval)) ?? 30,
            clientCertPem: settings.get(SettingsKey.hubClientCertPem),
            clientKeyPem: settings.hubClientKeyPem, caCertPem: settings.get(SettingsKey.hubCaCertPem),
            topicPrefix: settings.get(SettingsKey.hubTopicPrefix))
        let reporter = HubReporter(config: config, host: HubHost(gateway: self), makeSession: Self.makeHubSession, clock: clock)
        reporter.setCommandCallback { [self] cmd in Task { await handleHubCommand(cmd) } }
        // TAK CoT from the Hub: the message list and the map (GatewayController+Tak).
        reporter.setTakCotCallback { [self] xml in Task { await onTakCotInbound(xml) } }
        reporter.setMoAckCallback { [self] imei, momsn in Task { await onHubReceipt(imei: imei, momsn: momsn) } }
        reporter.start()
        setHubReporter(reporter)
        Self.log.info("Hub Reporter initialized: bridge=\(bridgeId)")
        // hub_0 follows this client (MESHSAT-1261).
        keep(
            Task { [self] in
                for await state in reporter.state.subscribe() {
                    switch state {
                    case .connected: interfaceManager.setOnline("hub_0")
                    case .connecting: interfaceManager.setConnecting("hub_0")
                    case .disconnected: interfaceManager.setOffline("hub_0")
                    case .error: interfaceManager.setError("hub_0", "Hub connection failed")
                    }
                }
            })
    }

    static func makeHubSession(_ config: HubReporterConfig) -> any MQTTSession {
        var endpoint =
            MqttEndpoint.parse(config.hubUrl, clientId: config.clientId)
            ?? MqttEndpoint(host: config.hubUrl, port: 8883, useTLS: true, useWebSockets: false, clientId: config.clientId)
        endpoint.username = config.username
        endpoint.password = config.password
        endpoint.clientCertPem = config.clientCertPem
        endpoint.clientKeyPem = config.clientKeyPem
        endpoint.caCertPem = config.caCertPem
        endpoint.certPins = [config.certPin, config.certPinBackup].filter { !$0.isEmpty }
        return MqttNioSession(endpoint: endpoint)
    }

    /// A message for the Hub, the way a kit sends it (deliverToTransport's hub_0 branch).
    func deliverToHub(payload: [UInt8], textPreview: String, recipient: String, deliveryId: Int64, sourceBearer: String) async -> String? {
        guard let hub = hubReporter else { return "the Hub is not set up" }
        guard hub.state.value == .connected else { return "not connected to the Hub" }
        // The id names who the message came from; bridge_id names this phone, which carried it.
        let bridgeId = settings.get(SettingsKey.hubBridgeId)
        var origin = ""
        if deliveryId != 0, let del = try? await db.deliveries.getById(deliveryId) { origin = del.origin }
        let deviceId = HubOrigin.deviceIdFor(
            sourceBearer: sourceBearer, origin: origin, modemImei: await driver.modemInfo.imei, bridgeId: bridgeId)
        if deviceId.isEmpty { return "no device id for the Hub" }
        let text = payload.isEmpty ? textPreview : String(decoding: payload, as: UTF8.self)
        let messageId = (deliveryId != 0 && !bridgeId.isEmpty) ? "\(bridgeId)-d\(deliveryId)" : ""
        let ok = await hub.publishMessage(
            deviceId: deviceId, text: text, recipient: recipient, channel: Self.hubChannel(of: sourceBearer), messageId: messageId)
        if !ok { return "the Hub did not take the message" }
        try? await db.messages.insert(
            MessageRecord(
                timestamp: clock.nowMs(), transport: "hub", direction: "tx", sender: "self",
                recipient: recipient.isEmpty ? "hub" : recipient,
                text: textPreview, forwarded: true, forwardedTo: "hub:mo/decoded"))
        return nil
    }

    /// The Hub has an MO from this phone's modem (MESHSAT-1246): the delivery is acknowledged
    /// and the chat message shows delivered.
    func onHubReceipt(imei: String, momsn: Int) async {
        let ref = "\(imei):\(momsn)"
        guard let rows = try? await db.deliveries.getBySatRef(ref), !rows.isEmpty else {
            // Rock7 tells the Hub as soon as the gateway has the MO, while the modem is still
            // closing the session on this side: on 25 Sep 2026 the receipt for MOMSN 248 came
            // 4 s before the delivery got its reference, and the message never got its second
            // tick. Keep the receipt; the send path claims it when the reference is written.
            Self.earlyReceipts.remember(ref)
            Self.log.info("The Hub has MOMSN \(momsn) before the phone finished its session; kept")
            return
        }
        await confirmDeliveries(rows, ref: ref, momsn: momsn)
    }

    /// The send path, right after the delivery got its satellite reference: a receipt that
    /// arrived early is applied now.
    func claimEarlyHubReceipt(ref: String) async {
        guard Self.earlyReceipts.take(ref) else { return }
        guard let rows = try? await db.deliveries.getBySatRef(ref), !rows.isEmpty else { return }
        let momsn = Int(ref.split(separator: ":").last ?? "") ?? -1
        await confirmDeliveries(rows, ref: ref, momsn: momsn)
    }

    private func confirmDeliveries(_ rows: [MessageDelivery], ref: String, momsn: Int) async {
        _ = try? await db.deliveries.markAckedBySatRef(ref)
        for del in rows where del.msgRef.hasPrefix("msg:") {
            if let msgId = Int64(del.msgRef.dropFirst(4)) { try? await db.messages.setForwardedTo(id: msgId, Self.iridiumDelivered) }
        }
        Self.log.info("The Hub has MOMSN \(momsn): \(rows.count) delivery(ies) confirmed")
    }

    /// Receipts that outran the session, kept for an hour.
    private static let earlyReceipts = EarlyReceipts()

    final class EarlyReceipts: @unchecked Sendable {
        private let lock = NSLock()
        private var refs: [String: Date] = [:]

        func remember(_ ref: String) {
            lock.lock()
            defer { lock.unlock() }
            let cutoff = Date().addingTimeInterval(-3600)
            refs = refs.filter { $0.value > cutoff }
            refs[ref] = Date()
        }

        func take(_ ref: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return refs.removeValue(forKey: ref) != nil
        }
    }

    /// Commands from the Hub (GatewayService.handleHubCommand). Each is answered.
    func handleHubCommand(_ cmd: HubCommand) async {
        guard let hub = hubReporter else { return }
        let payload = JSONBody.parse(Data(cmd.payload.utf8)) ?? JSONBody()
        var error = ""
        switch cmd.cmd {
        case "send_text":
            let text = payload.string("text") ?? ""
            if !text.isEmpty {
                _ = await dispatcher?.dispatchAccess(
                    sourceInterface: "hub_reporter",
                    msg: RouteMessage(text: text, from: "hub", channel: 0, portNum: 1, visited: ["hub_reporter"]),
                    payload: Array(text.utf8))
            }
        case "credential_push", "credential_revoke":
            error = await handleCredentialCommand(cmd.cmd, payload)
        case "send_mt":
            let text = payload.string("text") ?? ""
            let data = Data(base64Encoded: payload.string("data") ?? "").map { [UInt8]($0) } ?? Array(text.utf8)
            if await driver.state != .connected {
                error = "iridium modem not connected"
            } else if !(await driver.writeMoBuffer(data)) {
                error = "failed to write MO buffer"
            } else if let r = await driver.sbdix(), r.moSuccess {
                try? await creditTracker.recordMo(moMsn: r.moMsn)
            } else {
                error = "SBDIX failed"
            }
        case "flush_burst":
            await flushBurst()
        case "config_update":
            if let v = payload.int("health_interval") { settings.set(SettingsKey.hubHealthInterval, String(v)) }
            if let v = payload.bool("deadman_enabled") { settings.set(SettingsKey.deadmanEnabled, v) }
            if let v = payload.int("deadman_timeout_min") { settings.set(SettingsKey.deadmanTimeoutMin, String(v)) }
            applyDeadManSettings()
        case "reboot":
            // iOS cannot restart the app; the gateway restarts its transports instead.
            Self.log.info("Hub reboot command received: restarting the node link")
            central.forceReconnect()
        case "hemb_bond_create", "hemb_bond_delete", "key_rotate":
            await handleStoreCommand(cmd.cmd, payload)
        default:
            error = "unsupported command: \(cmd.cmd)"
        }
        await hub.publishCommandResponse(
            CommandResponse(requestId: cmd.requestId, cmd: cmd.cmd, status: error.isEmpty ? "ok" : "error", error: error))
    }

    /// credential_push and credential_revoke: the Hub's provider credentials into the store.
    func handleCredentialCommand(_ cmd: String, _ payload: JSONBody) async -> String {
        if cmd == "credential_revoke" {
            try? await db.providerCredentials.deleteById(payload.string("credential_id") ?? "")
            return ""
        }
        let data = Data(base64Encoded: payload.string("data") ?? "") ?? Data()
        let cred = ProviderCredential(
            id: payload.string("credential_id") ?? "", provider: payload.string("provider") ?? "", name: payload.string("name") ?? "",
            credType: payload.string("cred_type") ?? "", encryptedData: data,
            certNotAfter: payload.string("cert_not_after").flatMap { $0.isEmpty ? nil : $0 },
            certFingerprint: payload.string("cert_fingerprint") ?? "", version: Int(payload.int("version") ?? 1), source: "hub",
            receivedAt: clock.nowMs())
        do {
            try await db.providerCredentials.upsert(cred)
            Self.log.info("Credential received from Hub: \(cred.id) (\(cred.provider))")
            return ""
        } catch {
            return "\(error)"
        }
    }

    /// hemb_bond_create, hemb_bond_delete and key_rotate: rows in the store, a key in the Keychain.
    func handleStoreCommand(_ cmd: String, _ payload: JSONBody) async {
        switch cmd {
        case "hemb_bond_create":
            var members: [String] = []
            if case .array(let a)? = payload["members"] {
                members = a.compactMap {
                    if case .string(let s) = $0 { return s }
                    return nil
                }
            }
            let membersJson = (try? JSONSerialization.data(withJSONObject: members)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            var budget = 0.0
            if case .double(let d)? = payload["cost_budget"] {
                budget = d
            } else if let i = payload.int("cost_budget") {
                budget = Double(i)
            }
            try? await db.hembBondGroups.insert(
                HembBondGroup(
                    id: payload.string("bond_id") ?? "", label: payload.string("label") ?? "", members: membersJson, costBudget: budget,
                    createdAt: clock.nowMs()))
        case "hemb_bond_delete":
            try? await db.hembBondGroups.delete(payload.string("bond_id") ?? "")
        default:
            let channelType = payload.string("channel_type") ?? ""
            let address = payload.string("address") ?? ""
            let keyHex = payload.string("key_hex") ?? ""
            let version = payload.int("version") ?? 1
            settings.secure.set("hub_key:\(channelType):\(address)", keyHex)
            if !address.isEmpty {
                try? await db.conversationKeys.upsert(ConversationKey(sender: address, hexKey: keyHex, label: "hub-rotated-v\(version)"))
            }
        }
    }

    /// A fix goes to the Hub as the phone's position (locationListener, MESHSAT-292).
    func publishPositionToHub(_ fix: PhoneFix) async {
        guard let hub = hubReporter, hub.state.value == .connected else { return }
        var deviceId = settings.get(SettingsKey.hubBridgeId)
        if deviceId.isEmpty { deviceId = "ios-phone" }
        await hub.publishDevicePosition(
            deviceId,
            DevicePosition(
                lat: fix.latitude, lon: fix.longitude, alt: fix.altitude, speed: fix.speedMps, course: fix.courseDeg, source: "gps"))
    }

    /// A stable id for this install, for the bridge id when none is set.
    func deviceIdentifier() -> String {
        let key = "net.meshsat.ios.install_id"
        if let existing = settings.defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        settings.defaults.set(fresh, forKey: key)
        return fresh
    }
}

/// What the reporter reads off the phone (HubReporter.collectInterfaces and friends).
final class HubHost: HubReporterHost, @unchecked Sendable {
    private unowned let gateway: GatewayController

    init(gateway: GatewayController) { self.gateway = gateway }

    private func status(_ state: InterfaceState) -> String {
        switch state {
        case .online: "online"
        case .connecting: "binding"
        default: "offline"
        }
    }

    func interfaces() -> [InterfaceInfo] {
        let states = gateway.interfaceManager.states.value
        var out = [InterfaceInfo(name: "ble_mesh_0", type: "meshtastic", status: status(states["mesh_0"]?.state ?? .offline))]
        let imei = gateway.lastModemImei
        out.append(
            InterfaceInfo(name: "iridium_spp_0", type: "iridium_sbd", status: status(states["iridium_0"]?.state ?? .offline), imei: imei))
        return out
    }

    func interfaceHealth() -> [InterfaceHealth] {
        let states = gateway.interfaceManager.states.value
        return [
            InterfaceHealth(name: "ble_mesh_0", status: states["mesh_0"]?.state == .online ? "online" : "offline"),
            InterfaceHealth(
                name: "iridium_spp_0", status: states["iridium_0"]?.state == .online ? "online" : "offline",
                signalBars: gateway.lastModemSignal),
        ]
    }

    func capabilities() -> [String] { ["ios", "gps", "battery", "ble_mesh", "iridium_sbd"] }

    func location() -> HubLocation? {
        guard let fix = gateway.location.phoneLocation.value else { return nil }
        return HubLocation(lat: fix.latitude, lon: fix.longitude, alt: fix.altitude, source: "gps")
    }

    func batteryPct() -> Double { DeviceMetrics.batteryPct() }
    func memPct() -> Double { DeviceMetrics.memPct() }
    func diskPct() -> Double { DeviceMetrics.diskPct() }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var deviceModel: String { DeviceMetrics.model() }
}
