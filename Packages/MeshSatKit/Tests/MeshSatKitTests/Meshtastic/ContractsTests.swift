import MeshSatMeshtastic
import MeshSatNet
import MeshSatReticulum
import XCTest

final class ContractsTests: XCTestCase {
    func testPipeStatusParsing() {
        XCTAssertEqual(IridiumPipeContract.parseStatus([1, 0])?.owner, IridiumPipeContract.Owner.none)
        XCTAssertEqual(IridiumPipeContract.parseStatus([1, 1])?.owner, IridiumPipeContract.Owner.phone)
        XCTAssertEqual(IridiumPipeContract.parseStatus([1, 2])?.owner, IridiumPipeContract.Owner.node)
        XCTAssertNil(IridiumPipeContract.parseStatus([1, 9]))
        XCTAssertNil(IridiumPipeContract.parseStatus([2, 1]))
        XCTAssertNil(IridiumPipeContract.parseStatus([]))
        XCTAssertEqual(IridiumPipeContract.nodeInboundBytes, 1024)
        XCTAssertEqual(IridiumPipeContract.minChunkBytes, 20)
    }

    func testUuidsAreWellFormed() {
        let all = [
            MeshtasticBleContract.serviceUUID, MeshtasticBleContract.toRadioUUID,
            MeshtasticBleContract.fromRadioUUID, MeshtasticBleContract.fromNumUUID,
            IridiumPipeContract.serviceUUID, IridiumPipeContract.rxUUID,
            IridiumPipeContract.txUUID, IridiumPipeContract.statusUUID,
            MeshSatReticulum.BleContract.serviceUUID, MeshSatReticulum.BleContract.txUUID,
            MeshSatReticulum.BleContract.rxUUID,
        ]
        for u in all {
            XCTAssertNotNil(UUID(uuidString: u), u)
            XCTAssertEqual(u, u.lowercased())
        }
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testLoopbackStreamDeliversAndCloses() async throws {
        let (a, b) = LoopbackByteStream.pair()
        try await a.send([1, 2, 3])
        var it = b.incoming.makeAsyncIterator()
        let got = await it.next()
        XCTAssertEqual(got, [1, 2, 3])
        await a.close()
        let end = await it.next()
        XCTAssertNil(end)
        do {
            try await b.send([9])
            XCTFail("send after close should throw")
        } catch {
            XCTAssertEqual(error as? ByteStreamError, .closed)
        }
    }
}
