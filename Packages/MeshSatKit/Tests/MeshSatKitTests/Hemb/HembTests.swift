// Mirrors HembFrameTest.kt, HembCodecTest.kt, HembBridgeInteropTest.kt and HembBonderTest.kt.
// The Bridge-produced byte arrays are the reference (MESHSAT-1163, MESHSAT-1264).
import XCTest

@testable import MeshSatHemb

final class HembFrameTests: XCTestCase {
    func testCrc8() {
        let data: [UInt8] = [0x48, 0x4D, 0x00, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(HembFrame.crc8(data), HembFrame.crc8(data))
        var flipped = data
        flipped[3] ^= 0x01
        XCTAssertNotEqual(HembFrame.crc8(data), HembFrame.crc8(flipped))
        XCTAssertEqual(HembFrame.crc8([]), 0)
    }

    func testMarshalExtendedProducesValidFrame() {
        let sym = HembCodedSymbol(genId: 42, symbolIndex: 0, k: 2, coefficients: [0x01, 0x02], data: [0xAA, 0xBB])
        let frame = HembFrame.marshalExtended(streamId: 1, sym: sym, bearerIndex: 0, totalN: 3)
        XCTAssertEqual(Array(frame.prefix(2)), [HembFrame.magic0, HembFrame.magic1])
        XCTAssertTrue(HembFrame.isHembFrame(frame))
        XCTAssertEqual(frame.count, HembFrame.extendedHeaderLen + 2 + 2)
    }

    func testParseSymbolRoundTripsExtendedFrame() throws {
        let sym = HembCodedSymbol(genId: 7, symbolIndex: 0, k: 3, coefficients: [0x11, 0x22, 0x33], data: [0xDE, 0xAD, 0xBE, 0xEF])
        let parsed = try XCTUnwrap(HembFrame.parseSymbol(HembFrame.marshalExtended(streamId: 5, sym: sym, bearerIndex: 2, totalN: 4)))
        XCTAssertEqual(parsed.bearerIndex, 2)
        XCTAssertEqual(parsed.symbol, sym)
        XCTAssertEqual(parsed.streamId, 5)
        XCTAssertEqual(parsed.n, 4)
        XCTAssertEqual(parsed.headerMode, HembFrame.headerModeExtended)
    }

    func testIsHembFrame() {
        XCTAssertFalse(HembFrame.isHembFrame([0x00, 0x01, 0x02]))
        XCTAssertFalse(HembFrame.isHembFrame([]))
        var frame = [UInt8](repeating: 0, count: HembFrame.extendedHeaderLen)
        frame[0] = HembFrame.magic0
        frame[1] = HembFrame.magic1
        frame[6] = 1
        frame[7] = 1
        frame[15] = HembFrame.crc8(frame, offset: 0, length: 15)
        XCTAssertTrue(HembFrame.isHembFrame(frame))
    }

    func testInvalidCrcRejectsFrame() {
        let sym = HembCodedSymbol(genId: 0, symbolIndex: 0, k: 1, coefficients: [1], data: [2])
        var frame = HembFrame.marshalExtended(streamId: 0, sym: sym, bearerIndex: 0, totalN: 1)
        frame[15] ^= 0xFF
        XCTAssertNil(HembFrame.parseSymbol(frame))
    }

    func testHeaderOverhead() {
        XCTAssertEqual(HembFrame.headerOverhead(HembFrame.headerModeExtended), 16)
        XCTAssertEqual(HembFrame.headerOverhead(HembFrame.headerModeCompact), 8)
        XCTAssertEqual(HembFrame.headerOverhead(HembFrame.headerModeImplicit), 0)
    }

    func testPromoteHeader() throws {
        let sym = HembCodedSymbol(genId: 700, symbolIndex: 300, k: 3, coefficients: [1, 2, 3], data: [9, 9])
        let compact = HembFrame.marshalCompact(streamId: 5, sym: sym, bearerIndex: 2, totalN: 5, ttl: 9)
        let promoted = try XCTUnwrap(HembFrame.promoteHeader(compact))
        let parsed = try XCTUnwrap(HembFrame.parseSymbol(promoted))
        XCTAssertEqual(parsed.headerMode, HembFrame.headerModeExtended)
        XCTAssertEqual(parsed.symbol, sym)
        XCTAssertEqual(parsed.streamId, 5)
        XCTAssertEqual(HembFrame.promoteHeader(promoted), promoted)
        XCTAssertNil(HembFrame.promoteHeader([1, 2, 3]))
    }
}

final class HembBridgeInteropTests: XCTestCase {
    /// The Bridge's MarshalExtended: stream 5, data, sequence 7, K 3, N 5, bearer 2, generation 42.
    private let bridgeExtendedFrame: [UInt8] = [
        0x48, 0x4D, 0x14, 0x05, 0x07, 0x00, 0x03, 0x05, 0x02, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x83,
        0x01, 0x02, 0x03, 0xAA, 0xBB, 0xCC, 0xDD,
    ]
    /// The Bridge's MarshalCompact: stream 5, data, sequence 300, K 3, N 5, bearer 2, generation 700, TTL 9.
    private let bridgeCompactFrame: [UInt8] = [0x14, 0x2C, 0x03, 0x05, 0x21, 0xBC, 0x89, 0xB3, 0x01, 0x02, 0x03, 0xAA, 0xBB, 0xCC, 0xDD]

