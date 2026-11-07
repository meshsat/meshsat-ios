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
        XCTAssertNil(IridiumPipeContract.parseStats(Self.sampleStats + [9, 9])?.beacon)
    }

    // Android's IridiumPipeStreamsTest "STATS bytes 52 to 63 carry the satellite beacon" (MESHSAT-1772).
    func testStatsBytes52To63CarryTheSatelliteBeacon() throws {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        var base: [UInt8] = [2, 2, 0x96, 3]
        for v in [UInt32(12), 7] { base.append(contentsOf: le32(v)) }
        for v in [32, 250, 2, 1] { base.append(contentsOf: le16(v)) }
        for v in [UInt32(240), 1_000, 0, 0, 5, 4, 1] { base.append(contentsOf: le32(v)) }
        base.append(contentsOf: [0, 0, 0, 0])
        XCTAssertEqual(base.count, 52)
        // A node that sends 52 bytes has no beacon fields.
        XCTAssertNil(try XCTUnwrap(IridiumPipeContract.parseStats(base)).beacon)
        func tail(_ state: UInt8, _ off: UInt8, _ msgs: Int, _ since: UInt32) -> [UInt8] {
            var t: [UInt8] = [state, off]
            t.append(contentsOf: le16(msgs))
            t.append(contentsOf: le32(since))
            t.append(contentsOf: le16(600))
            t.append(contentsOf: le16(1_800))
            return t
        }
        let on = base + tail(2, 1, 3, 580)
        XCTAssertEqual(on.count, 64)
        let s = try XCTUnwrap(IridiumPipeContract.parseStats(on))
        XCTAssertTrue(s.flags.contains(.beaconOn))
        let b = try XCTUnwrap(s.beacon)
        XCTAssertEqual(
            b,
            IridiumPipeContract.Beacon(
                state: .on, lastOff: .switchOff, messagesToModem: 3, onSinceUptimeS: 580, intervalS: 600, limitS: 1_800))
        // Uptime 1000, on since 580: 420 s in, next position in 180 s, off by itself in 1380 s.
        XCTAssertEqual(NodeStatsText.beacon(b, uptimeS: s.uptimeS), "On: next position in 3 min, off by itself in 23 min")
        let row = NodeStatsText.rows(s)[1]
        XCTAssertEqual(row.label, "Satellite beacon")
        XCTAssertEqual(row.value, "On: next position in 3 min, off by itself in 23 min")

        let never = base + tail(0, 0, 0, 0xFFFF_FFFF)
        let n = try XCTUnwrap(IridiumPipeContract.parseStats(never))
        XCTAssertEqual(n.beacon?.state, .notInUse)
        XCTAssertNil(n.beacon?.onSinceUptimeS)
        XCTAssertFalse(NodeStatsText.rows(n).contains { $0.label == "Satellite beacon" })

        func with(_ state: IridiumPipeContract.BeaconState, _ off: IridiumPipeContract.BeaconOff, _ msgs: Int) -> IridiumPipeContract.Beacon
        {
            IridiumPipeContract.Beacon(
                state: state, lastOff: off, messagesToModem: msgs, onSinceUptimeS: 580, intervalS: 600, limitS: 1_800)
        }
        XCTAssertEqual(NodeStatsText.beacon(with(.sending, .switchOff, 3), uptimeS: 0), "Off, sending its last message")
        XCTAssertEqual(
            NodeStatsText.beacon(with(.off, .limit, 3), uptimeS: 0), "Off (30 min limit), 3 messages to the modem since the node started")
        XCTAssertEqual(NodeStatsText.beacon(with(.off, .nothingSent, 0), uptimeS: 0), "Off (switched off before anything was sent)")
        XCTAssertEqual(NodeStatsText.beacon(with(.off, .notYet, 1), uptimeS: 0), "Off, 1 message to the modem since the node started")
        XCTAssertEqual(NodeStatsText.inTime(59), "in under a minute")
        XCTAssertEqual(NodeStatsText.inTime(60), "in 1 min")
        XCTAssertEqual(NodeStatsText.inTime(61), "in 2 min")
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
