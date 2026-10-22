// Mirrors SatelliteChainTest.kt (MESHSAT-1623): the app's side of the kits' satellite chain beyond
// the Bridge's vectors: no key never means plaintext, sends draw fresh nonces, the limit is stated
// and enforced, an SOS goes as it is, the bytes survive the 9704's segments, and the Hub birth
// declares the chain. [MESHSAT-1624]
import Foundation
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatWire
import XCTest

@testable import MeshSatHub

/// SplitMix64: the same bytes on every run and platform, for the boundary payload.
struct SeededBytes {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 8)
        while out.count < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: z >> (8 * k))) }
        }
        return Array(out.prefix(count))
    }
}

final class SatelliteChainTests: XCTestCase {
    private let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let otherKey = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
    private let greek = Array("Καλησπέρα από το σκάφος, όλα καλά".utf8)

    private func expectRefused(_ what: String, _ block: () throws -> [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try block(), "\(what) was not refused", file: file, line: line) { error in
            XCTAssertTrue(error is TransformError, "\(what): \(error)", file: file, line: line)
        }
    }

    func testNoKeyOrOneThatIsNotAKeyIsNeverSentAsPlaintext() {
        expectRefused("no key") { try SatelliteChain.seal(self.greek, keyHex: nil) }
        expectRefused("empty key") { try SatelliteChain.seal(self.greek, keyHex: "") }
        // What the key store answers when its secret is missing: a reference, not a key.
        expectRefused("a key-store reference") { try SatelliteChain.seal(self.greek, keyHex: "convkey:shared") }
        expectRefused("a short key") { try SatelliteChain.seal(self.greek, keyHex: String(self.key.prefix(62))) }
        // Swift's isHexDigit takes fullwidth digits too; a key written in them is not a key either.
        let fullwidth = "\u{FF10}\u{FF11}" + String(key.dropFirst(2))
        expectRefused("fullwidth digits") { try SatelliteChain.seal(self.greek, keyHex: fullwidth) }
    }

    func testEverySendDrawsAFreshNonceAndBothOpen() throws {
        let a = try SatelliteChain.seal(greek, keyHex: key)
        let b = try SatelliteChain.seal(greek, keyHex: key)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(Array(a[1..<13]), Array(b[1..<13]))
        XCTAssertEqual(try SatelliteChain.open(a, keyHex: key), greek)
        XCTAssertEqual(try SatelliteChain.open(b, keyHex: key), greek)
    }

    func testTheVersionByteIsAddedOnceAndTakenOffOnce() throws {
        let wire = try SatelliteChain.seal(greek, keyHex: key)
        XCTAssertEqual(wire.first, SatelliteChain.protocolVersion)
        // Without it the wire is not the chain's; with it twice it does not open.
        expectRefused("no version byte") { try SatelliteChain.open(Array(wire.dropFirst()), keyHex: self.key) }
        expectRefused("a second version byte") { try SatelliteChain.open([SatelliteChain.protocolVersion] + wire, keyHex: self.key) }
        // A nonce that itself starts with 0x01 is not mistaken for the version byte.
        let p = TransformPipeline()
        p.fixedNonce = [0x01] + [UInt8](repeating: 0x55, count: 11)
        let w = try SatelliteChain.seal(greek, keyHex: key, pipeline: p)
        XCTAssertEqual(w[1], 0x01)
        XCTAssertEqual(try SatelliteChain.open(w, keyHex: key), greek)
    }

    func testAWrongKeyChangedOrCutBytesOrNoKeyNeverReadAsText() throws {
        let wire = try SatelliteChain.seal(Array("meet at the north gate".utf8), keyHex: key)
        var tagChanged = wire
        tagChanged[tagChanged.count - 1] ^= 1
        var cipherChanged = wire
        cipherChanged[13] ^= 1
        let cases: [String: (bytes: [UInt8], keyHex: String?)] = [
            "wrong key": (wire, otherKey),
            "no key": (wire, nil),
            "tag changed": (tagChanged, key),
            "ciphertext changed": (cipherChanged, key),
            "cut": (Array(wire.dropLast()), key),
            "version byte only": ([0x01], key),
        ]
        for (name, c) in cases {
            let mt = SatelliteChain.readMt(c.bytes, keyHex: c.keyHex)
            guard case .unopened = mt else { return XCTFail("\(name) read as \(mt)") }
        }
        // A typed text does not start with 0x01: it reads as before.
        XCTAssertEqual(SatelliteChain.readMt(Array("hello".utf8), keyHex: key), .text("hello", sealed: false))
    }

