// Mirrors TakChatTest.kt (MESHSAT-1707/1708): a dispatcher's TAK chat to this phone and the
// phone's answer. The GeoChats are as ATAK, WinTAK and iTAK write them; every "not for me" has a
// positive control beside it.
import XCTest

@testable import MeshSatTak

final class TakChatTests: XCTestCase {
    private let me = "MESHSAT-msa-test"
    private let meCallsign = "MESHSAT-TEST"
    /// 2026-09-25T10:20:30Z
    private let fixed = Date(timeIntervalSince1970: 1_790_331_630)

    private func chat(_ dest: String, toUid: String? = nil, toCallsign: String? = nil, text: String = "check in &amp; report") -> String {
        let uid = toUid ?? me
        let cs = toCallsign ?? meCallsign
        return "<event version=\"2.0\" uid=\"GeoChat.ANDROID-abc.\(uid).m1\" type=\"b-t-f\" how=\"h-g-i-g-o\" "
            + "time=\"2026-10-27T10:00:00Z\" start=\"2026-10-27T10:00:00Z\" stale=\"2026-10-28T10:00:00Z\">"
            + "<point lat=\"0\" lon=\"0\" hae=\"9999999\" ce=\"9999999\" le=\"9999999\"/><detail>"
            + "<__chat parent=\"RootContactGroup\" groupOwner=\"false\" messageId=\"m1\" chatroom=\"\(cs)\" id=\"\(uid)\" "
            + "senderCallsign=\"DISPATCH-1\"><chatgrp uid0=\"ANDROID-abc\" uid1=\"\(uid)\" id=\"\(uid)\"/></__chat>"
            + "<link uid=\"ANDROID-abc\" type=\"a-f-G-U-C\" relation=\"p-p\"/>"
            + "<remarks source=\"BAO.F.ATAK.ANDROID-abc\" to=\"\(uid)\">\(text)</remarks>\(dest)</detail></event>"
    }

    private func parsed(_ xml: String) throws -> CotEvent { try XCTUnwrap(CotXml.parse(xml)) }

    func testAChatAtakAddressesToThisPhoneByCallsignIsForIt() throws {
        let ev = try parsed(chat("<marti><dest callsign=\"\(meCallsign)\"/></marti>"))
        XCTAssertEqual(
            TakChats.chatFor(ev, ownUid: me, ownCallsign: meCallsign),
            TakChats.Chat(fromUid: "ANDROID-abc", fromCallsign: "DISPATCH-1", text: "check in & report"))
    }

    func testAChatItakAddressesToThisPhoneByUidIsForIt() throws {
        let ev = try parsed(chat("<marti><dest uid=\"\(me)\"/></marti>"))
        XCTAssertEqual(TakChats.chatFor(ev, ownUid: me, ownCallsign: meCallsign)?.fromCallsign, "DISPATCH-1")
    }

    func testAChatForSomebodyElseTheRoomOrThisPhoneItselfIsNot() throws {
        let other = try parsed(chat("<marti><dest callsign=\"OTHER-1\"/></marti>", toUid: "ANDROID-xyz", toCallsign: "OTHER-1"))
        XCTAssertNil(TakChats.chatFor(other, ownUid: me, ownCallsign: meCallsign))
        let room = try parsed(chat("", toUid: CotBuilder.chatRoom, toCallsign: CotBuilder.chatRoom))
        XCTAssertNil(TakChats.chatFor(room, ownUid: me, ownCallsign: meCallsign))
        let own = try parsed(chat("<marti><dest uid=\"\(me)\"/></marti>").replacingOccurrences(of: "ANDROID-abc", with: me))
        XCTAssertNil(TakChats.chatFor(own, ownUid: me, ownCallsign: meCallsign))
        let empty = try parsed(chat("<marti><dest uid=\"\(me)\"/></marti>", text: "  "))
        XCTAssertNil(TakChats.chatFor(empty, ownUid: me, ownCallsign: meCallsign))
        // Positive control: the same chat, addressed to this phone.
        XCTAssertNotNil(TakChats.chatFor(try parsed(chat("<marti><dest uid=\"\(me)\"/></marti>")), ownUid: me, ownCallsign: meCallsign))
    }

    func testAMissionDestNamesNobody() throws {
        let ev = try parsed(chat("<marti><dest mission=\"ops\"/></marti>"))
        XCTAssertEqual(ev.detail?.marti, [])
        // Without a person dest, __chat names the recipient: this phone.
        XCTAssertNotNil(TakChats.chatFor(ev, ownUid: me, ownCallsign: meCallsign))
    }

    func testTheAnswerIsAGeoChatTheDispatchersClientReadsAsAChatToIt() throws {
        let ev = CotBuilder.geoChat(
            fromUid: me, fromCallsign: meCallsign, toUid: "ANDROID-abc", toCallsign: "DISPATCH-1", text: "on my way <5 min>",
            messageId: "id-1", now: fixed)
        let back = try parsed(CotXml.marshal(ev))
        XCTAssertEqual(back, ev)
        XCTAssertEqual(back.type, CotType.chat)
        XCTAssertEqual(back.uid, "GeoChat.\(me).ANDROID-abc.id-1")
        XCTAssertEqual(back.stale, "2026-09-26T10:20:30Z")
        XCTAssertEqual(
            TakChats.chatFor(back, ownUid: "ANDROID-abc", ownCallsign: "DISPATCH-1"),
            TakChats.Chat(fromUid: me, fromCallsign: meCallsign, text: "on my way <5 min>"))
        let d = try XCTUnwrap(back.detail)
        XCTAssertEqual(d.marti, [CotDest(uid: "ANDROID-abc", callsign: "DISPATCH-1")])
        XCTAssertEqual(d.chat?.messageId, "id-1")
        XCTAssertEqual(d.chat?.uid0, me)
        XCTAssertEqual(d.remarks?.to, "ANDROID-abc")
    }

