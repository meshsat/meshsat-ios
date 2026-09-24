// The receive half of GatewayController (GatewayService.observeTransports and the MT path):
// every frame from the node into the store and the radio state, MT messages from the modem,
// the drain when the modem sees a satellite, and the routing of what arrived.
import Foundation
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatNet
import MeshSatStore

extension GatewayController {
    // MARK: Receive paths (GatewayService.observeTransports)

    func observeTransports() {
        keep(
            Task { [self] in
                for await data in central.receivedData.subscribe() {
                    await onMeshFrame(data)
                }
            })
        // Iridium MT: once the modem is up, and on every ring alert. Never on a timer, because
        // every SBDIX is billed (MESHSAT-1236).
        keep(
            Task { [self] in
                for await state in driver.stateChanges.subscribe() where state == .connected {
                    await pollIridiumMt(ringAlert: false)
                }
            })
        keep(
            Task { [self] in
                for await _ in driver.ringAlerts.subscribe() {
                    await pollIridiumMt(ringAlert: true)
                }
            })
        // The modem sees a satellite: send what waits now instead of at its next retry, as the
        // Bridge drains its queue on a signal of at least one bar (MESHSAT-1249). Not during the
        // 3 minutes after a session that found no network.
        keep(
            Task { [self] in
                for await bars in driver.signalReadings.subscribe() where bars >= Self.iridiumMinSignalBars {
                    if await driver.sbdixHoldRemainingMs() == 0 {
                        await dispatcher?.drainNow(channelId: "iridium_0", reason: "the modem sees a satellite (\(bars)/5)")
                    }
                }
            })
    }

