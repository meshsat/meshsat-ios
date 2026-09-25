// Mirrors CotBuilderTest.kt (MESHSAT-191), plus the exact XML Android writes, Kotlin's number
// layout, the parser's edge cases, the protobuf round trip and the integration's outputs.
import XCTest

@testable import MeshSatTak

final class CotBuilderTests: XCTestCase {
    /// 2026-09-25T10:20:30Z
    private let fixed = Date(timeIntervalSince1970: 1_790_331_630)

    func testCallsignFormatMatchesBridge() {
        XCTAssertEqual(CotBuilder.callsign("123456"), "MESHSAT-3456")
        XCTAssertEqual(CotBuilder.callsign("abcd"), "MESHSAT-ABCD")
        XCTAssertEqual(CotBuilder.callsign(""), "MESHSAT")
        XCTAssertEqual(CotBuilder.callsign("123456", prefix: "MS"), "MS-3456")
    }

    func testPositionEvent() {
        let ev = CotBuilder.position(uid: "uid1", callsign: "MESHSAT-1234", lat: 47.3, lon: -122.5, alt: 100)
        XCTAssertEqual(ev.type, CotType.position)
        XCTAssertEqual(ev.how, CotHow.gps)
        XCTAssertEqual(ev.version, "2.0")
        XCTAssertEqual(ev.point, CotPoint(lat: 47.3, lon: -122.5, hae: 100, ce: 10, le: 10))
        XCTAssertEqual(ev.detail?.contact?.callsign, "MESHSAT-1234")
        XCTAssertEqual(ev.detail?.group, CotGroup(name: "Cyan", role: "Team Member"))
        XCTAssertEqual(ev.detail?.precision?.altSrc, "GPS")
        XCTAssertNil(ev.detail?.emergency)
        XCTAssertNil(ev.detail?.status)
        XCTAssertEqual(CotBuilder.position(uid: "u", callsign: "c", lat: 0, lon: 0, battery: "87").detail?.status?.battery, "87")
    }

    func testSosEvent() {
        let ev = CotBuilder.sos(uid: "uid1", callsign: "MESHSAT-1234", lat: 47.3, lon: -122.5, reason: "battery low")
        XCTAssertEqual(ev.type, CotType.position)
        XCTAssertEqual(ev.detail?.emergency, CotEmergency(type: "911 Alert", text: "battery low"))
        XCTAssertEqual(ev.detail?.remarks, CotRemarks(source: "MeshSat", text: "Emergency: battery low"))
    }

    func testDeadmanEvent() {
        let ev = CotBuilder.deadman(uid: "uid1", callsign: "MESHSAT-1234", lat: 47.3, lon: -122.5, timeoutSec: 7200)
        XCTAssertEqual(ev.type, CotType.alarm)
        XCTAssertEqual(ev.how, CotHow.humanEntered)
        XCTAssertEqual(ev.uid, "uid1-DEADMAN")
        XCTAssertEqual(ev.point.ce, 100)
        XCTAssertTrue(ev.detail?.remarks?.text.contains("7200s") == true)
    }

    func testChatEvent() {
        let ev = CotBuilder.chat(uid: "uid1", callsign: "MESHSAT-1234", text: "hello world", now: fixed)
        XCTAssertEqual(ev.type, CotType.chat)
        XCTAssertEqual(ev.how, CotHow.humanGeochat)
        XCTAssertEqual(ev.uid, "uid1-CHAT-" + String(1_790_331_630_000, radix: 36))
        XCTAssertEqual(ev.point.lat, 0)
        XCTAssertEqual(ev.point.ce, 9_999_999)
        XCTAssertEqual(ev.detail?.remarks, CotRemarks(source: "MESHSAT-1234", text: "hello world"))
    }

