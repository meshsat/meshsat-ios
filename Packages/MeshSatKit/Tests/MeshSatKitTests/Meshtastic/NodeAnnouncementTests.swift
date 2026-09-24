// Mirrors NodeAnnouncementTest.kt and NodeIdentityMergeTest.kt: a node's name, learned on the
// air (MESHSAT-1287), and the merge that keeps what a partial NodeInfo leaves out.
import MeshSatMeshtastic
import MeshSatProto
import XCTest

final class NodeAnnouncementTests: XCTestCase {
    private func announcement(from: UInt32, long: String, short: String) -> [UInt8] {
        var user = Meshtastic_User()
        user.id = "!4370c1d8"
        user.longName = long
        user.shortName = short
        var data = Meshtastic_Data()
        data.portnum = .nodeinfoApp
        data.payload = (try? user.serializedBytes()) ?? Data()
        var pkt = Meshtastic_MeshPacket()
        pkt.from = from
        pkt.to = 0xFFFF_FFFF
        pkt.decoded = data
        pkt.rxSnr = 6.5
        var fr = Meshtastic_FromRadio()
        fr.packet = pkt
        return (try? fr.serializedBytes()) ?? []
    }

    func testAnAnnouncementHeardOnTheAirCarriesTheNodesName() {
        guard
            case .nodeInfo(let info)? = MeshtasticProtocol.parseFromRadioFull(
                announcement(from: 0x4370_c1d8, long: "MeshSat tesseract", short: "TESS"))
        else {
            return XCTFail("not a node info")
        }
        XCTAssertEqual(info.nodeNum, 0x4370_c1d8)
        XCTAssertEqual(info.longName, "MeshSat tesseract")
        XCTAssertEqual(info.shortName, "TESS")
        XCTAssertEqual(info.snr, 6.5)
    }

    func testANodeNumberAbove2To31StaysPositive() {
        guard
            case .nodeInfo(let info)? = MeshtasticProtocol.parseFromRadioFull(
                announcement(from: 0xbf6e_e7bc, long: "MeshSat flaneur", short: "FLNR"))
        else {
            return XCTFail("not a node info")
        }
        XCTAssertEqual(info.nodeNum, 0xbf6e_e7bc)
    }

    func testAnAnnouncementWithNoNameInItIsNotAName() {
        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(announcement(from: 0x4370_c1d8, long: "", short: "")), .unhandled)
    }

    func testAskingWhoANodeIsSendsOurOwnNameAndWantsAnAnswer() throws {
        let bytes = MeshtasticProtoAdapter.encodeNodeInfoRequest(
            myNodeNum: 0xbf6e_e7bc, destNode: 0x4370_c1d8, longName: "MeshSat flaneur", shortName: "FLNR")
        let pkt = try Meshtastic_ToRadio(serializedBytes: bytes).packet
        XCTAssertEqual(pkt.to, 0x4370_c1d8)
        XCTAssertEqual(pkt.decoded.portnum, .nodeinfoApp)
        XCTAssertTrue(pkt.decoded.wantResponse)
        XCTAssertEqual(try Meshtastic_User(serializedBytes: pkt.decoded.payload).longName, "MeshSat flaneur")
    }

    func testOneQuestionPerNodeEveryTenMinutes() {
        let limiter = WhoIsLimiter()
        XCTAssertTrue(limiter.mayAsk(1, nowMs: 0))
        XCTAssertFalse(limiter.mayAsk(1, nowMs: 60_000))
        XCTAssertTrue(limiter.mayAsk(2, nowMs: 60_000))
        XCTAssertTrue(limiter.mayAsk(1, nowMs: WhoIsLimiter.everyMs))
    }

    // MARK: NodeIdentityMergeTest

    typealias Info = MeshtasticProtocol.MeshNodeInfo

    func testFullUpdateOverwritesAllFields() {
        let existing = Info(nodeNum: 1, longName: "OldName", shortName: "OLD", hwModel: 7, batteryLevel: 80, lastHeard: 1000)
        let info = Info(nodeNum: 1, longName: "NewName", shortName: "NEW", hwModel: 14, batteryLevel: 50, lastHeard: 2000)
        let merged = info.merged(over: existing, nowMs: 5000)
        XCTAssertEqual(merged.longName, "NewName")
        XCTAssertEqual(merged.shortName, "NEW")
        XCTAssertEqual(merged.hwModel, 14)
        XCTAssertEqual(merged.batteryLevel, 50)
        XCTAssertEqual(merged.lastHeard, 2000)
    }

    func testEmptyFieldsPreservedFromExisting() {
        let existing = Info(
            nodeNum: 1, longName: "MyNode", shortName: "MN", macaddr: "AA:BB:CC", hwModel: 7, batteryLevel: 90, lastHeard: 1000)
        let info = Info(nodeNum: 1, longName: "", shortName: "", macaddr: "", hwModel: 0, batteryLevel: -1, lastHeard: 0)
        let merged = info.merged(over: existing, nowMs: 5000)
        XCTAssertEqual(merged.longName, "MyNode")
        XCTAssertEqual(merged.shortName, "MN")
        XCTAssertEqual(merged.macaddr, "AA:BB:CC")
        XCTAssertEqual(merged.hwModel, 7)
        XCTAssertEqual(merged.batteryLevel, 90)
        XCTAssertEqual(merged.lastHeard, 5000)
    }

    func testPartialUpdateMergesCorrectly() {
        let existing = Info(nodeNum: 1, longName: "MyNode", shortName: "MN", hwModel: 7, batteryLevel: 90, lastHeard: 1000)
        let info = Info(nodeNum: 1, longName: "Updated", shortName: "", hwModel: 0, batteryLevel: 75, lastHeard: 2000)
        let merged = info.merged(over: existing, nowMs: 5000)
        XCTAssertEqual(merged.longName, "Updated")
        XCTAssertEqual(merged.shortName, "MN")
        XCTAssertEqual(merged.hwModel, 7)
        XCTAssertEqual(merged.batteryLevel, 75)
        XCTAssertEqual(merged.lastHeard, 2000)
    }

    func testNewNodeWithNoExisting() {
        let info = Info(nodeNum: 99, longName: "Brand New", shortName: "BN", hwModel: 14, batteryLevel: 100, lastHeard: 5000)
        let merged = info.merged(over: nil, nowMs: 9000)
        XCTAssertEqual(merged.longName, "Brand New")
        XCTAssertEqual(merged.shortName, "BN")
        XCTAssertEqual(merged.hwModel, 14)
        XCTAssertEqual(merged.batteryLevel, 100)
        XCTAssertEqual(merged.lastHeard, 5000)
    }

    func testTheRadioStateMergesAndTouches() {
        let state = MeshtasticRadioState(now: { 7000 })
        state.addNodeInfo(Info(nodeNum: 1, longName: "MyNode", shortName: "MN", hwModel: 7))
        state.addNodeInfo(Info(nodeNum: 1, longName: "", shortName: "", batteryLevel: 40))
        XCTAssertEqual(state.nodes.value.count, 1)
        XCTAssertEqual(state.nodes.value[0].longName, "MyNode")
        XCTAssertEqual(state.nodes.value[0].batteryLevel, 40)
        XCTAssertEqual(state.nodes.value[0].lastHeard, 7000)
        XCTAssertFalse(state.touchNode(1), "a named node needs no question")
        XCTAssertTrue(state.touchNode(2), "an unknown node does")
        state.addNodeInfo(Info(nodeNum: 3))
        XCTAssertTrue(state.touchNode(3), "a nameless node does")
    }
}