    /// Android's geoChat writes exactly this; the Bridge and the Hub read it.
    func testTheAnswerIsAndroidsXmlByteForByte() {
        let ev = CotBuilder.geoChat(
            fromUid: "MESHSAT-a", fromCallsign: "MESHSAT-A", toUid: "ANDROID-abc", toCallsign: "DISPATCH-1", text: "ok", messageId: "id-1",
            now: fixed)
        XCTAssertEqual(
            CotXml.marshal(ev),
            "<event version=\"2.0\" uid=\"GeoChat.MESHSAT-a.ANDROID-abc.id-1\" type=\"b-t-f\" how=\"h-g-i-g-o\" "
                + "time=\"2026-09-25T10:20:30Z\" start=\"2026-09-25T10:20:30Z\" stale=\"2026-09-26T10:20:30Z\">"
                + "<point lat=\"0.0\" lon=\"0.0\" hae=\"9999999.0\" ce=\"9999999.0\" le=\"9999999.0\"></point><detail>"
                + "<__chat parent=\"RootContactGroup\" groupOwner=\"false\" messageId=\"id-1\" chatroom=\"DISPATCH-1\" "
                + "id=\"ANDROID-abc\" senderCallsign=\"MESHSAT-A\"><chatgrp uid0=\"MESHSAT-a\" uid1=\"ANDROID-abc\" "
                + "id=\"ANDROID-abc\"></chatgrp></__chat><link uid=\"MESHSAT-a\" type=\"a-f-G-U-C\" relation=\"p-p\"></link>"
                + "<remarks source=\"BAO.F.ATAK.MESHSAT-a\" to=\"ANDROID-abc\" time=\"2026-09-25T10:20:30Z\">ok</remarks>"
                + "<marti><dest uid=\"ANDROID-abc\" callsign=\"DISPATCH-1\"></dest></marti></detail></event>")
    }

    func testAPositionOffersChatToATakClient() throws {
        let xml = CotXml.marshal(CotBuilder.position(uid: "MESHSAT-x", callsign: "MESHSAT-X", lat: 52, lon: 4))
        XCTAssertTrue(xml.contains("endpoint=\"*:-1:stcp\""), xml)
        XCTAssertEqual(try parsed(xml).detail?.contact?.endpoint, CotBuilder.takEndpoint)
    }

    func testATakConversationKey() {
        let peer = TakChats.peer(uid: "ANDROID-abc", callsign: "DISPATCH-1")
        XCTAssertEqual(peer, "tak:ANDROID-abc#DISPATCH-1")
        XCTAssertTrue(TakChats.isPeer(peer))
        XCTAssertEqual(TakChats.uid(ofPeer: peer), "ANDROID-abc")
        XCTAssertEqual(TakChats.callsign(ofPeer: peer), "DISPATCH-1")
        // An operator on the Hub map.
        XCTAssertEqual(TakChats.uid(ofPeer: TakChats.peer(uid: "meshsat-hub-op-7", callsign: "Office")), "meshsat-hub-op-7")
        // Not TAK.
        XCTAssertFalse(TakChats.isPeer("bridge:kit-a"))
        XCTAssertFalse(TakChats.isPeer("tak:"))
        XCTAssertEqual(TakChats.uid(ofPeer: "!0a0b0c0d"), "")
        XCTAssertEqual(TakChats.callsign(ofPeer: "tak:uid-only"), "")
    }

    func testTheIntegrationAnswersAndReadsAsThisPhone() async throws {
        let published = Published()
        let tak = TakIntegration(deviceId: "msa-test", callsignPrefix: "MESHSAT", publish: { await published.add($0) })
        XCTAssertEqual(tak.uid, "MESHSAT-msa-test")
        XCTAssertTrue(tak.canExport)
        await tak.sendChat(to: "ANDROID-abc", callsign: "DISPATCH-1", text: "copy")
        let xmls = await published.all
        XCTAssertEqual(xmls.count, 1)
        let back = try parsed(xmls[0])
        XCTAssertEqual(TakChats.chatFor(back, ownUid: "ANDROID-abc", ownCallsign: "DISPATCH-1")?.fromUid, "MESHSAT-msa-test")
        XCTAssertNotNil(tak.chatFor(try parsed(chat("<marti><dest uid=\"MESHSAT-msa-test\"/></marti>", toUid: "MESHSAT-msa-test"))))
        tak.updateOutputFlags(mqttExport: false)
        XCTAssertFalse(tak.canExport)
        XCTAssertFalse(TakIntegration(deviceId: "x", publish: nil).canExport)
    }
}

private actor Published {
    var all: [String] = []
    func add(_ s: String) { all.append(s) }
}
