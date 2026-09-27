// The Iridium BLE contract's version 2 additions (MESHSAT-1378), as GatewayService drives
// them: STATS is followed for the health card on the Satellite page whoever owns the modem, and
// the pass windows go to the node after every prediction so its own routing can time its
// sessions.
import Foundation
import Logging
import MeshSatMeshtastic
import MeshSatNet
import MeshSatSatellite

extension GatewayController {
    /// A node's pipe has appeared: follow STATS and hand the node the passes known now.
    func followNodeHealth(_ pipe: IridiumBlePipe) async {
        if await pipe.watchStats() { Self.log.info("Iridium pipe: following the node's satellite health (STATS)") }
        await writePassWindows()
    }

    /// Give the node the next pass windows (contract v2 PASS) whenever the prediction changes
    /// or a new link comes up: the node's own routing, while no phone holds the modem, opens
    /// routine sessions inside them. Advice only; never a signal gate. A write replaces the
    /// node's list, so an unchanged list is not written again; a node without PASS is left alone.
    func writePassWindows() async {
        guard let pipe = central.iridiumPipe.value, pipe.hasPass else { return }
        let nowSec = clock.nowMs() / 1000
        let windows = PassWindowsForNode.windows(passes.value.map(Self.passForNode), nowSec: nowSec)
        if windows == pipe.passesWritten { return }
        if await pipe.writePasses(windows) {
            pipe.passesWritten = windows
            Self.log.info("Iridium: \(windows.count) pass windows given to the node")
        }
    }

    static func passForNode(_ pass: PassPrediction) -> PassWindowsForNode.Pass {
        PassWindowsForNode.Pass(aosUnix: Int64(pass.aos.value), losUnix: Int64(pass.los.value), peakElevDeg: pass.peakElevDeg)
    }
}