    func testOneSatelliteMessageAtMostAtTheBoundaryAndNoFurther() throws {
        XCTAssertEqual(SatelliteChain.maxWireBytes, Iridium9704Driver.imtMaxSize)
        // Bytes no table shortens go raw: wire = 30 + n.
        var rng = SeededBytes(seed: 1624)
        let most = rng.next(SatelliteChain.maxWireBytes - SatelliteChain.overhead)
        let wire = try SatelliteChain.seal(most, keyHex: key)
        XCTAssertEqual(wire.count, Iridium9704Driver.imtMaxSize)
        XCTAssertEqual(try SatelliteChain.open(wire, keyHex: key), most)
        expectRefused("one byte over") { try SatelliteChain.seal(most + [0x42], keyHex: self.key) }
    }

    func testAnSosABurstAndBinaryFramesGoAsTheyAre() {
        let text = Array("all good here".utf8)
        XCTAssertTrue(SatelliteChain.sealsDelivery(msgRef: "", payload: text))
        XCTAssertTrue(SatelliteChain.sealsDelivery(msgRef: "compose:1", payload: greek))
        XCTAssertFalse(SatelliteChain.sealsDelivery(msgRef: "sos:1761091200000:sat", payload: text))
        XCTAssertFalse(SatelliteChain.sealsDelivery(msgRef: "sos:1761091200000:cancel:sat", payload: text))
        XCTAssertFalse(SatelliteChain.sealsDelivery(msgRef: "burst:1761091200000", payload: text))
        XCTAssertFalse(SatelliteChain.sealsDelivery(msgRef: "", payload: [0x4D, 0x53, 0x07, 0xC3, 0x28]))
        // Cut in the middle of a character, or an encoded surrogate: not text either.
        XCTAssertFalse(SatelliteChain.sealsDelivery(msgRef: "", payload: Array(greek.dropLast())))
        XCTAssertFalse(SatelliteChain.sealsDelivery(msgRef: "", payload: [0x61, 0xED, 0xA0, 0x80]))
    }

    func testTheSealedBytesSurviveThe9704sBase64Segments() throws {
        let all = (0...255).map { UInt8($0) }
        let wires = [all, try SatelliteChain.seal(greek, keyHex: key), try SatelliteChain.seal(all, keyHex: key)]
        for wire in wires {
            for segment in [1, 2, 3, 7, 1446, wire.count] {
                var back: [UInt8] = []
                for start in stride(from: 0, to: wire.count, by: segment) {
                    let chunk = Array(wire[start..<min(start + segment, wire.count)])
                    back += try XCTUnwrap(Iridium9704Driver.jsprSegmentBytes(Iridium9704Driver.jsprSegmentData(chunk)))
                }
                XCTAssertEqual(back, wire, "segments of \(segment)")
            }
        }
        // A data field with a line break in it still decodes, as android.util.Base64.DEFAULT did.
        let b64 = Iridium9704Driver.jsprSegmentData(all)
        XCTAssertEqual(Iridium9704Driver.jsprSegmentBytes(String(b64.prefix(40)) + "\n" + String(b64.dropFirst(40))), all)
    }

    func testTheBridgesKeyRefChainResolvesThroughTheKeyResolver() throws {
        // The Bridge's own H chain names its key by reference (the vectors' spec.h_chain_egress).
        let chain =
            "[{\"type\":\"smaz2g\",\"params\":{\"dict\":\"meshtastic\"}},"
            + "{\"type\":\"encrypt\",\"params\":{\"key_ref\":\"iridium:shared\"}}]"
        let nonce = [UInt8](repeating: 0x07, count: 12)
        let byRef = TransformPipeline()
        byRef.fixedNonce = nonce
        let key = self.key
        byRef.keyResolver = { $0 == SatelliteChain.keyRef ? key : nil }
        let byKey = TransformPipeline()
        byKey.fixedNonce = nonce
        let expected = try SatelliteChain.seal(greek, keyHex: key, pipeline: byKey)
        XCTAssertEqual([SatelliteChain.protocolVersion] + (try byRef.applyEgress(greek, transformsJson: chain)), expected)
        XCTAssertEqual(try byRef.applyIngress(Array(expected.dropFirst()), transformsJson: chain), greek)
        // No resolver, or no key behind the reference: the step fails, it never runs without a key.
        expectRefused("no resolver") { try TransformPipeline().applyEgress(self.greek, transformsJson: chain) }
        let empty = TransformPipeline()
        empty.keyResolver = { _ in "" }
        expectRefused("no key behind the reference") { try empty.applyEgress(self.greek, transformsJson: chain) }
        XCTAssertEqual(TransformPipeline.validate(transformsJson: chain, binaryCapable: true, maxPayload: 0).errors, [])
    }

