// Mirrors ui/screens/PeersScreen.kt: the People tab, every node the MeshSat node has heard.
// Tap one for its details, to message it or to find it on the map. `onMessage` gets the node
// id as messages store mesh senders ("!xxxxxxxx"); `onShowOnMap` gets the node number.
import MeshSatMeshtastic
import SwiftUI

private enum PeerSortMode: String, CaseIterable {
    case lastSeen = "Last heard"
    case name = "Name"
    case signal = "Signal"
    case battery = "Battery"
}

private let activeMs: Int64 = 15 * 60 * 1000

public struct PeersScreen: View {
    let onConnect: () -> Void
    let onMessage: (String) -> Void
    let onShowOnMap: (UInt32) -> Void
    @Environment(GatewayModel.self) private var model
    @State private var sortMode: PeerSortMode = .lastSeen
    @State private var selected: UInt32?
    @State private var now = Int64(Date().timeIntervalSince1970 * 1000)

    public init(onConnect: @escaping () -> Void, onMessage: @escaping (String) -> Void, onShowOnMap: @escaping (UInt32) -> Void) {
        self.onConnect = onConnect
        self.onMessage = onMessage
        self.onShowOnMap = onShowOnMap
    }

    private var myNodeNum: UInt32 { model.myInfo?.myNodeNum ?? 0 }

    private var rows: [(MeshtasticProtocol.MeshNodeInfo, NodeSignal)] {
        let withSignal = model.nodes.map { ($0, nodeSignal($0, live: model.linkSignals[$0.nodeNum])) }
        switch sortMode {
        case .name:
            return withSignal.sorted {
                displayName($0.0).lowercased() < displayName($1.0).lowercased()
            }
        case .lastSeen: return withSignal.sorted { $0.0.lastHeard > $1.0.lastHeard }
        case .battery: return withSignal.sorted { batteryKey($0.0) > batteryKey($1.0) }
        // Heard directly first, strongest first; then fewest hops; not measured last.
        case .signal:
            return withSignal.sorted { a, b in
                let ka = (a.1.direct ? 0 : (a.1.hops > 0 ? 1 : 2), -(a.1.snr ?? 0), a.1.hops)
                let kb = (b.1.direct ? 0 : (b.1.hops > 0 ? 1 : 2), -(b.1.snr ?? 0), b.1.hops)
                return ka < kb
            }
        }
    }

    private func displayName(_ n: MeshtasticProtocol.MeshNodeInfo) -> String {
        n.longName.isEmpty ? (n.shortName.isEmpty ? MeshtasticProtocol.formatNodeId(n.nodeNum) : n.shortName) : n.longName
    }

    private func batteryKey(_ n: MeshtasticProtocol.MeshNodeInfo) -> Int { n.batteryLevel < 0 ? -1 : n.batteryLevel }

