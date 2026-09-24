// Mirrors the pure part of ui/screens/TopologyScreen.kt (MESHSAT-1249): the mesh as it was
// actually heard. A link exists only where a node reported the other in a NeighborInfo packet,
// or where our own radio heard a node directly (0 hops). Nothing is inferred from silence, and
// a node with no link is shown on its own. The force layout is verbatim.
import Foundation
import MeshSatMeshtastic

/// A node or a link counts as recent when heard within this window; older ones are drawn muted.
let topologyFreshMs: Int64 = 15 * 60 * 1000

/// One measured hearing: `hearer` received `heard` at `snr` dB, known at `at`. `byOurRadio` is a
/// measurement our own radio made; otherwise `hearer` reported it in a NeighborInfo packet.
struct Hearing: Equatable, Hashable {
    let hearer: UInt32
    let heard: UInt32
    let snr: Float
    let at: Int64
    let fresh: Bool
    let byOurRadio: Bool
}

/// A link between two nodes: every hearing that shows it, in either direction.
struct TopoLink: Equatable {
    let a: UInt32
    let b: UInt32
    let hearings: [Hearing]
    var fresh: Bool { hearings.contains { $0.fresh } }
}

struct TopoNode: Equatable {
    let num: UInt32
    let label: String
    let name: String
    let isMe: Bool
    let lastSeen: Int64
    let info: MeshtasticProtocol.MeshNodeInfo?
}

struct Topology: Equatable {
    let nodes: [TopoNode]
    let links: [TopoLink]
    let hearings: [Hearing]

    static let empty = Topology(nodes: [], links: [], hearings: [])

    static func build(
        nodes: [MeshtasticProtocol.MeshNodeInfo], myNodeNum: UInt32, reports: [UInt32: MeshtasticProtocol.NeighborReport],
        signals: [UInt32: MeshtasticProtocol.MeshLinkSignal], now: Int64
    ) -> Topology {
        var hearings: [Hearing] = []
        // What the nodes themselves reported. The window follows the sender's broadcast interval,
        // which is hours, so a report is not called old just because it is from this morning.
        for report in reports.values.sorted(by: { $0.nodeId < $1.nodeId }) {
            let window = max(topologyFreshMs, 2 * Int64(report.broadcastIntervalSecs) * 1000)
            let fresh = now - report.receivedAt < window
            for n in report.neighbors where n.nodeId != report.nodeId {
                hearings.append(
                    Hearing(hearer: report.nodeId, heard: n.nodeId, snr: n.snr, at: report.receivedAt, fresh: fresh, byOurRadio: false))
            }
        }
        // What our radio heard directly: the latest over-the-air packet with 0 hops, else the
        // radio's own node list when the packets did not say.
        let byNum = Dictionary(nodes.map { ($0.nodeNum, $0) }, uniquingKeysWith: { a, _ in a })
        if myNodeNum != 0 {
            for id in Set(byNum.keys).union(signals.keys).sorted() where id != myNodeNum {
                let sig = signals[id]
                let node = byNum[id]
                if let sig, sig.hopsAway == 0 {
                    hearings.append(
                        Hearing(
                            hearer: myNodeNum, heard: id, snr: sig.snr, at: sig.heardAt, fresh: now - sig.heardAt < topologyFreshMs,
                            byOurRadio: true))
                } else if sig == nil || sig!.hopsAway < 0, let node, node.hopsAway == 0, node.lastHeard > 0 {
                    hearings.append(
                        Hearing(
                            hearer: myNodeNum, heard: id, snr: node.snr, at: node.lastHeard, fresh: now - node.lastHeard < topologyFreshMs,
                            byOurRadio: true))
                }
            }
        }
        // One row per hearer and heard node, so the list below has unique keys.
        var seen = Set<String>()
        hearings = hearings.filter { seen.insert("\($0.hearer)>\($0.heard):\($0.byOurRadio)").inserted }

        var linkMap: [String: TopoLink] = [:]
        var linkOrder: [String] = []
        for h in hearings {
            let (a, b) = h.hearer < h.heard ? (h.hearer, h.heard) : (h.heard, h.hearer)
            let key = "\(a)-\(b)"
            if let existing = linkMap[key] {
                linkMap[key] = TopoLink(a: a, b: b, hearings: existing.hearings + [h])
            } else {
                linkMap[key] = TopoLink(a: a, b: b, hearings: [h])
                linkOrder.append(key)
            }
        }
        let links = linkOrder.compactMap { linkMap[$0] }

        // Every node we know of: the node list, anything that transmitted, anything a report names.
        var ids: [UInt32] = []
        var idSet = Set<UInt32>()
        func add(_ id: UInt32) { if idSet.insert(id).inserted { ids.append(id) } }
        if myNodeNum != 0 { add(myNodeNum) }
        nodes.forEach { add($0.nodeNum) }
        signals.keys.sorted().forEach { add($0) }
        for h in hearings {
            add(h.hearer)
            add(h.heard)
        }
        // A stable order (your node, then by number), so the layout does not restart every time
        // the node list reorders itself on a NodeInfo update.
        let topoNodes = ids.sorted { ($0 != myNodeNum ? 1 : 0, $0) < ($1 != myNodeNum ? 1 : 0, $1) }.map { id -> TopoNode in
            let info = byNum[id]
            let lastSeen = max(info?.lastHeard ?? 0, max(signals[id]?.heardAt ?? 0, reports[id]?.receivedAt ?? 0))
            let short = info?.shortName ?? ""
            let long = info?.longName ?? ""
            return TopoNode(
                num: id, label: short.isEmpty ? String(MeshtasticProtocol.formatNodeId(id).suffix(4)) : short,
                name: long.isEmpty ? MeshtasticProtocol.formatNodeId(id) : long, isMe: id == myNodeNum, lastSeen: lastSeen, info: info)
        }
        return Topology(nodes: topoNodes, links: links, hearings: hearings.sorted { $0.at > $1.at })
    }
}

