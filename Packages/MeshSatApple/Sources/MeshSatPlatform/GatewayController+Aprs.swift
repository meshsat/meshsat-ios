// Mirrors initAprs, initAprsIs, initAprsKiss, initAprsMessageTracker, initAprsBeacon,
// handleAprsPacket, sendAprsAck and the aprs branches of the connect callback and of
// deliverToTransport in service/GatewayService.kt (MESHSAT-230, 231, 232). Two modes, as on
// Android: "kiss" (a TNC such as Direwolf over TCP) and "is" (APRS-IS). One difference,
// deliberate: the manager's reconnect follows the configured mode; Android's connect callback
// always dials KISS, so an APRS-IS lane that dropped came back on the wrong transport.
import Foundation
import MeshSatAprs
import MeshSatEngine
import MeshSatNet
import MeshSatStore

/// The APRS lane's state, one locked value: the GatewayController body is at the lint limit.
final class AprsParts: @unchecked Sendable {
    struct State {
        var isClient: AprsIsClient?
        var kiss: KissClient?
        var tracker: AprsMessageTracker?
        var beacon: AprsBeacon?
        var fullCallsign = ""
        var mode = "kiss"
    }
    private let lock = NSLock()
    private var value = State()
    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func update(_ change: (inout State) -> Void) {
        lock.lock()
        change(&value)
        lock.unlock()
    }
}

extension GatewayController {
    static let aprsDest = Ax25Address("APMSHT")
    static let aprsPath = [Ax25Address("WIDE1", 1), Ax25Address("WIDE2", 1)]

    /// CALL-SSID from the settings; the bare callsign for SSID 0 or none.
    func aprsFullCallsign() -> String {
        let callsign = settings.get(SettingsKey.aprsCallsign).trimmingCharacters(in: .whitespaces).uppercased()
        // No callsign, no lane: Android's initAprs stops on a blank callsign before the SSID
        // is appended (a test caught "-10" being built from nothing, 25 Sep 2026).
        guard !callsign.isEmpty else { return "" }
        let ssid = settings.get(SettingsKey.aprsSsid).trimmingCharacters(in: .whitespaces)
        return !ssid.isEmpty && ssid != "0" ? "\(callsign)-\(ssid)" : callsign
    }

    /// GatewayService.initAprs: nothing unless enabled with a callsign.
    func initAprs() {
        guard settings.get(SettingsKey.aprsEnabled) else { return }
        let full = aprsFullCallsign()
        guard !full.isEmpty else {
            Self.log.warning("APRS: callsign not configured")
            return
        }
        let mode = settings.get(SettingsKey.aprsMode)
        aprs.update {
            $0.fullCallsign = full
            $0.mode = mode
        }
        initAprsMessageTracker()
        initAprsBeacon()
        keep(Task { [self] in _ = await aprsConnect() })
    }

    func stopAprs() {
        let parts = aprs.state
        aprs.update { $0 = AprsParts.State() }
        parts.tracker?.cancelAll()
        parts.beacon?.stop()
        parts.isClient?.disconnect()
        parts.kiss?.disconnect()
    }

    /// The manager's connect callback for aprs_0: dial the configured mode. The state observer
    /// reports online, so the return is only an error.
    func aprsConnect() async -> String? {
        let full = aprsFullCallsign()
        guard !full.isEmpty else { return "APRS callsign not configured" }
        if settings.get(SettingsKey.aprsMode) == "is" {
            await initAprsIs(full)
        } else {
            await initAprsKiss(full)
        }
        return nil
    }

    func aprsDisconnect() {
        let parts = aprs.state
        parts.isClient?.disconnect()
        parts.kiss?.disconnect()
    }

    private func mirrorAprsState(_ states: AsyncStream<AprsClientState>, error: String) {
        keep(
            Task { [self] in
                for await state in states {
                    switch state {
                    case .connected: interfaceManager.setOnline("aprs_0")
                    case .disconnected: interfaceManager.setOffline("aprs_0")
                    case .error: interfaceManager.setError("aprs_0", error)
                    case .connecting: interfaceManager.setConnecting("aprs_0")
                    }
                }
            })
    }

    /// GatewayService.initAprsKiss: the TNC at host:port from the settings.
    private func initAprsKiss(_ full: String) async {
        let host = settings.get(SettingsKey.aprsKissHost).trimmingCharacters(in: .whitespaces)
        let port = Int(settings.get(SettingsKey.aprsKissPort)) ?? 8001
        let client: KissClient
        if let existing = aprs.state.kiss {
            client = existing
        } else {
            client = KissClient(dialer: NWByteStreamDialer(), log: { Self.log.debug("APRS KISS: \($0)") })
            client.setFrameCallback { [weak self] frame in
                Task { await self?.handleAprsPacket(AprsCodec.parse(frame)) }
            }
            // Subscribed before the first connect, so no state is missed.
            mirrorAprsState(client.state.subscribe(), error: "KISS connection error")
            aprs.update { $0.kiss = client }
        }
        await client.connect(host: host.isEmpty ? "localhost" : host, port: port)
        Self.log.info("APRS KISS initialized (\(full) on \(host):\(port))")
    }

