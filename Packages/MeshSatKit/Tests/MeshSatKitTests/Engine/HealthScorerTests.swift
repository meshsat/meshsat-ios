// The composite formula of health_score.go, and the store's numbers turned into a score.
import MeshSatEngine
import XCTest

private struct FakeHealthStore: HealthStore {
    var signal: Int?
    var sent = 0
    var failed = 0
    var latency: Int64 = 0
    func latestSignal(source: String) async throws -> Int? { signal }
    func countSentSince(channel: String, since: Int64) async throws -> Int { sent }
    func countFailedSince(channel: String, since: Int64) async throws -> Int { failed }
    func avgLatencyMsSince(channel: String, since: Int64) async throws -> Int64 { latency }
}

private func status(_ id: String, _ type: String, _ state: InterfaceState) -> InterfaceStatus {
    InterfaceStatus(id: id, channelType: type, state: state)
}

final class HealthScorerTests: XCTestCase {
    func testAnInterfaceThatIsNotOnlineScoresZero() async {
        let scorer = HealthScorer(statuses: { [status("mesh_0", "mesh", .offline)] }, store: FakeHealthStore(signal: 5, sent: 10))
        let s = await scorer.score("mesh_0")
        XCTAssertEqual(s.score, 0)
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.signal, 100)
    }

    func testTheWeightsOfTheBridge() async {
        // signal 3 bars = 60, 3 of 4 got through, 10 s average, iridium costs 30:
        // 60*0.3 + 75*0.3 + 90*0.2 + 30*0.2 = 18 + 22.5 + 18 + 6 = 64.5 -> 64
        let store = FakeHealthStore(signal: 3, sent: 3, failed: 1, latency: 10_000)
        let scorer = HealthScorer(statuses: { [status("iridium_0", "iridium", .online)] }, store: store)
        let s = await scorer.score("iridium_0")
        XCTAssertEqual(s.score, 64)
        XCTAssertEqual(s.costScore, 30)
        XCTAssertEqual(s.successRate, 0.75, accuracy: 1e-9)
    }

    func testNoTrafficCountsAsEverythingGotThrough() async {
        let scorer = HealthScorer(statuses: { [status("sms_0", "sms", .online)] }, store: FakeHealthStore())
        let s = await scorer.score("sms_0")
        XCTAssertEqual(s.successRate, 1)
        // 0 + 30 + 20 + 12
        XCTAssertEqual(s.score, 62)
    }

    func testCostByChannelType() {
        XCTAssertEqual(HealthScorer.channelCostScore("mesh"), 100)
        XCTAssertEqual(HealthScorer.channelCostScore("sms"), 60)
        XCTAssertEqual(HealthScorer.channelCostScore("iridium"), 30)
        XCTAssertEqual(HealthScorer.channelCostScore("aprs"), 50)
    }
}
