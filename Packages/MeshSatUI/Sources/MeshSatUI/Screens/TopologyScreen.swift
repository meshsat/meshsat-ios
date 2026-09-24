// Mirrors ui/screens/TopologyScreen.kt (MESHSAT-1249): how the nodes you hear are linked. The
// graph sits above the list, never inside a scroll, so pinch and drag reach it.
import MeshSatMeshtastic
import SwiftUI

public struct TopologyScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    public init() {}

    public var body: some View {
        let connected = model.meshState == .connected
        let myNodeNum = model.myInfo?.myNodeNum ?? 0
        let topology = Topology.build(
            nodes: model.nodes, myNodeNum: myNodeNum, reports: model.neighborReports, signals: model.linkSignals, now: nowMs)
        Group {
            // Silence is not an empty mesh: until another node transmits, say that it has not yet.
            if !topology.nodes.contains(where: { !$0.isMe }) {
                EmptyTopology(connected: connected)
            } else {
                GeometryReader { g in
                    let canvasHeight = min(max(g.size.height * 0.45, 200), 360)
                    VStack(spacing: 0) {
                        TopologyCanvas(topology: topology)
                            .padding(.horizontal, 16).padding(.top, 12)
                            .frame(height: canvasHeight)
                        TopologyDetails(
                            topology: topology, reportsReceived: !model.neighborReports.isEmpty, signals: model.linkSignals,
                            connected: connected, bluetoothRssi: model.bluetoothRssi, now: nowMs)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MSColors.bg)
        // Freshness moves with the clock, not only with new packets.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }
    }
}

private struct EmptyTopology: View {
    let connected: Bool
    var body: some View {
        VStack(spacing: 8) {
            Text(connected ? "Your node is listening." : "Your node is not connected.").msText(.titleMedium).multilineTextAlignment(.center)
            Text(
                connected
                    ? "Nodes appear here once they transmit on the mesh."
                    : "Connect your MeshSat node in Setup to see how the mesh is linked."
            )
            .msText(.bodyMedium, color: MSColors.textSecondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pinch to zoom, drag to move; the layout runs 90 steps of the force simulation when the set
/// of nodes or links changes.
private struct TopologyCanvas: View {
    let topology: Topology
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureScale: CGFloat = 1
    @State private var gestureOffset: CGSize = .zero
    @State private var positions: [SIMD2<Float>] = []
    @State private var layoutKey = ""

    private var ids: [UInt32] { topology.nodes.map(\.num) }
    private struct Edge {
        let i: Int
        let j: Int
        let fresh: Bool
    }
    private var edges: [Edge] {
        let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return topology.links.compactMap { l in
            guard let i = index[l.a], let j = index[l.b] else { return nil }
            return Edge(i: i, j: j, fresh: l.fresh)
        }
    }

    var body: some View {
        let key = ids.map(String.init).joined(separator: ",") + "|" + edges.map { "\($0.i)-\($0.j)" }.joined(separator: ",")
        let totalScale = scale * gestureScale
        let totalOffset = CGSize(width: offset.width + gestureOffset.width, height: offset.height + gestureOffset.height)
        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in draw(ctx, size, totalScale, totalOffset) }
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture().onChanged { v in gestureScale = v.magnification }.onEnded { v in
                        scale = min(max(scale * v.magnification, 0.5), 4)
                        gestureScale = 1
                    }
                )
                .simultaneousGesture(
                    DragGesture().onChanged { v in gestureOffset = v.translation }.onEnded { v in
                        offset = CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height)
                        gestureOffset = .zero
                    }
                )
            if scale != 1 || offset != .zero {
                MSTextButton("Reset view", color: MSColors.textSecondary) {
                    scale = 1
                    offset = .zero
                }
            }
        }
        .background(MSColors.surface, in: RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous).stroke(MSColors.border, lineWidth: 1))
        .task(id: key) {
            if layoutKey != key || positions.count != ids.count {
                layoutKey = key
                positions = TopologyLayout.initial(ids.count)
            }
            let e = edges.map { ($0.i, $0.j) }
            for step in 0..<90 {
                if Task.isCancelled { return }
                var p = positions
                TopologyLayout.simulate(&p, edges: e, temperature: 5 * (1 - Float(step) / 90))
                positions = p
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ scale: CGFloat, _ offset: CGSize) {
        let n = positions.count
        guard n > 0, n == topology.nodes.count else { return }
        // Fit the layout to the canvas, then apply the user's zoom and pan.
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for p in positions {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        let pad: CGFloat = 36
        let fit = min(
            max(min((size.width - 2 * pad) / CGFloat(max(maxX - minX, 1)), (size.height - 2 * pad) / CGFloat(max(maxY - minY, 1))), 0.2), 3)
        let mid = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        func screen(_ i: Int) -> CGPoint {
            CGPoint(
                x: size.width / 2 + offset.width + CGFloat(positions[i].x - mid.x) * fit * scale,
                y: size.height / 2 + offset.height + CGFloat(positions[i].y - mid.y) * fit * scale)
        }
        for e in edges {
            var line = Path()
            line.move(to: screen(e.i))
            line.addLine(to: screen(e.j))
            ctx.stroke(
                line, with: .color(e.fresh ? MSColors.mesh : MSColors.textMuted.opacity(0.6)),
                style: StrokeStyle(lineWidth: e.fresh ? 2 : 1.5, dash: e.fresh ? [] : [4, 4]))
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<n {
            let node = topology.nodes[i]
            let c = screen(i)
            let fresh = node.lastSeen > 0 && now - node.lastSeen < topologyFreshMs
            let color: Color = node.isMe ? MSColors.textPrimary : (fresh ? MSColors.green : MSColors.textMuted)
            let r: CGFloat = node.isMe ? 9 : 6
            if node.isMe {
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: 2 * (r + 3), height: 2 * (r + 3))),
                    with: .color(MSColors.mesh))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            ctx.draw(
                Text(node.label).font(MSFont.sans(12)).foregroundColor(node.isMe ? MSColors.textPrimary : MSColors.textSecondary),
                at: CGPoint(x: c.x, y: c.y + r + 4), anchor: .top)
        }
    }
}

private struct TopologyDetails: View {
    let topology: Topology
    let reportsReceived: Bool
    let signals: [UInt32: MeshtasticProtocol.MeshLinkSignal]
    let connected: Bool
    let bluetoothRssi: Int
    let now: Int64

    var body: some View {
        let names = Dictionary(topology.nodes.map { ($0.num, $0.isMe ? "Your node" : $0.name) }, uniquingKeysWith: { a, _ in a })
        let others = topology.nodes.filter { !$0.isMe }
        let recent = others.filter { $0.lastSeen > 0 && now - $0.lastSeen < topologyFreshMs }.count
        let directRecent = topology.hearings.filter { $0.byOurRadio && $0.fresh }
        let avgSnr: Float? = directRecent.isEmpty ? nil : directRecent.map(\.snr).reduce(0, +) / Float(directRecent.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pinch to zoom, drag to move.").msText(.bodySmall, color: MSColors.textMuted)
                HStack(spacing: 12) {
                    StatItem("Heard in 15 min", "\(recent) of \(others.count)")
                    StatItem("Links", "\(topology.links.count)")
                    StatItem("Average SNR, heard directly", avgSnr.map { String(format: "%.1f dB", $0) } ?? "-")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .msCard()
                if !reportsReceived {
                    Notice("Links appear when nodes share who they hear. This needs Neighbor Info turned on in the nodes' module settings.")
                }
                if !connected { Notice("Your node is not connected, so this is what it heard last.") }
                if !topology.hearings.isEmpty {
                    sectionTitle("Who hears whom")
                    ForEach(topology.hearings, id: \.self) { h in
                        HearingRow(
                            hearer: names[h.hearer] ?? MeshtasticProtocol.formatNodeId(h.hearer),
                            heard: names[h.heard] ?? MeshtasticProtocol.formatNodeId(h.heard), hearing: h)
                    }
                }
                sectionTitle("Nodes")
                ForEach(topology.nodes.sorted { ($0.isMe ? 0 : 1, -$0.lastSeen) < ($1.isMe ? 0 : 1, -$1.lastSeen) }, id: \.num) { node in
                    NodeRow(
                        node: node, signal: signals[node.num],
                        directSnr: topology.hearings.first { $0.byOurRadio && $0.heard == node.num }?.snr, bluetoothRssi: bluetoothRssi,
                        now: now)
                }
                Legend()
            }
            .padding(16)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).msText(.titleSmall, color: MSColors.textSecondary).padding(.top, 4)
    }
}

private struct StatItem: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).msText(.bodySmall, color: MSColors.textMuted).lineLimit(2)
            Text(value).msText(.titleSmall, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Notice: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).msText(.bodyMedium, color: MSColors.textSecondary).padding(12).frame(maxWidth: .infinity, alignment: .leading).msCard()
    }
}

