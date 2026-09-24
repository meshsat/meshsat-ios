// The gateway's InterfaceManager and Dispatcher set-up, out of the class body (swiftlint's
// 600-line limit): mirrors initInterfaceManager and initDispatcher of service/GatewayService.kt.
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatMeshtastic
import MeshSatNet
import MeshSatReticulum
import MeshSatStore
import MeshSatWire

extension GatewayController {
    func initInterfaceManager() {
        let mgr = interfaceManager
        mgr.register(InterfaceConfig(id: "mesh_0", channelType: "mesh", autoReconnect: true, initialBackoffMs: 5_000, maxBackoffMs: 60_000))
        mgr.register(
            InterfaceConfig(id: "iridium_0", channelType: "iridium", autoReconnect: true, initialBackoffMs: 10_000, maxBackoffMs: 120_000))
        // The SMS lane is the Messages composer (MESHSAT-1328); until it exists the interface is
        // disabled, so a rule to it holds its deliveries instead of dropping them.
        mgr.register(InterfaceConfig(id: "sms_0", channelType: "sms", autoReconnect: false, alwaysOnline: true))
        mgr.register(InterfaceConfig(id: "hub_0", channelType: "hub", autoReconnect: false))
        // Hub relay tunnel (MESHSAT-1157): the transport reconnects by itself, so the manager
        // only mirrors its state and never schedules a reconnect of its own.
        mgr.register(InterfaceConfig(id: RelayBridgeTransport.interfaceId, channelType: "tcp", autoReconnect: false))
        mgr.register(
            InterfaceConfig(id: "mqtt_0", channelType: "mqtt", autoReconnect: true, initialBackoffMs: 5_000, maxBackoffMs: 120_000))
        mgr.register(
            InterfaceConfig(id: "aprs_0", channelType: "aprs", autoReconnect: true, initialBackoffMs: 10_000, maxBackoffMs: 120_000))
        mgr.register(
            InterfaceConfig(id: "tcp_rns_0", channelType: "tcp", autoReconnect: true, initialBackoffMs: 5_000, maxBackoffMs: 60_000))

        mgr.setConnectCallback { [self] interfaceId in
            if interfaceId.hasPrefix("mesh") {
                // The address was saved on first connect; the central keeps the last one.
                central.reconnect()
                return nil  // async: setOnline comes from the state observer
            }
            if interfaceId == "iridium_0" {
                // The 9603 arrives with the MeshSat node's BLE link; this only allows taking it.
                iridiumWanted.send(true)
                // A modem still connected is simply online again: its state will not say
                // Connected a second time, so nothing else would restart the worker.
                if await driver.state == .connected { mgr.setOnline("iridium_0") }
                return nil
            }
            return "\(interfaceId) is not built yet"
        }
        mgr.setDisconnectCallback { [self] interfaceId in
            if interfaceId.hasPrefix("mesh") { central.disconnect() }
            if interfaceId == "iridium_0" { iridiumWanted.send(false) }
        }

        // BLE state drives the manager
        keep(
            Task { [self] in
                for await state in central.state.subscribe() {
                    switch state {
                    case .connected: mgr.setOnline("mesh_0")
                    case .disconnected: mgr.setOffline("mesh_0")
                    case .scanning, .connecting: mgr.setConnecting("mesh_0")
                    }
                }
            })
        keep(
            Task { [self] in
                for await state in driver.stateChanges.subscribe() {
                    switch state {
                    case .connected: mgr.setOnline("iridium_0")
                    case .disconnected: mgr.setOffline("iridium_0")
                    case .connecting: mgr.setConnecting("iridium_0")
                    }
                }
            })
        // Interfaces this phone has no hardware or configuration for are Disabled rather than
        // left at Offline (MESHSAT-1261).
        mgr.disable("sms_0")
        if !settings.get(SettingsKey.mqttEnabled) { mgr.disable("mqtt_0") }
        if !settings.get(SettingsKey.aprsEnabled) { mgr.disable("aprs_0") }
        if settings.get(SettingsKey.hubRelayTarget).isEmpty { mgr.disable(RelayBridgeTransport.interfaceId) }
        if !settings.get(SettingsKey.hubEnabled) { mgr.disable("hub_0") }
        if !settings.get(SettingsKey.rnsTcpEnabled) { mgr.disable("tcp_rns_0") }

        keep(
            Task { [self] in
                for await err in central.errors.subscribe() where !err.isEmpty {
                    mgr.setError("mesh_0", err)
                }
            })
        // The modem's errors never change the interface state: its link state comes from the
        // driver's state above, and most of these are refusals, not link failures.
        keep(
            Task { [self] in
                for await err in driver.errors.subscribe() where !err.isEmpty {
                    mgr.noteError("iridium_0", err)
                }
            })
    }