    func testBridgeExtendedFrameParsesFieldForField() throws {
        XCTAssertTrue(HembFrame.isHembFrame(bridgeExtendedFrame))
        let parsed = try XCTUnwrap(HembFrame.parseSymbol(bridgeExtendedFrame))
        XCTAssertEqual(parsed.streamId, 5)  // read 85 before MESHSAT-1163
        XCTAssertEqual(parsed.bearerIndex, 2)
        XCTAssertEqual(parsed.n, 5)
        XCTAssertEqual(parsed.flags, HembFrame.flagData)
        XCTAssertEqual(parsed.headerMode, HembFrame.headerModeExtended)
        XCTAssertEqual(
            parsed.symbol, HembCodedSymbol(genId: 42, symbolIndex: 7, k: 3, coefficients: [1, 2, 3], data: [0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func testBridgeCompactFrameParsesFieldForField() throws {
        let parsed = try XCTUnwrap(HembFrame.parseSymbol(bridgeCompactFrame))
        XCTAssertEqual(parsed.headerMode, HembFrame.headerModeCompact)
        XCTAssertEqual(parsed.streamId, 5)
        XCTAssertEqual(parsed.bearerIndex, 2)
        XCTAssertEqual(parsed.n, 5)
        XCTAssertEqual(parsed.flags, HembFrame.flagData)
        XCTAssertEqual(parsed.symbol.symbolIndex, 300)  // read 707 before MESHSAT-1264
        XCTAssertEqual(parsed.symbol.genId, 700)  // read 303 before
        XCTAssertEqual(parsed.ttl, 9)  // not read at all before
        XCTAssertEqual(parsed.symbol.k, 3)
        XCTAssertEqual(parsed.symbol.coefficients, [1, 2, 3])
    }

    func testOurHeadersGoOutOnTheBridgesBytes() throws {
        let compact = try XCTUnwrap(HembFrame.parseSymbol(bridgeCompactFrame))
        let ours = HembFrame.marshalCompact(
            streamId: compact.streamId, sym: compact.symbol, bearerIndex: compact.bearerIndex, totalN: compact.n, flags: compact.flags,
            ttl: compact.ttl)
        XCTAssertEqual(ours, bridgeCompactFrame)
        let extended = try XCTUnwrap(HembFrame.parseSymbol(bridgeExtendedFrame))
        let oursExt = HembFrame.marshalExtended(
            streamId: extended.streamId, sym: extended.symbol, bearerIndex: extended.bearerIndex, totalN: extended.n)
        XCTAssertEqual(oursExt, bridgeExtendedFrame)
    }
}

final class HembCodecTests: XCTestCase {
    func testGf256() {
        XCTAssertEqual(HembGf256.add(42, 42), 0)
        XCTAssertEqual(HembGf256.add(42, 17), 42 ^ 17)
        for a in 0...255 {
            XCTAssertEqual(HembGf256.mul(UInt8(a), 1), UInt8(a))
            XCTAssertEqual(HembGf256.mul(UInt8(a), 0), 0)
        }
        for a in 1...255 { XCTAssertEqual(HembGf256.mul(UInt8(a), HembGf256.inv(UInt8(a))), 1, "\(a)") }
        for a in 1...50 {
            for b in 1...50 { XCTAssertEqual(HembGf256.mul(UInt8(a), UInt8(b)), HembGf256.mul(UInt8(b), UInt8(a))) }
        }
        XCTAssertEqual(HembGf256.mul(HembGf256.mul(42, 17), 99), HembGf256.mul(42, HembGf256.mul(17, 99)))
        // Generator 0x03 under 0x11B: 1, 3, 5, 15, 17.
        XCTAssertEqual(Array(HembGf256.exp.prefix(5)), [1, 3, 5, 15, 17])
        for i in 0..<255 { XCTAssertEqual(HembGf256.exp[i], HembGf256.exp[i + 255]) }
    }

    func testGaussianElimination() {
        var coeffs = HembGfMatrix(rows: 3, cols: 3)
        coeffs[0, 0] = 1
        coeffs[1, 1] = 1
        coeffs[2, 2] = 1
        XCTAssertEqual(hembGaussianEliminate(coeffs, payloads: [[10, 20], [30, 40], [50, 60]]), [[10, 20], [30, 40], [50, 60]])
        var deficient = HembGfMatrix(rows: 2, cols: 3)
        for (i, v) in [1, 2, 3].enumerated() {
            deficient[0, i] = UInt8(v)
            deficient[1, i] = UInt8(v)
        }
        XCTAssertNil(hembGaussianEliminate(deficient, payloads: [[1], [1]]))
        XCTAssertEqual(hembComputeRank([[1, 0, 0], [0, 1, 0], [0, 0, 1]], k: 3), 3)
        XCTAssertEqual(hembComputeRank([[1, 2, 3], [1, 2, 3], [4, 5, 6]], k: 3), 2)
    }

    /// Fresh coefficients until the first K symbols are mutually innovative, as the Bridge's
    /// tests pre-flight (about one draw in 256 is rank-deficient at K=3, MESHSAT-1269).
    static func encodeInnovative(_ genId: Int, _ segments: [[UInt8]], n: Int, attempts: Int = 10) throws -> [HembCodedSymbol] {
        let k = segments.count
        for _ in 0..<attempts {
            let symbols = try HembRlncEncoder.encode(genId: genId, segments: segments, n: n)
            let probe = HembRlncDecoder(k: k, symSize: segments[0].count)
            symbols.prefix(k).forEach { probe.feed($0) }
            if probe.rank == k { return symbols }
        }
        throw XCTSkip("no full-rank encoding of K=\(k) in \(attempts) attempts")
    }

    func testRlncEncodeAndDecode() throws {
        let original = Array("Hello HeMB World!".utf8)
        let segments = HembRlncEncoder.segmentPayload(original, symSize: 5)
        let k = segments.count
        let symbols = try Self.encodeInnovative(0, segments, n: k)
        XCTAssertEqual(symbols.count, k)
        let decoder = HembRlncDecoder(k: k, symSize: 5)
        symbols.forEach { decoder.feed($0) }
        XCTAssertTrue(decoder.isSolvable)
        let recovered = try XCTUnwrap(decoder.solve())
        XCTAssertEqual(Array(recovered.flatMap { $0 }.prefix(original.count)), original)
        // N greater than K: the first K suffice.
        let data = (0..<50).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        let segs = HembRlncEncoder.segmentPayload(data, symSize: 10)
        let more = try Self.encodeInnovative(42, segs, n: segs.count + 3)
        let d2 = HembRlncDecoder(k: segs.count, symSize: 10)
        more.prefix(segs.count).forEach { d2.feed($0) }
        XCTAssertEqual(Array(try XCTUnwrap(d2.solve()).flatMap { $0 }.prefix(data.count)), data)
        XCTAssertEqual(try XCTUnwrap(hembTryDecode(try Self.encodeInnovative(0, [[1, 2, 3], [4, 5, 6]], n: 3), k: 2)).count, 2)
    }

    func testRlncRankTrackingAndDuplicates() throws {
        let segments: [[UInt8]] = [[1, 2], [3, 4], [5, 6]]
        let symbols = try Self.encodeInnovative(0, segments, n: 4)
        let decoder = HembRlncDecoder(k: 3, symSize: 2)
        XCTAssertEqual(decoder.rank, 0)
        for (i, sym) in symbols.prefix(3).enumerated() {
            decoder.feed(sym)
            XCTAssertEqual(decoder.rank, i + 1)
        }
        XCTAssertTrue(decoder.isSolvable)
        let dup = try HembRlncEncoder.encode(genId: 0, segments: [[10, 20], [30, 40]], n: 3)
        let d2 = HembRlncDecoder(k: 2, symSize: 2)
        XCTAssertTrue(d2.feed(dup[0]))
        XCTAssertFalse(d2.feed(dup[0]))
        XCTAssertEqual(d2.rank, 1)
        XCTAssertThrowsError(try HembRlncEncoder.encode(genId: 0, segments: [], n: 1))
        XCTAssertThrowsError(try HembRlncEncoder.encode(genId: 0, segments: [[1]], n: 0))
        XCTAssertThrowsError(try HembRlncEncoder.encode(genId: 0, segments: [[1], [1, 2]], n: 2))
    }

    func testEncodingSurvivesADependentDraw() throws {
        let segments: [[UInt8]] = [[1, 2], [3, 4], [5, 6]]
        for _ in 0..<500 {
            let decoder = HembRlncDecoder(k: 3, symSize: 2)
            try Self.encodeInnovative(0, segments, n: 3).prefix(3).forEach { decoder.feed($0) }
            XCTAssertEqual(decoder.rank, 3)
        }
    }

    func testReassemblyBuffer() throws {
        let symbols = try Self.encodeInnovative(0, [[1, 2, 3], [4, 5, 6]], n: 3)
        let delivered = AprsReceived<[UInt8]>()
        let buf = HembReassemblyBuffer(deliverFn: { delivered.add($0) })
        XCTAssertNil(buf.addSymbol(streamId: 0, bearerIndex: 0, symbols[0]))
        XCTAssertEqual(delivered.all.count, 0)
        XCTAssertEqual(buf.activeStreamCount, 1)
        XCTAssertEqual(buf.addSymbol(streamId: 0, bearerIndex: 1, symbols[1]), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(delivered.all, [[1, 2, 3, 4, 5, 6]])
        // A decoded generation is freed, as the Bridge does: K=1 decodes again on the same ids.
        let single = try HembRlncEncoder.encode(genId: 0, segments: [[10]], n: 2)
        let buf2 = HembReassemblyBuffer()
        XCTAssertNotNil(buf2.addSymbol(streamId: 0, bearerIndex: 0, single[0]))
        XCTAssertEqual(buf2.activeStreamCount, 0)
        XCTAssertNotNil(buf2.addSymbol(streamId: 0, bearerIndex: 1, single[1]))
    }

    func testReassemblyReap() throws {
        let clock = TestClock()
        clock.now = 1_000
        let events = AprsReceived<HembEvent>()
        let buf = HembReassemblyBuffer(eventListener: { events.add($0) }, now: { clock.now })
        let sym = try HembRlncEncoder.encode(genId: 0, segments: [[1], [2]], n: 3)[0]
        buf.addSymbol(streamId: 0, bearerIndex: 0, sym)
        XCTAssertEqual(buf.activeStreamCount, 1)
        XCTAssertEqual(buf.reap(maxAgeMs: 0), 0, "not older than 0 ms yet")
        clock.now += 1
        XCTAssertEqual(buf.reap(maxAgeMs: 0), 1)
        XCTAssertEqual(buf.activeStreamCount, 0)
        XCTAssertEqual(events.all.map(\.type), [.generationFailed])
    }

    func testProfiles() {
        func bearer(_ type: String, loss: Double, cost: Double = 0) -> HembBearerProfile {
            HembBearerProfile(
                index: 0, interfaceId: "\(type)_0", channelType: type, mtu: 237, costPerMsg: cost, lossRate: loss, sendFn: { _ in })
        }
        XCTAssertGreaterThanOrEqual(HembProfiles.selectRedundancy([bearer("tcp", loss: 0)]), 1.0)
        XCTAssertEqual(HembProfiles.selectRedundancy([]), 1.0)
        let mesh = [bearer("mesh", loss: 0.10)]
        XCTAssertGreaterThan(HembProfiles.selectRedundancy(mesh, priority: 0), HembProfiles.selectRedundancy(mesh, priority: 2))
        XCTAssertLessThanOrEqual(
            HembProfiles.selectRedundancy([bearer("iridium_sbd", loss: 0.01, cost: 0.05)]),
            HembProfiles.selectRedundancy([bearer("mesh", loss: 0.01)]))
        XCTAssertEqual(HembProfiles.repairSymbols(bearer("iridium_sbd", loss: 0.5, cost: 0.05), sourceCount: 10), 1)
        XCTAssertEqual(HembProfiles.repairSymbols(bearer("mesh", loss: 0.3), sourceCount: 0), 0)
        XCTAssertEqual(HembProfiles.repairSymbols(bearer("mesh", loss: 0.3), sourceCount: 10), 5)
        XCTAssertEqual(HembProfiles.bearerRedundancy(bearer("mesh", loss: 0)), 1.30)
        XCTAssertEqual(HembProfiles.bearerRedundancy(bearer("iridium_sbd", loss: 0, cost: 0.05)), 1.00)
        XCTAssertEqual(HembProfiles.bearerRedundancy(bearer("unknown", loss: 0, cost: 0.05)), 1.05)
    }

    func testBearerSelector() {
        let selector = BearerSelector()
        var ble = BearerSelector.bleDefaults()
        ble.onlineFn = { true }
        ble.healthFn = { 80 }
        ble.sendFn = { _ in }
        var sms = BearerSelector.smsDefaults()
        sms.onlineFn = { false }
        sms.healthFn = { 90 }
        selector.register(ble)
        selector.register(sms)
        let active = selector.activeBearers()
        XCTAssertEqual(active.map(\.interfaceId), ["ble_0"])
        XCTAssertEqual(active[0].healthScore, 80)
        XCTAssertEqual(selector.registeredIds(), ["ble_0", "sms_0"])
        XCTAssertEqual(selector.onlineCount, 1)
        var dead = BearerSelector.bleDefaults()
        dead.onlineFn = { true }
        selector.register(dead)
        XCTAssertEqual(selector.activeBearers().count, 0)
        selector.unregister("sms_0")
        XCTAssertEqual(selector.registeredIds(), ["ble_0"])
    }

    func testQrPayloadParse() throws {
        var buf: [UInt8] = [1] + (0..<16).map { UInt8($0) }
        let label = Array("test-bond".utf8)
        buf += [UInt8(label.count)] + label + [2]
        for m in ["ble_0", "sms_0"] { buf += [UInt8(m.utf8.count)] + Array(m.utf8) }
        let bits = (1.50).bitPattern
        buf += (0..<8).map { UInt8((bits >> (8 * (7 - UInt64($0)))) & 0xFF) }
        let config = try XCTUnwrap(HembBondGroupManager.parseQrPayload(buf))
        XCTAssertEqual(config.label, "test-bond")
        XCTAssertEqual(config.members, ["ble_0", "sms_0"])
        XCTAssertEqual(config.costBudget, 1.5, accuracy: 0.001)
        XCTAssertEqual(config.id, "000102030405060708090a0b0c0d0e0f")
        XCTAssertNil(HembBondGroupManager.parseQrPayload([99]))
        XCTAssertNil(HembBondGroupManager.parseQrPayload([]))
        let url =
            HembBondGroupManager.qrPrefix
            + Data(buf).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(HembBondGroupManager.parseQrUrl(url), config)
        XCTAssertNil(HembBondGroupManager.parseQrUrl("meshsat://provision/x"))
        let hub = try XCTUnwrap(
            HembBondGroupManager.parseHubCreate("{\"bond_id\":\"b1\",\"label\":\"L\",\"members\":[\"mesh_0\"],\"cost_budget\":2.5}"))
        XCTAssertEqual(hub, HembConfig(id: "b1", label: "L", members: ["mesh_0"], costBudget: 2.5))
        XCTAssertNil(HembBondGroupManager.parseHubCreate("{\"label\":\"no id\"}"))
    }

    func testEndToEndEncodeFrameReassemble() throws {
        let payload = Array("End-to-end HeMB test payload for bonded delivery!".utf8)
        let segments = HembRlncEncoder.segmentPayload(payload, symSize: 10)
        let n = segments.count + 2
        let symbols = try HembRlncEncoder.encode(genId: 0, segments: segments, n: n)
        let frames = symbols.enumerated().map { i, sym in HembFrame.marshalExtended(streamId: 1, sym: sym, bearerIndex: i % 3, totalN: n) }
        let delivered = AprsReceived<[UInt8]>()
        let buf = HembReassemblyBuffer(deliverFn: { delivered.add($0) })
        for frame in frames {
            XCTAssertTrue(HembFrame.isHembFrame(frame))
            if let result = buf.addFrame(frame) {
                XCTAssertEqual(Array(result.prefix(payload.count)), payload)
                break
            }
        }
        XCTAssertEqual(delivered.all.count, 1, "should have decoded")
    }

    func testBondStatsDefaults() {
        let stats = HembBondStats()
        XCTAssertEqual(stats.activeStreams, 0)
        XCTAssertEqual(stats.symbolsSent, 0)
        XCTAssertEqual(stats.costIncurred, 0)
    }
}

final class HembBonderTests: XCTestCase {
    func testSingleBearerPassthrough() async throws {
        let captured = AprsReceived<[UInt8]>()
        let bearer = HembBearerProfile(index: 0, interfaceId: "mesh_0", channelType: "mesh", mtu: 237, sendFn: { captured.add($0) })
        let bonder = HembBonder(bearers: [bearer])
        try await bonder.send(Array("hello hemb".utf8))
        XCTAssertEqual(captured.all, [Array("hello hemb".utf8)])
        XCTAssertEqual(bonder.stats().symbolsSent, 1)
        XCTAssertEqual(bonder.stats().bytesFree, 10)
        XCTAssertEqual(bonder.receiveSymbol(bearerIndex: 0, [1, 2]), [1, 2])
    }

    func testMultiBearerRoundTrip() async throws {
        let frames = AprsReceived<[UInt8]>()
        let bearers = [
            HembBearerProfile(index: 0, interfaceId: "mesh_0", channelType: "mesh", mtu: 237, sendFn: { frames.add($0) }),
            HembBearerProfile(index: 1, interfaceId: "tcp_0", channelType: "tcp", mtu: 1400, sendFn: { frames.add($0) }),
        ]
        let bonder = HembBonder(bearers: bearers)
        let payload = (0..<500).map { UInt8($0 % 256) }
        try await bonder.send(payload)
        XCTAssertFalse(frames.all.isEmpty)
        for frame in frames.all { XCTAssertTrue(HembFrame.isHembFrame(frame)) }
        let delivered = AprsReceived<[UInt8]>()
        let reassembly = HembReassemblyBuffer(deliverFn: { delivered.add($0) })
        for frame in frames.all { reassembly.addFrame(frame) }
        let decoded = try XCTUnwrap(delivered.all.first, "should decode from N frames")
        XCTAssertEqual(Array(decoded.prefix(payload.count)), payload)
        XCTAssertEqual(bonder.stats().symbolsSent, Int64(frames.all.count))
    }

    func testFreeBearersFirst() async throws {
        let free = AprsReceived<[UInt8]>()
        let paid = AprsReceived<[UInt8]>()
        let bearers = [
            HembBearerProfile(index: 0, interfaceId: "mesh_0", channelType: "mesh", mtu: 237, costPerMsg: 0, sendFn: { free.add($0) }),
            HembBearerProfile(index: 1, interfaceId: "sbd_0", channelType: "iridium", mtu: 340, costPerMsg: 0.05, sendFn: { paid.add($0) }),
        ]
        let bonder = HembBonder(bearers: bearers)
        try await bonder.send(Array("test".utf8))
        XCTAssertFalse(free.all.isEmpty, "free bearer should receive frames")
        XCTAssertTrue(paid.all.isEmpty, "a paid bearer with no source symbols and no repair gets nothing")
        XCTAssertEqual(bonder.stats().bytesPaid, 0)
    }

    func testAllocation() {
        func bearer(_ i: Int, cost: Double, loss: Double, mtu: Int = 237) -> HembBearerProfile {
            HembBearerProfile(
                index: i, interfaceId: "b\(i)", channelType: "x", mtu: mtu, costPerMsg: cost, lossRate: loss, sendFn: { _ in })
        }
        let bonder = HembBonder(bearers: [
            bearer(0, cost: 0.05, loss: 0.5), bearer(1, cost: 0, loss: 0.2), bearer(2, cost: 0, loss: 0.1, mtu: 500),
        ])
        let allocs = bonder.allocateSymbols(bonder.bearersForTest, k: 10)
        // The biggest free bearer takes every source symbol; the other free one adds repair
        // symbols for all K; the paid one gets nothing.
        XCTAssertEqual(allocs.map(\.bearer.index), [1, 2])
        XCTAssertEqual(allocs.map(\.source), [0, 10])
        XCTAssertEqual(allocs.map(\.repair), [3, 2])
        let paidOnly = HembBonder(bearers: [bearer(0, cost: 0.05, loss: 0.5), bearer(1, cost: 0.01, loss: 0.5)])
        let pa = paidOnly.allocateSymbols(paidOnly.bearersForTest, k: 4)
        XCTAssertEqual(pa.map(\.bearer.index), [1])
        XCTAssertEqual(pa.map(\.source), [4])
        XCTAssertEqual(pa.map(\.repair), [1])
    }

    func testGenerationCleanupAfterDecode() {
        let delivered = AprsReceived<[UInt8]>()
        let buf = HembReassemblyBuffer(deliverFn: { delivered.add($0) })
        buf.addSymbol(streamId: 5, bearerIndex: 0, HembCodedSymbol(genId: 0, symbolIndex: 0, k: 1, coefficients: [1], data: [0xAA]))
        XCTAssertEqual(delivered.all.count, 1)
        XCTAssertEqual(buf.activeStreamCount, 0)
        buf.addSymbol(streamId: 5, bearerIndex: 0, HembCodedSymbol(genId: 0, symbolIndex: 0, k: 1, coefficients: [1], data: [0xBB]))
        XCTAssertEqual(delivered.all, [[0xAA], [0xBB]])
    }

    func testErrors() async {
        let none = HembBonder(bearers: [])
        do {
            try await none.send([1])
            XCTFail("no bearers")
        } catch {
            XCTAssertEqual(error as? HembBonderError, .noBearers)
        }
        let dead = HembBonder(bearers: [
            HembBearerProfile(index: 0, interfaceId: "a", channelType: "mesh", mtu: 237, healthScore: 0, sendFn: { _ in }),
            HembBearerProfile(index: 1, interfaceId: "b", channelType: "tcp", mtu: 1400, healthScore: 0, sendFn: { _ in }),
        ])
        do {
            try await dead.send([1])
            XCTFail("no healthy bearers")
        } catch {
            XCTAssertEqual(error as? HembBonderError, .noHealthyBearers)
        }
    }
}

extension HembBonder {
    var bearersForTest: [HembBearerProfile] {
        Mirror(reflecting: self).children.first { $0.label == "bearers" }?.value as? [HembBearerProfile] ?? []
    }
}