/// Force-directed layout: nodes push each other apart, real links pull their ends together, and
/// a weak pull to the centre keeps unlinked nodes on screen.
enum TopologyLayout {
    static func initial(_ n: Int) -> [SIMD2<Float>] {
        (0..<n).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(max(n, 1))
            return SIMD2(Float(120 * cos(angle)), Float(120 * sin(angle)))
        }
    }

    static func simulate(_ positions: inout [SIMD2<Float>], edges: [(Int, Int)], temperature: Float) {
        let n = positions.count
        if n < 2 { return }
        var forces = [SIMD2<Float>](repeating: .zero, count: n)
        let repulsionK: Float = 8000
        let springK: Float = 0.02
        let gravityK: Float = 0.01
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = positions[i] - positions[j]
                let dist = max((d.x * d.x + d.y * d.y).squareRoot(), 1)
                let f = d * (repulsionK / (dist * dist) / dist)
                forces[i] += f
                forces[j] -= f
            }
        }
        // Springs along the links that were actually heard.
        for (i, j) in edges where i >= 0 && i < n && j >= 0 && j < n && i != j {
            let d = positions[j] - positions[i]
            let dist = max((d.x * d.x + d.y * d.y).squareRoot(), 1)
            let f = d * (springK * dist / dist)
            forces[i] += f
            forces[j] -= f
        }
        for i in 0..<n {
            forces[i] -= positions[i] * gravityK
            let f = forces[i]
            let mag = max((f.x * f.x + f.y * f.y).squareRoot(), 0.001)
            let cap = min(mag, temperature * 10)
            positions[i] += f * (cap / mag)
            positions[i].x = min(max(positions[i].x, -300), 300)
            positions[i].y = min(max(positions[i].y, -300), 300)
        }
    }
}