    func initDispatcher() {
        keep(
            Task { [self] in
                do {
                    try ChannelDefaults.register(into: registry)
                    let eval = AccessEvaluator(rules: db.accessRules, groups: db.objectGroups)
                    try await eval.reloadFromDb()
                    accessEvaluator = eval
                    let failover = FailoverResolver(store: db.failoverGroups, status: interfaceManager)
                    let disp = Dispatcher(
                        store: db.deliveries, accessEvaluator: eval, failoverResolver: failover, registry: registry,
                        deliveryCallback: { [self] interfaceId, payload, textPreview, recipient, deliveryId, sourceBearer in
                            await deliverToTransport(
                                interfaceId, payload: payload, textPreview: textPreview, recipient: recipient, deliveryId: deliveryId,
                                sourceBearer: sourceBearer)
                        },
                        sequenceTracker: sequenceTracker, clock: clock)
                    interfaceManager.setStateChangeCallback { id, type, old, new in
                        disp.onInterfaceStateChange(id, channelType: type, old: old, new: new)
                    }
                    // Iridium sends (MESHSAT-1243): mark the chat message sent, or record a
                    // rule-forwarded one.
                    disp.setOnSent { [self] del in
                        await sos?.onSent(del)
                        guard del.channel == "iridium_0" else { return }
                        if del.msgRef.hasPrefix("msg:"), let msgId = Int64(del.msgRef.dropFirst(4)) {
                            try? await db.messages.setForwardedToUnlessDelivered(id: msgId, "iridium:sbd")
                        } else {
                            try? await db.messages.insert(
                                MessageRecord(
                                    timestamp: clock.nowMs(), transport: "iridium", direction: "tx", sender: "self",
                                    recipient: Peers.satellite,
                                    text: del.textPreview, forwarded: true, forwardedTo: "iridium:sbd"))
                        }
                    }
                    // A satellite send that reported a failure after the upload may have arrived: the
                    // chat shows "May have been sent" until a retry is confirmed.
                    disp.setOnUnconfirmed { [self] del, _ in
                        if del.channel == "iridium_0", del.msgRef.hasPrefix("msg:"), let msgId = Int64(del.msgRef.dropFirst(4)) {
                            try? await db.messages.setForwardedTo(id: msgId, Self.iridiumUnconfirmed)
                        }
                    }
                    // iOS has no SMS API: sms_0 deliveries wait for the person in the Messages composer.
                    disp.setManualChannels(["sms_0"])
                    // The SOS controller's veto and follow-up (MESHSAT-1249).
                    disp.setMayDeliver { [self] del in sos?.mayDeliver(del) ?? true }
                    disp.start(interfaces: [
                        "mesh_0": "mesh", "iridium_0": "iridium", "sms_0": "sms", "hub_0": "hub", "mqtt_0": "mqtt", "aprs_0": "aprs",
                    ])
                    dispatcher = disp
                    initSos()
                    let tracker = AckTracker(store: db.deliveries, clock: clock)
                    tracker.start()
                    ackTracker = tracker
                    Self.log.info("Dispatcher initialized (\(eval.ruleCount()) access rules, ACK tracker started)")
                } catch {
                    Self.log.error("Dispatcher init failed: \(error)")
                }
            })
    }
}
