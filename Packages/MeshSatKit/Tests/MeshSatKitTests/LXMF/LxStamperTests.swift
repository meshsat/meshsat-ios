// The stamper beyond the golden vectors (which pin the workblock and Python's and Go's stamps):
// a search that finds, and one that is cancelled.
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatRns

final class LxStamperTests: XCTestCase {
    func testASearchFindsAStampOfAtLeastTheCost() throws {
        let id = Rns.sha256(Array("a message id".utf8))
        let (stamp, value) = try XCTUnwrap(LxStamper.generateStamp(messageId: id, cost: 4))
        XCTAssertEqual(stamp.count, LxStamper.stampSize)
        XCTAssertGreaterThanOrEqual(value, 4)
        let wb = LxStamper.workblock(id)
        XCTAssertTrue(LxStamper.stampValid(workblock: wb, stamp: stamp, cost: 4))
        XCTAssertEqual(LxStamper.stampValue(workblock: wb, stamp: stamp), value)
        XCTAssertNil(LxStamper.generateStamp(messageId: id, cost: 0))
    }

    func testACancelledSearchReturnsNothing() {
        let id = Rns.sha256(Array("another id".utf8))
        XCTAssertNil(LxStamper.generateStamp(messageId: id, cost: 200, cancelled: { true }))
    }

    func testThePropagationWorkblockIsShorter() {
        let id = Rns.sha256([1])
        XCTAssertEqual(LxStamper.workblock(id, expandRounds: LxStamper.workblockExpandRoundsPN).count, 1000 * 256)
        XCTAssertEqual(Array(LxStamper.workblock(id, expandRounds: 2).prefix(256)), Array(LxStamper.workblock(id, expandRounds: 1)))
    }
}