    public var body: some View {
        let nodes = model.nodes
        let meshUp = model.meshState == .connected
        let activeCount = nodes.filter { $0.nodeNum != myNodeNum && $0.lastHeard > 0 && now - $0.lastHeard < activeMs }.count
        VStack(alignment: .leading, spacing: 0) {
            Text("People").msText(.headlineMedium).padding(.bottom, 4)
            // Your own node is in the list but is not someone you heard.
            Text("\(Words.count(nodes.filter { $0.nodeNum != myNodeNum }.count, "node")) heard, \(activeCount) in the last 15 min")
                .msText(.bodyMedium, color: MSColors.textSecondary).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Cards handed over face to face, above the nodes: a person you swapped cards with is
                    // someone you know, a node you heard is not (MESHSAT-566, 575).
                    ContactCardsSection()
                    if nodes.isEmpty {
                        emptyState(meshUp)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Text("Sort by").msText(.bodySmall, color: MSColors.textMuted)
                                ForEach(PeerSortMode.allCases, id: \.self) { mode in
                                    MSFilterChip(mode.rawValue, selected: sortMode == mode, selectedLabel: MSColors.textPrimary) {
                                        sortMode = mode
                                    }
                                    .frame(minHeight: MSSpace.touch)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                        HStack(spacing: 0) {
                            columnName("Node", 0.44)
                            columnName("Signal", 0.18)
                            columnName("Battery", 0.16)
                            columnName("Last heard", 0.22)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            MSColors.surface,
                            in: UnevenRoundedRectangle(
                                topLeadingRadius: MSRadius.card, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                topTrailingRadius: MSRadius.card)
                        )
                        .overlay(
                            UnevenRoundedRectangle(
                                topLeadingRadius: MSRadius.card, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                topTrailingRadius: MSRadius.card
                            ).stroke(MSColors.border, lineWidth: 1))
                        ForEach(rows, id: \.0.nodeNum) { node, signal in
                            PeerRow(node: node, signal: signal, isMe: node.nodeNum == myNodeNum, now: now) { selected = node.nodeNum }
                        }
                    }
                }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        // "Last heard" and the active count move with the clock, not only with new packets.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                now = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }
        .overlay {
            if let num = selected, let node = nodes.first(where: { $0.nodeNum == num }) {
                let isMe = node.nodeNum == myNodeNum
                NodeDetailSheet(
                    node: node, live: model.linkSignals[node.nodeNum], isMe: isMe,
                    onMessage: isMe
                        ? nil
                        : {
                            selected = nil
                            onMessage(MeshtasticProtocol.formatNodeId(node.nodeNum))
                        },
                    onShowOnMap: {
                        selected = nil
                        onShowOnMap(node.nodeNum)
                    },
                    onDismiss: { selected = nil })
            }
        }
    }

    private func columnName(_ text: String, _ weight: CGFloat) -> some View {
        Text(text).msText(.labelSmall, color: MSColors.textMuted).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(weight)
    }

    // Silence is not evidence of an empty mesh: a node only shows up once it transmits.
    private func emptyState(_ meshUp: Bool) -> some View {
        VStack(spacing: 12) {
            Text(meshUp ? "Your node is listening." : "Nobody heard yet.").msText(.titleMedium)
            Text(
                meshUp
                    ? "People appear here as soon as they transmit on the mesh."
                    : "People appear here when your MeshSat node hears them on the mesh."
            )
            .msText(.bodyMedium, color: MSColors.textSecondary).multilineTextAlignment(.center)
            if !meshUp { MSFilledButton("Connect your node", fullWidth: false, action: onConnect) }
        }
        .padding(.horizontal, 32)
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }
}

/// Column widths as Android's weights 0.44 / 0.18 / 0.16 / 0.22 of the row.
private struct PeerRow: View {
    let node: MeshtasticProtocol.MeshNodeInfo
    let signal: NodeSignal
    let isMe: Bool
    let now: Int64
    let onClick: () -> Void

    var body: some View {
        let elapsed = node.lastHeard > 0 ? now - node.lastHeard : Int64.max
        let statusColor: Color = isMe ? MSColors.textPrimary : (elapsed < activeMs ? MSColors.green : MSColors.textMuted)
        let name = node.longName.isEmpty ? node.shortName : node.longName
        let nodeId = MeshtasticProtocol.formatNodeId(node.nodeNum)
        let batteryColor: Color =
            node.batteryLevel < 0
            ? MSColors.textMuted : (node.batteryLevel > 100 ? MSColors.green : (node.batteryLevel <= 20 ? MSColors.amber : MSColors.green))
        Button(action: onClick) {
            GeometryReader { g in
                let w = g.size.width - 24
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            if !name.isEmpty || isMe {
                                Text(isMe ? "\(name.isEmpty ? "Your node" : name) (you)" : name).msText(.bodyMedium).lineLimit(1)
                            }
                            Text(nodeId).msText(.bodySmall, mono: true, color: MSColors.textMuted)
                        }
                    }
                    .frame(width: w * 0.44, alignment: .leading)
                    // Signal: SNR when heard directly, the hop count when relayed.
                    Text(isMe ? "-" : signal.short)
                        .msText(
                            .bodySmall, mono: signal.direct && !isMe,
                            color: signal.direct && !isMe ? MSColors.textPrimary : MSColors.textMuted
                        )
                        .frame(width: w * 0.18, alignment: .leading)
                    Text(NodeBattery.cell(node.batteryLevel)).msText(.bodySmall, mono: true, color: batteryColor)
                        .frame(width: w * 0.16, alignment: .leading)
                    Text(isMe ? "-" : Words.ago(node.lastHeard, nowMs: now)).msText(.bodySmall, color: statusColor)
                        .frame(width: w * 0.22, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .frame(height: g.size.height)
            }
            .frame(minHeight: 56)
            .background(MSColors.surface)
            .overlay(Rectangle().stroke(MSColors.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