private struct HearingRow: View {
    let hearer: String
    let heard: String
    let hearing: Hearing
    var body: some View {
        HStack(spacing: 12) {
            LinkSample(fresh: hearing.fresh)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(hearer) hears \(heard)").msText(.bodyMedium, color: hearing.fresh ? MSColors.textPrimary : MSColors.textSecondary)
                    .lineLimit(2)
                Text(String(format: "SNR %.1f dB, ", hearing.snr) + Words.ago(hearing.at) + (hearing.byOurRadio ? "" : ", as it reported"))
                    .msText(.bodySmall, color: MSColors.textMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: MSSpace.touch)
    }
}

private struct NodeRow: View {
    let node: TopoNode
    let signal: MeshtasticProtocol.MeshLinkSignal?
    let directSnr: Float?
    let bluetoothRssi: Int
    let now: Int64

    var body: some View {
        let fresh = node.lastSeen > 0 && now - node.lastSeen < topologyFreshMs
        let dot: Color = node.isMe ? MSColors.textPrimary : (fresh ? MSColors.green : MSColors.textMuted)
        let info = node.info
        var idLine = MeshtasticProtocol.formatNodeId(node.num)
        if let info, info.hwModel != 0 { idLine += "  " + MeshtasticProtocol.hardwareName(info.hwModel) }
        var details: [String] = []
        if node.isMe {
            if bluetoothRssi != 0 { details.append("Bluetooth to phone \(bluetoothRssi) dBm") }
        } else if let directSnr {
            details.append(String(format: "Heard directly, SNR %.1f dB", directSnr))
            if let signal, signal.hopsAway == 0, signal.rssi != 0 { details.append("RSSI \(signal.rssi) dBm") }
        } else if let signal, signal.hopsAway > 0 {
            details.append("\(Words.count(signal.hopsAway, "hop")) away")
        } else if let info, info.hopsAway > 0 {
            details.append("\(Words.count(info.hopsAway, "hop")) away")
        }
        if let info {
            if (0...100).contains(info.batteryLevel) {
                details.append("Battery \(info.batteryLevel)%")
            } else if info.batteryLevel > 100 {
                details.append("On USB power")
            }
        }
        return HStack(alignment: .top, spacing: 12) {
            Circle().fill(dot).frame(width: 10, height: 10).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.isMe ? "\(node.name) (your node)" : node.name).msText(.bodyMedium).lineLimit(1)
                Text(idLine).msText(.bodySmall, mono: true, color: MSColors.textMuted).lineLimit(1)
                if !details.isEmpty { Text(details.joined(separator: ", ")).msText(.bodySmall, color: MSColors.textSecondary) }
            }
            Spacer(minLength: 8)
            if !node.isMe {
                Text(Words.ago(node.lastSeen, nowMs: now)).msText(.bodySmall, color: fresh ? MSColors.green : MSColors.textMuted)
            }
        }
        .frame(minHeight: MSSpace.touch)
    }
}

private struct LinkSample: View {
    let fresh: Bool
    var body: some View {
        Canvas { ctx, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(
                line, with: .color(fresh ? MSColors.mesh : MSColors.textMuted.opacity(0.6)),
                style: StrokeStyle(lineWidth: 2, dash: fresh ? [] : [4, 4]))
        }
        .frame(width: 24, height: 12)
    }
}

private struct Legend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            legendDot("Your node", MSColors.textPrimary)
            legendDot("Heard in the last 15 min", MSColors.green)
            legendDot("Not heard for 15 min or more", MSColors.textMuted)
            HStack(spacing: 8) {
                LinkSample(fresh: true)
                Text("Recent link").msText(.bodySmall, color: MSColors.textSecondary)
            }
            HStack(spacing: 8) {
                LinkSample(fresh: false)
                Text("Older link").msText(.bodySmall, color: MSColors.textSecondary)
            }
            Text(
                "A line is drawn only where a node said it hears the other, or where your node heard it directly. "
                    + "A node shows up once it transmits."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.horizontal, 7)
            Text(label).msText(.bodySmall, color: MSColors.textSecondary)
        }
    }
}
