// The node's log over LogRadio (MESHSAT-1374), as MeshtasticBle.setNodeDebugLog does it: the
// flag is set through the admin channel; Settings > Advanced > Node log follows LogRadio while
// it is open.
import Foundation
import Logging
import MeshSatMeshtastic

extension GatewayController {
    /// Set `security.debug_log_api_enabled` on the node through the admin channel: the node's
    /// own security config, as it sent it, with that one flag changed, so its keys and admin
    /// keys stay as they are (a local client needs no session passkey: the firmware zeroes
    /// `from`). A setting the node keeps until it is changed again. Why it could not be sent,
    /// or nil.
    public func setNodeDebugLog(_ on: Bool) -> String? {
        guard central.state.value == .connected else { return "The node is not connected." }
        guard let me = central.radio.myInfo.value?.myNodeNum, let security = central.radio.securityConfig.value else {
            return "The node has not sent its security settings yet; try again in a moment."
        }
        central.sendToRadio(MeshtasticProtoAdapter.buildAdminSetDebugLogApi(myNodeNum: me, security: security, enabled: on))
        // The node does not echo a set: keep the copy in step so the switch shows what was asked.
        var updated = security
        updated.debugLogApiEnabled = on
        central.radio.securityConfig.send(updated)
        Self.log.info("Node debug log over Bluetooth \(on ? "on" : "off")")
        return nil
    }
}