    /// GatewayService.initAprsIs: login with the passcode and a range filter round the phone.
    private func initAprsIs(_ full: String) async {
        let server = settings.get(SettingsKey.aprsIsServer).trimmingCharacters(in: .whitespaces)
        let port = Int(settings.get(SettingsKey.aprsIsPort)) ?? 14580
        let passcodeSetting = settings.get(SettingsKey.aprsIsPasscode).trimmingCharacters(in: .whitespaces)
        let passcode = passcodeSetting.isEmpty ? "-1" : passcodeSetting
        let range = Int(settings.get(SettingsKey.aprsIsFilterRange)) ?? 100
        let fix = location.phoneLocation.value
        let client: AprsIsClient
        if let existing = aprs.state.isClient {
            client = existing
        } else {
            client = AprsIsClient(dialer: NWByteStreamDialer(), log: { Self.log.debug("APRS-IS: \($0)") })
            client.setPacketCallback { [weak self] pkt in
                Task { await self?.handleAprsPacket(pkt) }
            }
            mirrorAprsState(client.state.subscribe(), error: "APRS-IS connection error")
            aprs.update { $0.isClient = client }
        }
        await client.connect(
            server: server.isEmpty ? "rotate.aprs2.net" : server, port: port, callsign: full, passcode: passcode,
            filterLat: fix?.latitude ?? 0, filterLon: fix?.longitude ?? 0, filterRange: range)
        Self.log.info("APRS-IS initialized (\(full) on \(server):\(port), filter=\(range)km)")
    }

    /// GatewayService.initAprsMessageTracker (MESHSAT-232): directed messages with ack tracking.
    private func initAprsMessageTracker() {
        let tracker = AprsMessageTracker()
        tracker.setOnSend { [weak self] to, text, msgId in
            Task { await self?.aprsTransmit(AprsCodec.encodeMessage(to: to, text: text, msgId: msgId)) }
        }
        tracker.setOnStatusChange { [weak self] msgId, status in
            guard let self else { return }
            Self.log.info("APRS msg \(msgId) delivery: \(status)")
            Task {
                try? await self.db.messages.insert(
                    MessageRecord(
                        timestamp: self.clock.nowMs(), transport: "aprs", direction: "rx", sender: "system",
                        text: "[APRS] Message \(msgId): \(Self.aprsStatusName(status))"))
            }
        }
        aprs.update { $0.tracker = tracker }
    }

    /// Android prints the enum constant: PENDING, ACKED, REJECTED, FAILED.
    static func aprsStatusName(_ status: AprsMessageTracker.DeliveryStatus) -> String {
        switch status {
        case .pending: return "PENDING"
        case .acked: return "ACKED"
        case .rejected: return "REJECTED"
        case .failed: return "FAILED"
        }
    }

    /// GatewayService.initAprsBeacon (MESHSAT-231): smart beaconing from the phone's fixes.
    private func initAprsBeacon() {
        guard settings.get(SettingsKey.aprsIsBeaconEnabled) else { return }
        let intervalMin = Int(settings.get(SettingsKey.aprsIsBeaconInterval)) ?? 10
        let beacon = AprsBeacon()
        beacon.slowRateSec = max(intervalMin * 60, AprsBeacon.minBeaconIntervalSec)
        beacon.fastRateSec = AprsBeacon.defaultFastRateSec
        beacon.setOnBeacon { [weak self] lat, lon, _, _, _, comment in
            guard let self else { return }
            Task {
                await self.aprsTransmit(AprsCodec.encodePosition(lat: lat, lon: lon, comment: comment))
                let full = self.aprs.state.fullCallsign
                try? await self.db.messages.insert(
                    MessageRecord(
                        timestamp: self.clock.nowMs(), transport: "aprs", direction: "tx", sender: "self",
                        text: "[APRS:\(full)] beacon " + String(format: "%.4f,%.4f", lat, lon) + " \(comment)"))
            }
        }
        keep(
            Task { [self] in
                for await fix in location.phoneLocation.subscribe() {
                    guard let fix else { continue }
                    beacon.onLocationUpdate(
                        AprsFix(
                            latitude: fix.latitude, longitude: fix.longitude, altitude: fix.altitude, bearing: fix.courseDeg,
                            speed: fix.speedMps))
                }
            })
        beacon.start()
        aprs.update { $0.beacon = beacon }
        Self.log.info("APRS beacon started (interval=\(intervalMin)min, smart beaconing enabled)")
    }

