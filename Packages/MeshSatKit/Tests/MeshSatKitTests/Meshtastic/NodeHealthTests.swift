// Mirrors NodeStatsTextTest.kt and PassWindowsForNodeTest.kt: the node health card's rows and
// the pass windows the node gets over PASS (contract v2, MESHSAT-1378).
import MeshSatMeshtastic
import XCTest

final class NodeHealthTests: XCTestCase {
    private func stats(
        owner: IridiumPipeContract.Owner? = .node, flags: IridiumPipeContract.Flags = [.modemAnswers], csq: Int? = 3,
        csqAgeS: UInt32? = 300, sessions: UInt32 = 7, lastMoStatus: Int = 0, lastMomsn: Int = 266, lastMtQueued: Int = 0,
        lastSessionAgeS: UInt32? = 3600, uptimeS: UInt32 = 86_400 + 7200, watchdogReboots: UInt32 = 0,
        phoneBytesDropped: UInt32 = 0, nodeSessions: UInt32 = 0, daySessionsUsed: Int = 0, daySessionsCap: Int = 0
    ) -> IridiumPipeContract.Stats {
        IridiumPipeContract.Stats(
            version: 2, owner: owner, flags: flags, csq: csq, csqAgeS: csqAgeS, sessions: sessions, lastMoStatus: lastMoStatus,
            lastMomsn: lastMomsn, lastMtStatus: 0, lastMtQueued: lastMtQueued, lastSessionAgeS: lastSessionAgeS, uptimeS: uptimeS,
            watchdogReboots: watchdogReboots, phoneBytesDropped: phoneBytesDropped, nodeSessions: nodeSessions, nodeSent: 2,
            nodeReceived: 1, daySessionsUsed: daySessionsUsed, daySessionsCap: daySessionsCap)
    }

    func testTheRowsOfAHealthyNode() {
        let rows = NodeStatsText.rows(stats())
        XCTAssertEqual(rows.map(\.label), ["Modem", "Signal", "Sessions since boot", "Last session", "Node uptime"])
        XCTAssertEqual(rows[0].value, "Used by the node, answers")
        XCTAssertEqual(rows[1].value, "3 of 5, 5 min ago")
        XCTAssertEqual(rows[2].value, "7")
        XCTAssertEqual(rows[3].value, "MO 0, sent, MOMSN 266, 1 h ago")
        XCTAssertEqual(rows[4].value, "1 d 2 h")
        XCTAssertNil(NodeStatsText.warning(stats()))
    }

    func testTheRowsThatAppearWhenThereIsSomethingToSay() {
        let s = stats(
            owner: .phone, flags: [.modemAnswers, .sessionInFlight, .messageWaiting], lastMoStatus: 32, lastMtQueued: 2,
            watchdogReboots: 5, phoneBytesDropped: 1024, nodeSessions: 3, daySessionsUsed: 4, daySessionsCap: 12)
        let rows = NodeStatsText.rows(s)
        XCTAssertEqual(
            rows.map(\.label),
            [
                "Modem", "Session", "Signal", "Sessions since boot", "Last session", "Gateway", "Node's own routing", "Node uptime",
                "Bluetooth watchdog reboots", "Bytes the node could not take",
            ])
        XCTAssertEqual(rows[0].value, "Held by this phone, answers")
        XCTAssertEqual(rows[1].value, "In flight now")
        XCTAssertEqual(rows[4].value, "MO 32, no network service, MOMSN 266, 1 h ago")
        XCTAssertEqual(rows[5].value, "2 waiting at the gateway")
        XCTAssertEqual(rows[6].value, "4 of 12 sessions today, sent 2, received 1")
        XCTAssertEqual(rows[8].value, "5")
        XCTAssertEqual(rows[9].value, "1024")
        // The flag alone, without a count.
        let flagged = NodeStatsText.rows(stats(flags: [.modemAnswers, .messageWaiting]))
        XCTAssertEqual(flagged.first { $0.label == "Gateway" }?.value, "A message is waiting at the gateway")
    }

    func testAFreshNodeAndItsWarnings() {
        let fresh = stats(
            owner: IridiumPipeContract.Owner.none, flags: [], csq: nil, csqAgeS: nil, sessions: 0, lastMoStatus: -1,
            lastSessionAgeS: nil, uptimeS: 42)
        let rows = NodeStatsText.rows(fresh)
        XCTAssertEqual(rows[0].value, "Free, not answering")
        XCTAssertEqual(rows[1].value, "Never read")
        XCTAssertEqual(rows[3].value, "None yet")
        XCTAssertEqual(rows[4].value, "42 s")
        XCTAssertEqual(NodeStatsText.warning(fresh), "The node's modem is not answering AT commands.")
        XCTAssertEqual(
            NodeStatsText.warning(stats(flags: [.modemAnswers, .inboundCongested])),
            "The node's incoming buffer is nearly full: the phone writes faster than the modem takes.")
        XCTAssertEqual(NodeStatsText.rows(stats(owner: nil))[0].value, "Unknown owner, answers")
    }

    func testAgoAndDuration() {
        XCTAssertEqual(NodeStatsText.ago(2), "just now")
        XCTAssertEqual(NodeStatsText.ago(12), "12 s ago")
        XCTAssertEqual(NodeStatsText.ago(250), "4 min ago")
        XCTAssertEqual(NodeStatsText.ago(7300), "2 h ago")
        XCTAssertEqual(NodeStatsText.ago(3 * 86_400 + 5), "3 d ago")
        XCTAssertEqual(NodeStatsText.duration(30), "30 s")
        XCTAssertEqual(NodeStatsText.duration(45 * 60), "45 min")
        XCTAssertEqual(NodeStatsText.duration(2 * 3600 + 14 * 60), "2 h 14 min")
        XCTAssertEqual(NodeStatsText.duration(3 * 86_400 + 2 * 3600), "3 d 2 h")
    }

    private func pass(_ aos: Int64, _ los: Int64, _ elev: Double) -> PassWindowsForNode.Pass {
        PassWindowsForNode.Pass(aosUnix: aos, losUnix: los, peakElevDeg: elev)
    }

    func testPassesNotYetOverSoonestFirstAtMostEight() {
        let now: Int64 = 1_000_000
        var passes = [
            pass(now - 600, now - 100, 40),  // over
            pass(now + 3_000, now + 3_500, 12.7),  // later
            pass(now - 100, now + 300, 55),  // up now
        ]
        for i in 1...9 { passes.append(pass(now + 10_000 * Int64(i), now + 10_000 * Int64(i) + 480, 20)) }
        let windows = PassWindowsForNode.windows(passes, nowSec: now)
        XCTAssertEqual(windows.count, 8)
        XCTAssertEqual(windows[0], IridiumPipeContract.PassWindow(startEpochS: UInt32(now - 100), durationS: 400, maxElevationDeg: 55))
        XCTAssertEqual(windows[1], IridiumPipeContract.PassWindow(startEpochS: UInt32(now + 3_000), durationS: 500, maxElevationDeg: 12))
        XCTAssertEqual(windows[2].startEpochS, UInt32(now + 10_000))
        XCTAssertEqual(PassWindowsForNode.windows([], nowSec: now), [])
    }
}
