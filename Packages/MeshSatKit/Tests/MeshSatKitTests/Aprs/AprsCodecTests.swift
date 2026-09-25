// Mirrors AprsCodecTest.kt, Ax25CodecTest.kt, KissCodecTest.kt and AprsIsPasscodeTest.kt.
import XCTest

@testable import MeshSatAprs

final class AprsCodecTests: XCTestCase {
    private func frame(_ call: String, _ ssid: Int, _ info: String) -> Ax25Frame {
        Ax25Frame(dst: Ax25Address("APRS"), src: Ax25Address(call, ssid), info: Array(info.utf8))
    }

    func testParsePositionWithoutTimestamp() {
        let pkt = AprsCodec.parse(frame("PA3XYZ", 10, "!5222.06N/00454.25E-Test station"))
        XCTAssertEqual(pkt.dataType, "!")
        XCTAssertEqual(pkt.source, "PA3XYZ-10")
        XCTAssertEqual(pkt.lat, 52.0 + 22.06 / 60.0, accuracy: 0.001)
        XCTAssertEqual(pkt.lon, 4.0 + 54.25 / 60.0, accuracy: 0.001)
        XCTAssertEqual(pkt.comment, "Test station")
        XCTAssertEqual(pkt.symbol, "/-")
    }

    func testParsePositionSouthWest() {
        let pkt = AprsCodec.parse(frame("LU1ABC", 0, "!3436.22S/05822.90W-Buenos Aires"))
        XCTAssertLessThan(pkt.lat, 0)
        XCTAssertLessThan(pkt.lon, 0)
    }

    func testParseMessageWithId() {
        let pkt = AprsCodec.parse(frame("PA3XYZ", 10, ":PA3ABC   :Hello from MeshSat{42"))
        XCTAssertEqual(pkt.dataType, ":")
        XCTAssertEqual(pkt.msgTo, "PA3ABC")
        XCTAssertEqual(pkt.message, "Hello from MeshSat")
        XCTAssertEqual(pkt.msgId, "42")
    }

    func testParseMessageWithoutId() {
        let pkt = AprsCodec.parse(frame("TEST", 0, ":PA3ABC   :Simple message"))
        XCTAssertEqual(pkt.msgTo, "PA3ABC")
        XCTAssertEqual(pkt.message, "Simple message")
        XCTAssertEqual(pkt.msgId, "")
    }

    func testEncodePositionNorthEast() {
        let s = String(decoding: AprsCodec.encodePosition(lat: 52.3676, lon: 4.9041, comment: "MeshSat Bridge"), as: UTF8.self)
        XCTAssertEqual(s, "!5222.06N/00454.25E-MeshSat Bridge")
    }

    func testEncodePositionSouthWest() {
        let s = String(decoding: AprsCodec.encodePosition(lat: -34.6037, lon: -58.3816, comment: "test"), as: UTF8.self)
        XCTAssertTrue(s.contains("S"), s)
        XCTAssertTrue(s.contains("W"), s)
    }

    func testEncodeMessage() {
        XCTAssertEqual(
            String(decoding: AprsCodec.encodeMessage(to: "PA3ABC", text: "Hello", msgId: "123"), as: UTF8.self), ":PA3ABC   :Hello{123")
        XCTAssertEqual(String(decoding: AprsCodec.encodeMessage(to: "PA3ABC", text: "Hello"), as: UTF8.self), ":PA3ABC   :Hello")
    }

    func testEncodeDecodePositionRoundtrip() {
        let encoded = AprsCodec.encodePosition(lat: 52.3676, lon: 4.9041, symbolTable: "/", symbolCode: "-", comment: "roundtrip test")
        let pkt = AprsCodec.parse(Ax25Frame(dst: Ax25Address("APRS"), src: Ax25Address("TEST", 10), info: encoded))
        XCTAssertEqual(pkt.lat, 52.3676, accuracy: 0.001)
        XCTAssertEqual(pkt.lon, 4.9041, accuracy: 0.001)
        XCTAssertTrue(pkt.comment.contains("roundtrip test"))
    }

    func testFullKissAx25AprsChain() throws {
        let info = AprsCodec.encodePosition(lat: 48.8566, lon: 2.3522, symbolTable: "/", symbolCode: "-", comment: "Paris")
        let ax25 = Ax25Codec.encode(dst: Ax25Address("APRS"), src: Ax25Address("F4TEST", 7), path: [Ax25Address("WIDE1", 1)], info: info)
        let kiss = KissCodec.encode(ax25)
        let inner = Array(kiss[1..<(kiss.count - 1)])
        let kissDecoded = try XCTUnwrap(KissCodec.decode(inner))
        let decoded = try XCTUnwrap(Ax25Codec.decode(kissDecoded))
        XCTAssertEqual(decoded.src.call, "F4TEST")
        XCTAssertEqual(decoded.src.ssid, 7)
        let pkt = AprsCodec.parse(decoded)
        XCTAssertEqual(pkt.lat, 48.8566, accuracy: 0.001)
        XCTAssertEqual(pkt.lon, 2.3522, accuracy: 0.001)
        XCTAssertTrue(pkt.comment.contains("Paris"))
        // The deframer finds the same frame in a stream with noise around it.
        var deframer = KissCodec.Deframer()
        let frames = deframer.feed([0xC0, 0xC0] + kiss + [0x01])
        XCTAssertEqual(frames, [inner])
    }