    /// The 9704 as a birth names it, as Android's iridium_imt_0.
    private func imt(_ status: String = "online", imei: String = "300000000000001", format: String = "") -> InterfaceInfo {
        InterfaceInfo(name: "iridium_imt_0", type: "iridium_imt", status: status, imei: imei, egressFormat: format)
    }

    func testTheBirthDeclaresTheChainAsTheBridgeDoes() {
        let sealed = imt(format: "sealed").toJson()
        XCTAssertEqual(sealed.string("egress_format"), "sealed")
        XCTAssertEqual(sealed["egress_sealed"], .bool(true))
        let plain = imt(format: "plain").toJson()
        XCTAssertEqual(plain.string("egress_format"), "plain")
        XCTAssertNil(plain["egress_sealed"])
        // Nothing set, or the setting not read yet: nothing declared, so the Hub keeps what it has.
        let none = imt().toJson()
        XCTAssertNil(none["egress_format"])
        XCTAssertNil(none["egress_sealed"])

        XCTAssertEqual(SatelliteChain.egressFormat(SatelliteChain.modeSealed), "sealed")
        XCTAssertEqual(SatelliteChain.egressFormat(SatelliteChain.modeLegacy), "sealed", "the rollback chain is sealed too")
        XCTAssertEqual(SatelliteChain.egressFormat(SatelliteChain.modePlain), "plain")
        XCTAssertNil(SatelliteChain.egressFormat(SatelliteChain.modeUndeclared))
        XCTAssertNil(SatelliteChain.egressFormat(nil))
    }

    func testALateImeiOrAChainSwitchReAnnouncesAMissingImeiDeclaresNothing() {
        let before = HubReporter.modemDeclarations([imt("binding", imei: "", format: "sealed")])
        XCTAssertEqual(before, [])
        let late = HubReporter.modemDeclarations([imt(format: "sealed")])
        XCTAssertNotEqual(before, late)
        let plain = HubReporter.modemDeclarations([imt(format: "plain")])
        XCTAssertNotEqual(late, plain)
        XCTAssertEqual(late, ["300000000000001:sealed"])
    }

    func testTheSettingPicksTheChainBothWays() {
        XCTAssertEqual(SatelliteChain.chainOf(SatelliteChain.modeSealed), .h)
        XCTAssertEqual(SatelliteChain.chainOf(SatelliteChain.modeLegacy), .legacy)
        XCTAssertNil(SatelliteChain.chainOf(SatelliteChain.modePlain))
        XCTAssertNil(SatelliteChain.chainOf(SatelliteChain.modeUndeclared))
        XCTAssertNil(SatelliteChain.chainOf(nil))
        // The rollback chain is parallax's: smaz2 with no dict (the default table), encrypt, base64.
        XCTAssertEqual(
            SatelliteChain.Chain.legacy.steps(keyHex: key),
            [TransformSpec(type: "smaz2"), TransformSpec(type: "encrypt", params: ["key": key]), TransformSpec(type: "base64")])
    }

