// Mirrors GatewayService.initHubRelay (MESHSAT-1157): the Hub relay client, a Reticulum
// interface over a WebSocket tunnel to one kit, carrying Reticulum packets as bare frames.
// Rides on the Hub Reporter's identity (bridge id and MQTT password) and needs only a target
// bridge id. Received frames go to the Reticulum transport node (MESHSAT-1326).
import Foundation
import MeshSatEngine
import MeshSatHub

extension GatewayController {
    func initHubRelay() {
        guard settings.get(SettingsKey.hubEnabled), settings.get(SettingsKey.hubRelayEnabled) else {
            Self.log.debug("Hub relay disabled in settings")
            return
        }
        let target = settings.get(SettingsKey.hubRelayTarget)
        guard !target.isEmpty else {
            Self.log.debug("Hub relay: no target bridge configured")
            return
        }
        let hubApiBase = RelayTunnel.deriveHubApiBase(
            settings.get(SettingsKey.hubUrl), explicitApiUrl: settings.get(SettingsKey.hubRelayUrl))
        var ownId = settings.get(SettingsKey.hubBridgeId)
        if ownId.isEmpty { ownId = "ios-" + String(deviceIdentifier().prefix(12)) }
        let password = settings.hubPassword
        guard !hubApiBase.isEmpty, !password.isEmpty else {
            Self.log.warning("Hub relay: Hub URL or password not configured")
            return
        }
        guard target != ownId else {
            Self.log.warning("Hub relay: target is this device, not started")
            return
        }
        let relay = RelayBridgeTransport(
            config: RelayBridgeTransport.Config(hubApiBase: hubApiBase, targetBridgeId: target, ownBridgeId: ownId, password: password),
            dialer: UrlSessionWebSocketDialer(), log: { Self.log.debug("\($0)") })
        // Wire receive before start: the transport node may not have started yet.
        relay.setReceiveCallback { [weak self] ifaceId, raw in
            self?.interfaceManager.recordActivity(ifaceId)
            self?.rnsNode?.onPacketReceived(sourceInterface: ifaceId, raw)
        }
        relay.startNow()
        setHubRelay(relay)
        keep(
            Task { [self] in
                for await state in relay.state.subscribe() {
                    switch state {
                    case .open: interfaceManager.setOnline(relay.interfaceId)
                    case .connecting: interfaceManager.setConnecting(relay.interfaceId)
                    case .refused(let code): interfaceManager.setError(relay.interfaceId, "hub refused: HTTP \(code)")
                    case .closed(let reason, let detail):
                        switch reason {
                        case .normal, .local: interfaceManager.setOffline(relay.interfaceId)
                        default: interfaceManager.setError(relay.interfaceId, "\(reason.rawValue): \(detail)")
                        }
                    }
                }
            })
        Self.log.info("Hub relay initialized: \(ownId) -> \(target) via \(hubApiBase)")
    }

    func stopHubRelay() {
        if let relay = hubRelay {
            setHubRelay(nil)
            relay.shutdown()
        }
    }
}