    /// One info field out, on whichever client is up: as a TNC-2 line to APRS-IS, or as an
    /// AX.25 UI frame via WIDE1-1,WIDE2-1 to the TNC.
    func aprsTransmit(_ info: [UInt8]) async {
        let parts = aprs.state
        if let client = parts.isClient, client.isConnected {
            await client.sendRaw("\(parts.fullCallsign)>APMSHT,TCPIP*:\(String(decoding: info, as: UTF8.self))")
        } else if let kiss = parts.kiss, kiss.isConnected {
            let call = parts.fullCallsign.split(separator: "-", maxSplits: 1).map(String.init)
            let src = Ax25Address(call.first ?? parts.fullCallsign, call.count > 1 ? Int(call[1]) ?? 10 : 0)
            await kiss.sendFrame(Ax25Codec.encode(dst: Self.aprsDest, src: src, path: Self.aprsPath, info: info))
        }
    }

    /// GatewayService.handleAprsPacket: an inbound packet from either client.
    func handleAprsPacket(_ pkt: AprsPacket) async {
        let parts = aprs.state
        // Acks and rejects for our messages are control only, never stored.
        if let tracker = parts.tracker, tracker.processInbound(pkt) { return }
        let text: String
        switch pkt.dataType {
        case "!", "=", "/", "@": text = "[APRS:\(pkt.source)] " + String(format: "%.4f,%.4f", pkt.lat, pkt.lon) + " \(pkt.comment)"
        case ":": text = "[APRS:\(pkt.source)\u{2192}\(pkt.msgTo)] \(pkt.message)"
        default: text = "[APRS:\(pkt.source)] \(pkt.raw)"
        }
        try? await db.messages.insert(
            MessageRecord(timestamp: clock.nowMs(), transport: "aprs", direction: "rx", sender: pkt.source, text: text))
        // A directed message to us with an id gets an ack (MESHSAT-232).
        if pkt.dataType == ":", !pkt.msgId.isEmpty, pkt.msgTo.caseInsensitiveCompare(parts.fullCallsign) == .orderedSame {
            let padded = pkt.source.padding(toLength: max(9, pkt.source.count), withPad: " ", startingAt: 0)
            await aprsTransmit(Array(":\(padded):ack\(pkt.msgId)".utf8))
        }
        // The station goes on the map.
        if pkt.lat != 0, pkt.lon != 0 {
            try? await db.nodePositions.insert(
                NodePosition(
                    timestamp: clock.nowMs(), nodeId: Self.aprsNodeId(pkt.source), nodeName: pkt.source, latitude: pkt.lat,
                    longitude: pkt.lon,
                    altitude: 0))
        }
        interfaceManager.recordActivity("aprs_0")
        guard let disp = dispatcher else { return }
        let n = await disp.dispatchAccess(
            sourceInterface: "aprs_0", msg: RouteMessage(text: text, from: pkt.source, portNum: 1, visited: ["aprs_0"]),
            payload: Array(text.utf8))
        if n > 0 { Self.log.info("Dispatched \(n) deliveries via access rules from aprs_0") }
    }

    /// Android keys the station by Java's String.hashCode, masked to 32 bits; the same here so
    /// a database moved between the apps keeps one id per station.
    static func aprsNodeId(_ source: String) -> Int64 {
        var hash: Int32 = 0
        for unit in source.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return Int64(hash) & 0xFFFF_FFFF
    }

    /// deliverToTransport's aprs branch: "@CALL text" is a directed message with ack tracking,
    /// anything else a BLN1 bulletin.
    func deliverToAprs(textPreview: String) async -> String? {
        let parts = aprs.state
        guard parts.isClient?.isConnected == true || parts.kiss?.isConnected == true else { return "aprs not connected" }
        let full = aprsFullCallsign()
        if let directed = AprsCodec.directedMessage(textPreview) {
            var text = "[APRS:\(full)\u{2192}\(directed.to)] \(directed.text)"
            if let tracker = parts.tracker {
                let msgId = tracker.send(to: directed.to, text: directed.text)
                text += " {\(msgId)}"
            } else {
                await aprsTransmit(AprsCodec.encodeMessage(to: directed.to, text: directed.text))
            }
            try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "aprs", direction: "tx", sender: "self", text: text, forwarded: true,
                    forwardedTo: "aprs:\(directed.to)"))
            return nil
        }
        await aprsTransmit(AprsCodec.encodeMessage(to: "BLN1", text: String(textPreview.prefix(AprsCodec.maxMessageLength))))
        try? await db.messages.insert(
            MessageRecord(
                timestamp: clock.nowMs(), transport: "aprs", direction: "tx", sender: "self", text: textPreview, forwarded: true,
                forwardedTo: "aprs:rf"))
        return nil
    }
}