    func onMeshFrame(_ data: [UInt8]) async {
        guard let result = MeshtasticProtocol.parseFromRadioFull(data, nowMs: clock.nowMs()) else { return }
        let radio = central.radio
        switch result {
        case .textMessage(let msg):
            let nodeId = MeshtasticProtocol.formatNodeId(msg.from)
            central.touchNode(msg.from)
            if deduplicator.isDuplicateKey("mesh:\(msg.from):\(msg.id)") { return }
            try? await db.messages.insert(
                MessageRecord(timestamp: clock.nowMs(), transport: "mesh", direction: "rx", sender: nodeId, text: msg.text))
            messageNotifications.send((title: "Mesh: \(nodeId)", text: msg.text))
            interfaceManager.recordActivity("mesh_0")
            await evaluateAndForward(sourceInterface: "mesh_0", text: msg.text, sender: nodeId)
        case .position(let pos):
            let nodeId = MeshtasticProtocol.formatNodeId(pos.from)
            central.touchNode(pos.from)
            try? await db.nodePositions.insert(
                NodePosition(
                    timestamp: clock.nowMs(), nodeId: Int64(pos.from), nodeName: nodeId, latitude: pos.latitude, longitude: pos.longitude,
                    altitude: pos.altitude))
            geofenceMonitor.checkPosition(nodeId: nodeId, lat: pos.latitude, lon: pos.longitude)
        case .telemetry(let t):
            central.touchNode(t.from)
            // 101 is Meshtastic's "on external power", kept so it can be shown as such.
            if (0...NodeBattery.externalPower).contains(t.batteryLevel) {
                radio.updateNodeBattery(t.from, batteryLevel: t.batteryLevel)
                if t.from == radio.myInfo.value?.myNodeNum { await onOwnNodeBattery(t.from, level: t.batteryLevel, voltage: t.voltage) }
            }
        case .environmentTelemetry(let env):
            central.touchNode(env.from)
        case .myInfo(let info):
            radio.setMyInfo(info)
        case .nodeInfo(let info):
            radio.addNodeInfo(info)
            if info.nodeNum == radio.myInfo.value?.myNodeNum { radio.setOwner(longName: info.longName, shortName: info.shortName) }
        case .routing(let routing):
            await ackTracker?.processAck(channel: "mesh", seqNum: Int64(routing.requestId), positive: routing.isAck)
        case .waypoint(let wp):
            let nodeId = MeshtasticProtocol.formatNodeId(wp.from)
            try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "mesh", direction: "rx", sender: nodeId,
                    text: "\u{1F4CD} Waypoint: \(wp.name) \u{2014} \(wp.description)"))
        case .storeForward(let sf):
            if let text = sf.text {
                let nodeId = MeshtasticProtocol.formatNodeId(sf.from)
                try? await db.messages.insert(
                    MessageRecord(timestamp: clock.nowMs(), transport: "mesh", direction: "rx", sender: nodeId, text: text))
                interfaceManager.recordActivity("mesh_0")
            }
        case .detectionSensor(let ds):
            let nodeId = MeshtasticProtocol.formatNodeId(ds.from)
            try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "mesh", direction: "rx", sender: nodeId,
                    text: "\u{26A0}\u{FE0F} Sensor alert: \(ds.name)"))
        case .channel(let ch):
            radio.addChannel(ch)
        case .deviceMetadata(let md):
            radio.setDeviceMetadata(md)
        case .config(let config):
            radio.setConfig(config)
        case .neighborInfo, .traceroute, .rangeTest, .paxcounter, .reply, .configCompleteId, .unhandled:
            break
        }
    }

    /// The phone's own node reported its battery: keep a reading a minute and work out how long
    /// it has left from how fast it has actually been falling (MESHSAT-1315).
    func onOwnNodeBattery(_ nodeNum: UInt32, level: Int, voltage: Float) async {
        let source = "node_battery:" + String(format: "%08x", nodeNum)
        let nowMs = clock.nowMs()
        let store = shouldStoreBatteryReading(at: nowMs)
        if store { try? await db.signals.insert(SignalRecord(timestamp: nowMs, source: source, value: level)) }
        var readings: [NodeBattery.Reading] = []
        do {
            for try await rows in db.signals.getSince(source: source, since: nowMs - NodeBattery.windowMs) {
                readings = rows.map { NodeBattery.Reading(atMs: $0.timestamp, level: $0.value) }
                break
            }
        } catch {
            Self.log.warning("Node battery readings could not be read: \(error)")
        }
        nodeBattery.send(
            NodeBatteryNow(
                nodeNum: nodeNum, level: level, voltage: voltage, hoursLeft: NodeBattery.hoursLeft(readings, nowMs: nowMs), atMs: nowMs))
    }

    /// One stored reading a minute, whatever the node's telemetry interval.
    func shouldStoreBatteryReading(at nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if nowMs - nodeBatteryStoredMs < Self.nodeBatterySampleMs { return false }
        nodeBatteryStoredMs = nowMs
        return true
    }

    /// Fetch MT traffic. A message already in the modem's MT buffer is read for free; only a
    /// ring alert, or a gateway that reported messages waiting, is worth a billed SBDIX.
    func pollIridiumMt(ringAlert: Bool) async {
        guard let status = await driver.sbdStatus() else { return }
        if status.mtFlag, let text = await driver.readMtBuffer() {
            await storeIridiumMt(text)
            // Drop it from the modem now that it is in the database, or the next poll would
            // store it again (MESHSAT-1266).
            _ = await driver.clearMtBuffer()
        }
        if ringAlert || status.raFlag || status.msgWaiting > 0 {
            _ = await driver.sbdix(answeringRing: ringAlert || status.raFlag)
        }
    }

    /// Store an MT message and hand it to the routing rules.
    func storeIridiumMt(_ mtText: String) async {
        var imei = await driver.modemInfo.imei
        if imei.isEmpty { imei = "iridium" }
        if deduplicator.isDuplicateKey("iridium:\(imei):\(mtText.hashValue)") { return }
        try? await db.messages.insert(
            MessageRecord(timestamp: clock.nowMs(), transport: "iridium", direction: "rx", sender: imei, text: mtText))
        Self.log.info("Iridium MT stored: \(mtText.count) chars")
        messageNotifications.send((title: "Iridium: \(imei)", text: mtText))
        interfaceManager.recordActivity("iridium_0")
        await evaluateAndForward(sourceInterface: "iridium_0", text: mtText, sender: imei)
    }

    func evaluateAndForward(sourceInterface: String, text: String, sender: String) async {
        guard let disp = dispatcher else { return }
        let n = await disp.dispatchAccess(
            sourceInterface: sourceInterface, msg: RouteMessage(text: text, from: sender, portNum: 1), payload: Array(text.utf8))
        if n > 0 { Self.log.info("Dispatched \(n) deliveries via access rules from \(sourceInterface)") }
    }
}