    func testTelemetryEvent() {
        let ev = CotBuilder.telemetry(uid: "uid1", callsign: "MESHSAT-1234", lat: 47.3, lon: -122.5, data: "temp=22.5C")
        XCTAssertEqual(ev.type, CotType.sensor)
        XCTAssertEqual(ev.uid, "uid1-SENSOR")
        XCTAssertEqual(ev.detail?.contact?.callsign, "MESHSAT-1234-SENSOR")
        XCTAssertEqual(ev.point.ce, 50)
        XCTAssertEqual(ev.detail?.remarks?.text, "temp=22.5C")
    }

    func testEnrichedPosition() {
        let ev = CotBuilder.enrichedPosition(uid: "u", callsign: "c", lat: 1, lon: 2, hdop: 1.5, pdop: 2)
        XCTAssertEqual(ev.point.ce, 7.5)
        XCTAssertEqual(ev.point.le, 8)
        let pdopOnly = CotBuilder.enrichedPosition(uid: "u", callsign: "c", lat: 1, lon: 2, pdop: 2)
        XCTAssertEqual(pdopOnly.point.ce, 6)
    }

    func testTimes() {
        let ev = CotBuilder.position(uid: "uid1", callsign: "CS", lat: 0, lon: 0, staleSec: 300, now: fixed)
        XCTAssertEqual(ev.time, "2026-09-25T10:20:30Z")
        XCTAssertEqual(ev.start, "2026-09-25T10:20:30Z")
        XCTAssertEqual(ev.stale, "2026-09-25T10:25:30Z")
        XCTAssertGreaterThan(ev.stale, ev.start)
        let re = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")
        let live = CotBuilder.position(uid: "u", callsign: "c", lat: 0, lon: 0)
        XCTAssertNotNil(re?.firstMatch(in: live.time, range: NSRange(live.time.startIndex..., in: live.time)))
    }

    // MARK: XML

    func testXmlMarshalIsAndroidsByteForByte() {
        let ev = CotBuilder.position(uid: "uid1", callsign: "MESHSAT-1234", lat: 47.3, lon: -122.5, alt: 100, now: fixed)
        XCTAssertEqual(
            CotXml.marshal(ev),
            "<event version=\"2.0\" uid=\"uid1\" type=\"a-f-G-U-C\" how=\"m-g\" time=\"2026-09-25T10:20:30Z\" "
                + "start=\"2026-09-25T10:20:30Z\" stale=\"2026-09-25T10:25:30Z\">"
                + "<point lat=\"47.3\" lon=\"-122.5\" hae=\"100.0\" ce=\"10.0\" le=\"10.0\"></point>"
                + "<detail><contact callsign=\"MESHSAT-1234\"></contact><__group name=\"Cyan\" role=\"Team Member\"></__group>"
                + "<precisionlocation altsrc=\"GPS\" geopointsrc=\"GPS\"></precisionlocation>"
                + "<track course=\"0.0\" speed=\"0.0\"></track></detail></event>")
    }

    func testXmlMarshalSosIncludesEmergency() {
        let xml = CotXml.marshal(CotBuilder.sos(uid: "uid1", callsign: "CS", lat: 47.3, lon: -122.5, reason: "help me"))
        XCTAssertTrue(xml.contains("<emergency type=\"911 Alert\">help me</emergency>"))
        XCTAssertTrue(xml.contains("<remarks source=\"MeshSat\">Emergency: help me</remarks>"))
    }

    func testXmlRoundTrip() throws {
        let ev = CotBuilder.position(uid: "uid-rt", callsign: "MESHSAT-TEST", lat: 47.3, lon: -122.5, alt: 100, battery: "42", now: fixed)
        let parsed = try XCTUnwrap(CotXml.parse(CotXml.marshal(ev)))
        XCTAssertEqual(parsed, ev)
        let sos = CotBuilder.sos(uid: "uid-sos", callsign: "CS", lat: 47.3, lon: -122.5, reason: "evacuation needed", now: fixed)
        XCTAssertEqual(CotXml.parse(CotXml.marshal(sos)), sos)
    }

