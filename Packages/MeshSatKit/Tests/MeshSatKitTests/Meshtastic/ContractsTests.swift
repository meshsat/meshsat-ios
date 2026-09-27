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
        XCTAssertNil(IridiumPipeContract.parseStatus([3, 1]))
        XCTAssertNil(IridiumPipeContract.parseStatus([]))
        XCTAssertNil(IridiumPipeContract.parseStatus([1]))
        XCTAssertEqual(IridiumPipeContract.nodeInboundBytes, 1024)
        XCTAssertEqual(IridiumPipeContract.minChunkBytes, 20)
        // Version 1 never carries flags; a version 2 of two bytes names its owner and no more.
        XCTAssertNil(IridiumPipeContract.parseStatus([1, 1, 0xFF, 5])?.flags)
        let short = IridiumPipeContract.parseStatus([2, 1])
        XCTAssertEqual(short?.owner, .phone)
        XCTAssertNil(short?.flags)
        XCTAssertNil(short?.csq)
    }

    /// MESHSAT-1378: `[02][owner][flags][csq]`, bit0 session, bit1 message waiting, bit2 modem
    /// answers, bit3 congested; csq 0-5 or 0xFF unknown.
    func testStatusVersion2CarriesFlagsAndSignal() {
        let s = IridiumPipeContract.parseStatus([2, 2, 0b1010, 4])
        XCTAssertEqual(s?.version, 2)
        XCTAssertEqual(s?.owner, .node)
        XCTAssertEqual(s?.flags, [.messageWaiting, .inboundCongested])
        XCTAssertEqual(s?.csq, 4)
        XCTAssertNil(IridiumPipeContract.parseStatus([2, 0, 0, 0xFF])?.csq)
        XCTAssertEqual(IridiumPipeContract.parseStatus([2, 0, 0, 0xFF])?.flags, [])
        // Longer than four: read what is there, ignore the rest.
        XCTAssertEqual(IridiumPipeContract.parseStatus([2, 1, 1, 2, 9, 9])?.csq, 2)
    }

    /// A STATS value as IRIDIUM-BLE.md lays it out, byte by byte, little-endian.
    static let sampleStats: [UInt8] = {
        var b = [UInt8](repeating: 0, count: 52)
        b[0] = 2  // version
        b[1] = 2  // owner node
        b[2] = 0b0110  // message waiting, modem answers
        b[3] = 3  // csq
        b[4...7] = [0x2C, 0x01, 0, 0]  // csqAgeS 300
        b[8...11] = [7, 0, 0, 0]  // sessions 7
        b[12...13] = [0xE0, 0xFF]  // lastMoStatus -32
        b[14...15] = [0x0A, 0x01]  // lastMomsn 266
        b[16...17] = [1, 0]  // lastMtStatus 1
        b[18...19] = [2, 0]  // lastMtQueued 2
        b[20...23] = [0x10, 0x0E, 0, 0]  // lastSessionAgeS 3600
        b[24...27] = [0x80, 0x51, 0x01, 0]  // uptimeS 86400
        b[28...31] = [5, 0, 0, 0]  // watchdogReboots 5
        b[32...35] = [0x00, 0x04, 0, 0]  // phoneBytesDropped 1024
        b[36...39] = [3, 0, 0, 0]  // nodeSessions 3
        b[40...43] = [2, 0, 0, 0]  // nodeSent 2
        b[44...47] = [1, 0, 0, 0]  // nodeReceived 1
        b[48] = 4  // daySessionsUsed
        b[49] = 12  // daySessionsCap
        return b
    }()

    func testStatsParsingByOffset() throws {
        let s = try XCTUnwrap(IridiumPipeContract.parseStats(Self.sampleStats))
        XCTAssertEqual(s.version, 2)
        XCTAssertEqual(s.owner, .node)
        XCTAssertEqual(s.flags, [.messageWaiting, .modemAnswers])
        XCTAssertEqual(s.csq, 3)
        XCTAssertEqual(s.csqAgeS, 300)
        XCTAssertEqual(s.sessions, 7)
        XCTAssertEqual(s.lastMoStatus, -32)
        XCTAssertEqual(s.lastMomsn, 266)
        XCTAssertEqual(s.lastMtStatus, 1)
        XCTAssertEqual(s.lastMtQueued, 2)
        XCTAssertEqual(s.lastSessionAgeS, 3600)
        XCTAssertEqual(s.uptimeS, 86400)
        XCTAssertEqual(s.watchdogReboots, 5)
        XCTAssertEqual(s.phoneBytesDropped, 1024)
        XCTAssertEqual(s.nodeSessions, 3)
        XCTAssertEqual(s.nodeSent, 2)
        XCTAssertEqual(s.nodeReceived, 1)
        XCTAssertEqual(s.daySessionsUsed, 4)
        XCTAssertEqual(s.daySessionsCap, 12)
        // Unknowns: 0xFF signal, 0xFFFFFFFF ages, -1 statuses before the first session.
        var fresh = [UInt8](repeating: 0, count: 52)
        fresh[0] = 2
        fresh[3] = 0xFF
        fresh[4...7] = [0xFF, 0xFF, 0xFF, 0xFF]
        fresh[12...13] = [0xFF, 0xFF]
        fresh[16...17] = [0xFF, 0xFF]
        fresh[20...23] = [0xFF, 0xFF, 0xFF, 0xFF]
        let f = try XCTUnwrap(IridiumPipeContract.parseStats(fresh))
        XCTAssertNil(f.csq)
        XCTAssertNil(f.csqAgeS)
        XCTAssertNil(f.lastSessionAgeS)
        XCTAssertEqual(f.lastMoStatus, -1)
        XCTAssertEqual(f.lastMtStatus, -1)
        XCTAssertEqual(f.owner, IridiumPipeContract.Owner.none)
        // Too short, wrong version, longer than needed.
        XCTAssertNil(IridiumPipeContract.parseStats(Array(Self.sampleStats.prefix(51))))
        var v1 = Self.sampleStats
        v1[0] = 1
        XCTAssertNil(IridiumPipeContract.parseStats(v1))
        XCTAssertEqual(IridiumPipeContract.parseStats(Self.sampleStats + [9, 9])?.daySessionsCap, 12)
    }

    func testPassListEncoding() {
        XCTAssertEqual(IridiumPipeContract.encodePassList([]), [1, 0])
        let one = IridiumPipeContract.PassWindow(startEpochS: 0x0102_0304, durationS: 0x0506, maxElevationDeg: 42)
        XCTAssertEqual(IridiumPipeContract.encodePassList([one]), [1, 1, 0x04, 0x03, 0x02, 0x01, 0x06, 0x05, 42])
        let many = (0..<12).map { IridiumPipeContract.PassWindow(startEpochS: UInt32($0), durationS: 1, maxElevationDeg: 1) }
        let encoded = IridiumPipeContract.encodePassList(many)
        XCTAssertEqual(encoded[1], 8)
        XCTAssertEqual(encoded.count, 2 + 8 * 7)
        XCTAssertEqual(encoded[2], 0)
        XCTAssertEqual(encoded[2 + 7 * 7], 7)
    }

    func testUuidsAreWellFormed() {
        let all = [
            MeshtasticBleContract.serviceUUID, MeshtasticBleContract.toRadioUUID,
            MeshtasticBleContract.fromRadioUUID, MeshtasticBleContract.fromNumUUID,
            IridiumPipeContract.serviceUUID, IridiumPipeContract.rxUUID,
            IridiumPipeContract.txUUID, IridiumPipeContract.statusUUID,
            IridiumPipeContract.statsUUID, IridiumPipeContract.passUUID, MeshtasticBleContract.logRadioUUID,
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