    /// The review's A3, which reproduced R33-R2 on Android 2.22.0, now with parallax's chain: it opens.
    func testALegacyWireFromTheGeneralPipelineOpensOnTheSatellitePath() throws {
        let text = Array("hello there, the satellite is in range".utf8)
        let legacy = [TransformSpec(type: "smaz2"), TransformSpec(type: "encrypt", params: ["key": key]), TransformSpec(type: "base64")]
        let pipeline = TransformPipeline()
        let wire: [UInt8] = [1] + (try pipeline.applyEgress(text, legacy))
        XCTAssertEqual(try pipeline.applyIngress(Array(wire.dropFirst()), legacy), text)
        let want = SatelliteChain.MtMessage.text(String(decoding: text, as: UTF8.self), sealed: true, chain: .legacy)
        XCTAssertEqual(SatelliteChain.readMt(wire, keyHex: key, preferred: .legacy), want)
        XCTAssertEqual(SatelliteChain.readMt(wire, keyHex: key, preferred: .h), want)
        // And an H wire still opens on the legacy setting, by its own tag.
        let h = try SatelliteChain.seal(text, keyHex: key)
        let opened = SatelliteChain.MtMessage.text(String(decoding: text, as: UTF8.self), sealed: true, chain: .h)
        XCTAssertEqual(SatelliteChain.readMt(h, keyHex: key, preferred: .legacy), opened)
        // Wrong key: neither chain reads it.
        guard case .unopened = SatelliteChain.readMt(wire, keyHex: otherKey, preferred: .legacy) else { return XCTFail("opened") }
    }

    func testTheRollbackChainHasTheSameOneMessageLimitAtTheBoundaryAndNoFurther() throws {
        // Wire = version byte + base64 of (nonce + smaz2 with the default table + tag).
        func wireLen(_ b: ArraySlice<UInt8>) -> Int { 1 + 4 * ((28 + Smaz2Bytes.compress(Array(b), dict: .default).count + 2) / 3) }
        // Bytes 0x01-0x08 are left out: the default table (lib-x) does not round trip them (the
        // vectors' spec says so), so a pool with them could not open to itself. The chain only
        // seals UTF-8 text.
        var rng = SeededBytes(seed: 1623)
        let pool = rng.next(SatelliteChain.maxWireBytes).map { (1...8).contains($0) ? $0 | 0x40 : $0 }
        var lo = 1
        var hi = pool.count
        while lo < hi {  // the longest prefix whose wire fits
            let mid = (lo + hi + 1) / 2
            if wireLen(pool[..<mid]) <= SatelliteChain.maxWireBytes { lo = mid } else { hi = mid - 1 }
        }
        // SMAZ2 is not monotonic byte by byte (a bigram can take the last byte back), so the edge is
        // walked to where one more byte no longer fits.
        while lo < pool.count, wireLen(pool[..<(lo + 1)]) <= SatelliteChain.maxWireBytes { lo += 1 }
        let most = Array(pool[..<lo])
        let wire = try SatelliteChain.seal(most, keyHex: key, chain: .legacy)
        XCTAssertEqual(wire.count, wireLen(most[...]))
        XCTAssertLessThanOrEqual(wire.count, SatelliteChain.maxWireBytes)
        XCTAssertEqual(try SatelliteChain.open(wire, keyHex: key, chain: .legacy), most)
        expectRefused("one byte over") { try SatelliteChain.seal(Array(pool[..<(lo + 1)]), keyHex: self.key, chain: .legacy) }
    }

    /// R33-R3: the chain's key is the one stored as exactly "iridium:shared". A "shared" key under
    /// another name (the address alone, another channel's) is never used, and with none the send
    /// fails closed.
    func testTheKeyIsReadAsIridiumSharedOnlyAndAnAbsentOneFailsClosed() async throws {
        let rows = ["shared": otherKey, "mesh:shared": otherKey]
        let asked = Collected<String>()
        let none = await SatelliteChain.key { name in
            asked.add(name)
            return rows[name]
        }
        XCTAssertNil(none, "a shared key under another name is never used")
        XCTAssertEqual(asked.list, [SatelliteChain.keyRef])
        XCTAssertEqual(SatelliteChain.keyRef, "iridium:shared")
        expectRefused("no key") { try SatelliteChain.seal(self.greek, keyHex: none) }
        let found = await SatelliteChain.key { name in name == "iridium:shared" ? self.key : rows[name] }
        XCTAssertEqual(found, key)
        // What is stored there must be a key: a reference or a short value is none.
        let reference = await SatelliteChain.key { _ in "convkey:shared" }
        XCTAssertNil(reference)
        let short = await SatelliteChain.key { _ in String(self.key.prefix(62)) }
        XCTAssertNil(short)
    }
}