    func testDirectedMessage() {
        XCTAssertEqual(AprsCodec.directedMessage("@pa3abc-5 Hello there")?.to, "PA3ABC-5")
        XCTAssertEqual(AprsCodec.directedMessage("@pa3abc-5 Hello there")?.text, "Hello there")
        XCTAssertEqual(AprsCodec.directedMessage("@N0CALL   spaced  ")?.text, "spaced")
        XCTAssertEqual(AprsCodec.directedMessage("@N0CALL " + String(repeating: "x", count: 80))?.text.count, 67)
        XCTAssertNil(AprsCodec.directedMessage("Hello @N0CALL"))
        XCTAssertNil(AprsCodec.directedMessage("@N0CALL"))
        XCTAssertNil(AprsCodec.directedMessage("@N0CALL   "))
        XCTAssertNil(AprsCodec.directedMessage("@TOOLONGCALL1 hi"))
        XCTAssertNil(AprsCodec.directedMessage("@N0_CALL hi"))
        XCTAssertNil(AprsCodec.directedMessage("@ hi"))
    }

    // MARK: AX.25

    func testAx25EncodeDecodeRoundtrip() throws {
        let info = Array("!5222.08N/00454.24E-MeshSat".utf8)
        let encoded = Ax25Codec.encode(
            dst: Ax25Address("APRS"), src: Ax25Address("PA3XYZ", 10), path: [Ax25Address("WIDE1", 1)], info: info)
        let decoded = try XCTUnwrap(Ax25Codec.decode(encoded))
        XCTAssertEqual(decoded.src, Ax25Address("PA3XYZ", 10))
        XCTAssertEqual(decoded.dst, Ax25Address("APRS", 0))
        XCTAssertEqual(decoded.path, [Ax25Address("WIDE1", 1)])
        XCTAssertEqual(decoded.info, info)
    }

    func testAx25NoPath() throws {
        let encoded = Ax25Codec.encode(dst: Ax25Address("APMSHT"), src: Ax25Address("TEST", 7), path: [], info: Array("test data".utf8))
        let decoded = try XCTUnwrap(Ax25Codec.decode(encoded))
        XCTAssertEqual(decoded.src, Ax25Address("TEST", 7))
        XCTAssertTrue(decoded.path.isEmpty)
        XCTAssertEqual(String(decoding: decoded.info, as: UTF8.self), "test data")
    }

    func testAx25MultiHopPath() throws {
        let encoded = Ax25Codec.encode(
            dst: Ax25Address("APRS"), src: Ax25Address("DL1ABC", 9), path: [Ax25Address("WIDE1", 1), Ax25Address("WIDE2", 1)],
            info: Array("test".utf8))
        let decoded = try XCTUnwrap(Ax25Codec.decode(encoded))
        XCTAssertEqual(decoded.path.map(\.formatted), ["WIDE1-1", "WIDE2-1"])
    }

    func testAx25RejectsTooShortFrame() {
        XCTAssertNil(Ax25Codec.decode([UInt8](repeating: 0, count: 10)))
    }

    func testAx25FormatCallsign() {
        XCTAssertEqual(Ax25Address("PA3XYZ", 10).formatted, "PA3XYZ-10")
        XCTAssertEqual(Ax25Address("PA3XYZ", 0).formatted, "PA3XYZ")
        XCTAssertEqual(Ax25Address("WIDE1", 1).formatted, "WIDE1-1")
    }

    // MARK: KISS

    func testKissEncodeWrapsAndEscapes() {
        XCTAssertEqual(KissCodec.encode([0x01, 0x02, 0x03]), [0xC0, 0x00, 0x01, 0x02, 0x03, 0xC0])
        XCTAssertEqual(KissCodec.encode([0x01, 0xC0, 0x02]), [0xC0, 0x00, 0x01, 0xDB, 0xDC, 0x02, 0xC0])
        XCTAssertEqual(KissCodec.encode([0x01, 0xDB, 0x02]), [0xC0, 0x00, 0x01, 0xDB, 0xDD, 0x02, 0xC0])
    }

    func testKissDecode() {
        XCTAssertEqual(KissCodec.decode([0x00, 0x01, 0x02, 0x03]), [0x01, 0x02, 0x03])
        XCTAssertEqual(KissCodec.decode([0x00, 0x01, 0xDB, 0xDC, 0x02]), [0x01, 0xC0, 0x02])
        XCTAssertEqual(KissCodec.decode([0x00, 0x01, 0xDB, 0xDD, 0x02]), [0x01, 0xDB, 0x02])
        let original: [UInt8] = [0x00, 0xC0, 0xDB, 0xFF, 0x42]
        let encoded = KissCodec.encode(original)
        XCTAssertEqual(KissCodec.decode(Array(encoded[1..<(encoded.count - 1)])), original)
    }

    func testKissDecodeRejects() {
        XCTAssertNil(KissCodec.decode([0x00]))
        XCTAssertNil(KissCodec.decode([0x01, 0x02, 0x03]))
        XCTAssertNil(KissCodec.decode([0x00, 0x01, 0xDB]))
        XCTAssertNil(KissCodec.decode([0x00, 0x01, 0xDB, 0x42]))
    }

    // MARK: Passcode

    func testPasscode() {
        XCTAssertEqual(AprsIsPasscode.calculate("N0CALL"), "13023")
        XCTAssertEqual(AprsIsPasscode.calculate("PA3XYZ-10"), AprsIsPasscode.calculate("PA3XYZ"))
        XCTAssertEqual(AprsIsPasscode.calculate("pa3xyz"), AprsIsPasscode.calculate("PA3XYZ"))
        XCTAssertEqual(AprsIsPasscode.calculate(""), "-1")
        XCTAssertNotEqual(AprsIsPasscode.calculate("PA3XYZ"), AprsIsPasscode.calculate("PA3ABC"))
        for call in ["W3ADO", "N0CAL"] {
            let code = Int(AprsIsPasscode.calculate(call)) ?? -1
            XCTAssertTrue((0...32767).contains(code), call)
        }
    }
}