    func testXmlParseRejectsNonXml() {
        XCTAssertNil(CotXml.parse("not xml"))
        XCTAssertNil(CotXml.parse(""))
        XCTAssertNil(CotXml.parse("<point lat=\"1\"/>"))
        XCTAssertNil(CotXml.parse("<event uid=\"x\"><point lat=\"1\"></event>"))
    }

    func testXmlEscapesSpecialCharacters() throws {
        let ev = CotBuilder.chat(uid: "uid1", callsign: "CS", text: "test <>&\"' message")
        let xml = CotXml.marshal(ev)
        XCTAssertTrue(xml.contains("test &lt;&gt;&amp;&quot;&apos; message"))
        XCTAssertEqual(try XCTUnwrap(CotXml.parse(xml)).detail?.remarks?.text, "test <>&\"' message")
    }

    func testXmlParsesBridgeStyleDocument() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <event version="2.0" uid="MESHSAT-abc" type="a-f-G-U-C-I" how="m-g" time="2026-09-25T10:20:30Z"
                start="2026-09-25T10:20:30Z" stale="2026-09-25T10:25:30Z">
              <point lat="52.3676" lon="4.9041" hae="12.5" ce="10" le="10"/>
              <detail>
                <contact callsign="MESHSAT-KIT1" endpoint="*:-1:stcp"/>
                <__group name="Cyan" role="Team Member"/>
                <track course="90" speed="1.5"/>
                <remarks>Bridge &amp; kit <![CDATA[<raw>]]></remarks>
                <unknown foo="bar"/>
              </detail>
            </event>
            """
        let ev = try XCTUnwrap(CotXml.parse(xml))
        XCTAssertEqual(ev.uid, "MESHSAT-abc")
        XCTAssertEqual(ev.type, "a-f-G-U-C-I")
        XCTAssertEqual(ev.point, CotPoint(lat: 52.3676, lon: 4.9041, hae: 12.5, ce: 10, le: 10))
        XCTAssertEqual(ev.detail?.contact?.callsign, "MESHSAT-KIT1")
        XCTAssertEqual(ev.detail?.track, CotTrack(course: 90, speed: 1.5))
        XCTAssertEqual(ev.detail?.remarks?.text, "Bridge & kit <raw>")
        XCTAssertNil(ev.detail?.emergency)
    }

    func testKotlinDoubleLayout() {
        XCTAssertEqual(CotXml.kotlinDouble(47.3), "47.3")
        XCTAssertEqual(CotXml.kotlinDouble(-122.5), "-122.5")
        XCTAssertEqual(CotXml.kotlinDouble(0), "0.0")
        XCTAssertEqual(CotXml.kotlinDouble(100), "100.0")
        XCTAssertEqual(CotXml.kotlinDouble(9_999_999), "9999999.0")
        XCTAssertEqual(CotXml.kotlinDouble(10_000_000), "1.0E7")
        XCTAssertEqual(CotXml.kotlinDouble(12_345_678.9), "1.23456789E7")
        XCTAssertEqual(CotXml.kotlinDouble(0.001), "0.001")
        XCTAssertEqual(CotXml.kotlinDouble(0.0001), "1.0E-4")
        XCTAssertEqual(CotXml.kotlinDouble(0.00012345), "1.2345E-4")
        XCTAssertEqual(CotXml.kotlinDouble(-2.5e-7), "-2.5E-7")
        XCTAssertEqual(CotXml.kotlinDouble(52.36760000000001), "52.36760000000001")
    }

    // MARK: Protobuf

    func testProtoRoundTrip() throws {
        let ev = CotBuilder.position(
            uid: "uid1", callsign: "MESHSAT-1234", lat: 47.3, lon: -122.5, alt: 100, course: 90, speed: 1.5, battery: "42", now: fixed)
        let bytes = TakProto.cotEventToProto(ev)
        XCTAssertFalse(bytes.isEmpty)
        let back = try XCTUnwrap(TakProto.protoToCotEvent(bytes))
        XCTAssertEqual(back.uid, "uid1")
        XCTAssertEqual(back.type, CotType.position)
        XCTAssertEqual(back.time, "2026-09-25T10:20:30Z")
        XCTAssertEqual(back.stale, "2026-09-25T10:25:30Z")
        XCTAssertEqual(back.point, ev.point)
        XCTAssertEqual(back.detail?.contact?.callsign, "MESHSAT-1234")
        XCTAssertEqual(back.detail?.group, CotGroup())
        XCTAssertEqual(back.detail?.precision, CotPrecision())
        XCTAssertEqual(back.detail?.track, CotTrack(course: 90, speed: 1.5))
        XCTAssertEqual(back.detail?.status?.battery, "42")
        XCTAssertNil(TakProto.protoToCotEvent([0xFF, 0x00, 0x12]))
        XCTAssertNil(TakProto.protoToCotEvent([]))
    }

    func testFraming() {
        XCTAssertEqual(TakProto.frameForStream([1, 2, 3]), [0xBF, 3, 1, 2, 3])
        XCTAssertEqual(TakProto.frameForStream([UInt8](repeating: 0, count: 300)).prefix(3), [0xBF, 0xAC, 0x02])
        XCTAssertEqual(TakProto.frameForMulticast([9]), [0xBF, 0x01, 0xBF, 9])
        XCTAssertEqual(TakProto.encodeVarint(0), [0])
        XCTAssertEqual(TakProto.encodeVarint(127), [127])
        XCTAssertEqual(TakProto.encodeVarint(128), [0x80, 0x01])
    }

    // MARK: Integration

    func testIntegrationPublishesAndFormats() async {
        let published = PublishedXml()
        let tak = TakIntegration(deviceId: "abcdef123456", callsignPrefix: "MS", publish: { await published.add($0) })
        XCTAssertEqual(tak.callsign, "MS-3456")
        await tak.sendPosition(lat: 47.3, lon: -122.5, alt: 10, course: 45, speed: 2)
        await tak.sendSOS(lat: 47.3, lon: -122.5, reason: "fall")
        tak.updateOutputFlags(mqttExport: false)
        await tak.sendChat("silent")
        let xmls = await published.all
        XCTAssertEqual(xmls.count, 2)
        XCTAssertTrue(xmls[0].contains("uid=\"MESHSAT-abcdef123456\""))
        XCTAssertTrue(xmls[0].contains("callsign=\"MS-3456\""))
        XCTAssertTrue(xmls[1].contains("<emergency type=\"911 Alert\">fall</emergency>"))
        XCTAssertEqual(TakIntegration.outTopic(prefix: "meshsat/acme", deviceId: "kit-1"), "meshsat/acme/kit-1/tak/cot/out")

        let pos = CotBuilder.position(uid: "u", callsign: "KIT", lat: 52.3676, lon: 4.9041)
        XCTAssertEqual(tak.formatForDisplay(pos), "[TAK:KIT] 52.367600,4.904100")
        XCTAssertEqual(
            tak.formatForDisplay(CotBuilder.sos(uid: "u", callsign: "KIT", lat: 0, lon: 0, reason: "x")), "[TAK:KIT] EMERGENCY: x")
        XCTAssertEqual(tak.formatForDisplay(CotBuilder.chat(uid: "u", callsign: "KIT", text: "hi")), "[TAK:KIT] hi")
        var bare = pos
        bare.detail = nil
        bare.point.lat = 0
        XCTAssertEqual(tak.formatForDisplay(bare), "[TAK:unknown] a-f-G-U-C event")
        XCTAssertNil(tak.parseInbound("nope"))
    }
}

private actor PublishedXml {
    var all: [String] = []
    func add(_ xml: String) { all.append(xml) }
}
