// Mirrors GatewayService.buildRnode, restartRnode and the RNode card's Apply (MESHSAT-1553 P4, here
// MESHSAT-1735): the RNode interface the settings describe, started with the Reticulum node and
// restarted on Apply without a gateway restart (Android's ACTION_RESTART_RNODE).
import Foundation
import MeshSatEngine
import MeshSatRns

extension GatewayController {
    /// The RNode interface the settings describe, or nil when off, without a radio, or misconfigured.
    func buildRnode() -> RnsRnodeInterface? {
        guard settings.get(SettingsKey.rnodeEnabled) else { return nil }
        let port = settings.get(SettingsKey.rnodePort)
        guard port.hasPrefix("ble:") else {
            Self.log.info("RNode: no radio chosen, not started")
            return nil
        }
        guard
            let params = RnsRnodeInterface.params(
                preset: settings.get(SettingsKey.rnodePreset), custom: settings.get(SettingsKey.rnodeCustomParams),
                airtime: settings.get(SettingsKey.rnodeAirtimeLimits))
        else {
            Self.log.warning("RNode: custom parameters do not parse, not started")
            return nil
        }
        if let bad = params.validate() {
            Self.log.warning("RNode: \(bad), not started")
            return nil
        }
        return RnsRnodeInterface(config: RnsRnodeInterface.Config(port: port, params: params))
    }

    func initRnode() {
        guard lxmf.rnode == nil, let iface = buildRnode() else { return }
        iface.setReceiveCallback { [weak self] id, raw in self?.rnsNode?.onPacketReceived(sourceInterface: id, raw) }
        lxmf.rnode = iface
        keep(Task { await iface.start() })
        Self.log.info("RNode interface started on \(iface.config.port)")
    }

    /// The card's Apply: the running RNode stops and one from the current settings starts.
    public func restartRnode() {
        let old = lxmf.rnode
        lxmf.rnode = nil
        Task { [self] in
            await old?.stop()
            initRnode()
            Self.log.info("RNode interface \(lxmf.rnode == nil ? "off" : "restarted")")
        }
    }

    /// What the card shows of a running RNode.
    public struct RnodeState: Sendable {
        public let status: String
        public let online: Bool
        public let stats: RnodeProtocol.Stats?
    }

    /// The radio's state line and its reported values, nil when no RNode runs.
    public var rnodeState: RnodeState? {
        guard let r = lxmf.rnode else { return nil }
        return RnodeState(status: r.status, online: r.isOnline, stats: r.stats())
    }
}
