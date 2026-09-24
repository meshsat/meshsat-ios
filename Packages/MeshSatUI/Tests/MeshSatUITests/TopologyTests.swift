// The mesh as it was heard: a link only from a report or a direct hearing, never from silence.
import MeshSatMeshtastic
import XCTest

@testable import MeshSatUI

final class TopologyTests: XCTestCase {
    private func node(_ num: UInt32, hops: Int = -1, snr: Float = 0, lastHeard: Int64 = 0) -> MeshtasticProtocol.MeshNodeInfo {
        var n = MeshtasticProtocol.MeshNodeInfo(nodeNum: num)
        n.hopsAway = hops
        n.snr = snr
        n.lastHeard = lastHeard
        return n
    }

    func testALinkComesFromAReportOrADirectHearingOnly() {
        let now: Int64 = 1_000_000_000
        let report = MeshtasticProtocol.NeighborReport(
            nodeId: 2, neighbors: [MeshtasticProtocol.MeshNeighbor(nodeId: 3, snr: 6.5)], broadcastIntervalSecs: 900,
            receivedAt: now - 60_000)
        let sig = MeshtasticProtocol.MeshLinkSignal(from: 2, snr: 4, rssi: -90, hopsAway: 0, heardAt: now - 1000)
        let t = Topology.build(
            nodes: [node(1), node(2), node(3), node(4, hops: 2, lastHeard: now)], myNodeNum: 1, reports: [2: report], signals: [2: sig],
            now: now)
        XCTAssertEqual(t.nodes.map(\.num), [1, 2, 3, 4])
        XCTAssertTrue(t.nodes[0].isMe)
        XCTAssertEqual(t.links.count, 2, "1-2 direct, 2-3 reported; 4 is relayed and has no link")
        XCTAssertEqual(t.hearings.filter(\.byOurRadio).map(\.heard), [2])
        XCTAssertTrue(t.links.allSatisfy(\.fresh))
    }

    func testAnOldReportIsNotFreshButStaysWithinTwiceItsInterval() {
        let now: Int64 = 1_000_000_000
        let report = MeshtasticProtocol.NeighborReport(
            nodeId: 2, neighbors: [MeshtasticProtocol.MeshNeighbor(nodeId: 3, snr: 1)], broadcastIntervalSecs: 3600,
            receivedAt: now - 5_000_000)
        let t = Topology.build(nodes: [], myNodeNum: 1, reports: [2: report], signals: [:], now: now)
        XCTAssertEqual(t.links.count, 1)
        XCTAssertTrue(t.links[0].fresh, "5000 s is inside twice a 3600 s interval")
        let old = MeshtasticProtocol.NeighborReport(
            nodeId: 2, neighbors: [MeshtasticProtocol.MeshNeighbor(nodeId: 3, snr: 1)], broadcastIntervalSecs: 60,
            receivedAt: now - 5_000_000)
        XCTAssertFalse(Topology.build(nodes: [], myNodeNum: 1, reports: [2: old], signals: [:], now: now).links[0].fresh)
    }

    func testTheLayoutPullsLinkedNodesTogetherAndKeepsEveryoneOnScreen() {
        var p = TopologyLayout.initial(4)
        let before = (p[0] - p[1]).x * (p[0] - p[1]).x + (p[0] - p[1]).y * (p[0] - p[1]).y
        for step in 0..<90 { TopologyLayout.simulate(&p, edges: [(0, 1)], temperature: 5 * (1 - Float(step) / 90)) }
        let after = (p[0] - p[1]).x * (p[0] - p[1]).x + (p[0] - p[1]).y * (p[0] - p[1]).y
        XCTAssertLessThan(after, before)
        XCTAssertTrue(p.allSatisfy { abs($0.x) <= 300 && abs($0.y) <= 300 })
    }
}
