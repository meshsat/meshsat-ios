// Mirrors ui/components/NodeDetailSheet.kt (MESHSAT-1249): how our radio hears a node, and a
// node's details with what can be done with it: message it, or find it on the map.
import MeshSatEngine
import MeshSatMeshtastic
import SwiftUI

/// SNR is only quoted for a node heard directly: on a relayed packet it is the relay's signal,
/// not the node's, so a relayed node shows its hop count.
struct NodeSignal: Equatable {
    /// For a narrow column: "6.5 dB", "2 hops" or "-".
    let short: String
    /// A sentence for the detail sheet.
    let long: String
    let direct: Bool
    let snr: Float?
    /// 0 heard directly, more is relayed, -1 not known.
    let hops: Int
}

/// `live` is the last over-the-air packet (the radio's linkSignals); `node` is the radio's node list.
func nodeSignal(_ node: MeshtasticProtocol.MeshNodeInfo, live: MeshtasticProtocol.MeshLinkSignal?) -> NodeSignal {
    func direct(_ snr: Float, _ rssi: Int, _ measured: String) -> NodeSignal {
        var long = String(format: "Heard directly. SNR %.1f dB", snr)
        if rssi != 0 { long += ", RSSI \(rssi) dBm" }
        long += measured
        return NodeSignal(short: String(format: "%.1f dB", snr), long: long, direct: true, snr: snr, hops: 0)
    }
    func relayed(_ hops: Int) -> NodeSignal {
        NodeSignal(
            short: Words.count(hops, "hop"), long: "Heard through other nodes, \(Words.count(hops, "hop")) away.", direct: false, snr: nil,
            hops: hops)
    }
    if let live, live.hopsAway == 0 { return direct(live.snr, live.rssi, ".") }
    if let live, live.hopsAway > 0 { return relayed(live.hopsAway) }
    if node.hopsAway == 0, node.snr != 0 { return direct(node.snr, 0, ", as your node last measured it.") }
    if node.hopsAway > 0 { return relayed(node.hopsAway) }
    return NodeSignal(
        short: "-", long: "Not measured yet. Your node measures it when it hears this node transmit.", direct: false, snr: nil, hops: -1)
}

/// Pass nil for an action that does not apply (there is no messaging your own node).
struct NodeDetailSheet: View {
    let node: MeshtasticProtocol.MeshNodeInfo
    let live: MeshtasticProtocol.MeshLinkSignal?
    let isMe: Bool
    let onMessage: (() -> Void)?
    let onShowOnMap: (() -> Void)?
    let onDismiss: () -> Void
    @Environment(GatewayModel.self) private var model
    @State private var position: NodePosition?

    var body: some View {
        let id = MeshtasticProtocol.formatNodeId(node.nodeNum)
        let signal = nodeSignal(node, live: live)
        MSModalBottomSheet(onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((node.longName.isEmpty ? id : node.longName) + (isMe ? " (your node)" : "")).msText(.titleLarge)
                    Text([node.shortName, id].filter { !$0.isEmpty }.joined(separator: "  ")).msText(
                        .bodyMedium, mono: true, color: MSColors.textMuted)
                }
                if !isMe { DetailRow("Last heard", Words.ago(node.lastHeard)) }
                DetailRow(
                    "Battery", NodeBattery.describe(level: node.batteryLevel, voltage: 0, hoursLeft: nil) ?? "Not reported",
                    mono: (0...100).contains(node.batteryLevel))
                if !isMe { DetailRow("Signal", signal.long) }
                if node.hwModel != 0 { DetailRow("Hardware", MeshtasticProtocol.hardwareName(node.hwModel)) }
                DetailRow(
                    "Position",
                    position.map { String(format: "%.5f, %.5f, ", $0.latitude, $0.longitude) + Words.ago($0.timestamp) }
                        ?? "Not shared yet. It appears once the node sends its position.",
                    mono: position != nil)
                HStack(spacing: 12) {
                    if let onMessage { MSFilledButton("Message", action: onMessage) }
                    if let onShowOnMap { MSOutlinedButton("Show on map", enabled: position != nil, action: onShowOnMap) }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task(id: node.nodeNum) {
            do {
                for try await rows in model.gateway.db.nodePositions.getByNode(Int64(node.nodeNum), limit: 1) { position = rows.first }
            } catch {}
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    let mono: Bool
    init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label).msText(.bodyMedium, color: MSColors.textMuted).frame(width: 96, alignment: .leading)
            Text(value).msText(.bodyMedium, mono: mono, color: MSColors.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
