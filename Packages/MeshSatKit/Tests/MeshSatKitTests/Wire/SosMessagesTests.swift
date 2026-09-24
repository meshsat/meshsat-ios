// Mirrors SosMessagesTest.kt: the SOS texts and the satellite frame (MESHSAT-1249). The frame
// vectors come from the Bridge's own encoder (internal/hubreporter/satuplink.go EncodeSatSOS),
// because the Hub decodes the phone's frame with the Bridge's layout.
import MeshSatWire
import XCTest

final class SosMessagesTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testTheSatelliteFrameIsByteForByteTheBridges() {
        let fix = SosMessages.Fix(lat: 52.1620671, lon: 4.5097402, accuracyM: 12, timeMs: 0)
        let frame = SosMessages.satFrame(
            bridgeId: "msa-flaneur", deviceId: "300434067943980", fix: fix, message: "SOS from flaneur, needs help", nowSec: 1_790_000_000)
        XCTAssertEqual(
            hex(frame),
            "4d5301020b6d73612d666c616e6575720f3330303433343036373934333938304250a5f54"
                + "0904fcb1c534f532066726f6d20666c616e6575722c206e656564732068656c706ab13b80"
        )
    }

    func testALongBridgeIdIsCutTo16BytesAndNoFixIs00AsOnTheBridge() {
        let frame = SosMessages.satFrame(bridgeId: "a-very-long-bridge-id-here", deviceId: "", fix: nil, message: "", nowSec: 1_790_000_000)
        XCTAssertEqual(hex(frame), "4d53010210612d766572792d6c6f6e672d62726964000000000000000000006ab13b80")
    }

    func testTheTestsPositionFrameIsByteForByteTheBridges() {
        let here = SosMessages.Fix(lat: 52.1620671, lon: 4.5097402, accuracyM: 12, timeMs: 0)
        XCTAssertEqual(
            hex(SosMessages.positionFrame(bridgeId: "msa-flaneur", fix: here, altitudeM: 12.7, nowSec: 1_790_000_000)),
            "4d5301010b6d73612d666c616e6575724250a5f540904fcb000c016ab13b80")
        let south = SosMessages.Fix(lat: -33.86882, lon: 151.20929, accuracyM: nil, timeMs: 0)
        XCTAssertEqual(
            hex(SosMessages.positionFrame(bridgeId: "msa-flaneur", fix: south, altitudeM: -3.2, nowSec: 1_790_000_000)),
            "4d5301010b6d73612d666c616e657572c20779ac43173594fffd016ab13b80")
    }

    func testATestAndACancellationNeverRaiseAnAlarmAtTheHubWhateverTheName() {
        for name in ["flaneur", "Sosimos", "Emergency team", "MAYDAY", ""] {
            XCTAssertFalse(SosMessages.containsAlarmWord(SosMessages.testText(name: name)), name)
            XCTAssertFalse(SosMessages.containsAlarmWord(SosMessages.cancelText(name: name)), name)
        }
    }

    func testAnSosDoesRaiseTheAlarmOnEveryRoute() {
        let fix = SosMessages.Fix(lat: 52.16207, lon: 4.50974, accuracyM: 8, timeMs: 1_000)
        XCTAssertTrue(SosMessages.containsAlarmWord(SosMessages.meshText(name: "flaneur", fix: fix, nowMs: 1_000)))
        XCTAssertTrue(SosMessages.containsAlarmWord(SosMessages.smsText(name: "flaneur", fix: fix, nowMs: 1_000)))
        XCTAssertTrue(SosMessages.containsAlarmWord(SosMessages.frameMessage(name: "flaneur", fix: fix)))
    }

    func testCoordinatesUseAPointWhateverThePhonesLanguage() {
        let fix = SosMessages.Fix(lat: 52.1620671, lon: 4.5097402, accuracyM: 12.4, timeMs: 0)
        XCTAssertEqual(SosMessages.coordinates(fix), "52.16207, 4.50974")
        XCTAssertTrue(SosMessages.smsText(name: "flaneur", fix: fix, nowMs: 0).contains("mlat=52.16207&mlon=4.50974"))
    }

    func testAnSmsWithTheLongestNameFitsOneGsm7Part() {
        let fix = SosMessages.Fix(lat: -33.86882, lon: -151.20929, accuracyM: 12345, timeMs: 0)
        let text = SosMessages.smsText(name: String(repeating: "A", count: 40), fix: fix, nowMs: 10 * 60_000)
        XCTAssertLessThanOrEqual(text.count, 160, text)
        XCTAssertTrue(text.allSatisfy { $0.isASCII && ($0.asciiValue ?? 0) >= 32 && ($0.asciiValue ?? 0) <= 126 })
    }

    func testAnOldFixIsCalledTheLastPosition() {
        let fix = SosMessages.Fix(lat: 52.0, lon: 4.0, accuracyM: nil, timeMs: 0)
        XCTAssertEqual(SosMessages.whereText(fix, nowMs: 3 * 60_000), "Last position 52.00000, 4.00000 at 00:00 UTC.")
        XCTAssertEqual(SosMessages.whereText(nil, nowMs: 0), "Position unknown.")
    }

    func testTheFrameMessageIsCutWithoutSplittingACharacter() {
        let cut = SosMessages.truncateUtf8("SOS: " + String(repeating: "Κυριάκος", count: 8), maxBytes: 64)
        XCTAssertLessThanOrEqual(cut.utf8.count, 64)
        XCTAssertFalse(cut.contains("\u{FFFD}"))
        XCTAssertEqual(SosMessages.cleanName("  \u{1}Anna\tde Vries  "), "Annade Vries")
    }

    func testProtocolVersionByte() {
        XCTAssertEqual(ProtocolVersion.prependVersionByte([0x41]), [0x01, 0x41])
        XCTAssertEqual(ProtocolVersion.stripVersionByte([0x01, 0x41]), .init(version: 1, data: [0x41]))
        XCTAssertEqual(ProtocolVersion.stripVersionByte([0x50, 0x41]), .init(version: 0, data: [0x50, 0x41]))
        XCTAssertEqual(ProtocolVersion.stripVersionByte([0x41]), .init(version: 0, data: [0x41]))
        XCTAssertEqual(ProtocolVersion.stripVersionByte([]), .init(version: 0, data: []))
    }
}
