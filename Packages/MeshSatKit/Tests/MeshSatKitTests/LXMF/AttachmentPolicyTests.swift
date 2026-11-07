// Mirrors lxmf/AttachmentPolicyTest.kt: attachments travel on Reticulum links only; every other
// bearer carries the text (MESHSAT-1735).
import XCTest

@testable import MeshSatLXMF

final class AttachmentPolicyTests: XCTestCase {
    func testOnlyReticulumCarriesThem() {
        XCTAssertTrue(AttachmentPolicy.carries("lxmf"))
        for t in ["sms", "mesh", "iridium", "hub", "tak"] { XCTAssertFalse(AttachmentPolicy.carries(t), t) }
    }

    func testSendButtonRules() {
        XCTAssertTrue(AttachmentPolicy.canSend("lxmf", text: "", hasAttachments: true))
        XCTAssertFalse(AttachmentPolicy.canSend("sms", text: "", hasAttachments: true), "a note alone cannot go by SMS")
        XCTAssertTrue(AttachmentPolicy.canSend("sms", text: "meet at the bridge", hasAttachments: true), "the transcript can")
        XCTAssertFalse(AttachmentPolicy.canSend("lxmf", text: "  ", hasAttachments: false))
        XCTAssertTrue(AttachmentPolicy.fits(audioBytes: 60_000, imageBytes: 5_536))
        XCTAssertFalse(AttachmentPolicy.fits(audioBytes: 60_000, imageBytes: 5_537))
    }

    func testTheLineUnderTheBox() {
        XCTAssertNil(AttachmentPolicy.note("lxmf", audioBytes: 0, audioMs: 0, imageBytes: 0))
        XCTAssertEqual(
            AttachmentPolicy.note("lxmf", audioBytes: 18 * 1024, audioMs: 12_000, imageBytes: 0),
            "With a voice note 12 s, 18 KB, by Reticulum; the far end sees it once the whole message is across.")
        XCTAssertEqual(
            AttachmentPolicy.note("iridium", audioBytes: 900, audioMs: 800, imageBytes: 3 * 1024),
            "By satellite only the text goes: a voice note 0.8 s, 900 B and photo 3 KB travels by Reticulum alone, so it is not sent.")
        XCTAssertEqual(
            AttachmentPolicy.note("sms", audioBytes: 0, audioMs: 0, imageBytes: 2048),
            "By SMS only the text goes: a photo 2 KB travels by Reticulum alone, so it is not sent.")
        XCTAssertEqual(AttachmentPolicy.bearerName("mesh"), "the mesh")
    }

    func testUnits() {
        XCTAssertEqual(AttachmentPolicy.seconds(30_000), "30 s")
        XCTAssertEqual(AttachmentPolicy.seconds(2_500), "2.5 s")
        XCTAssertEqual(AttachmentPolicy.size(LxFields.maxAttachmentBytes), "64 KB")
        XCTAssertEqual(AttachmentPolicy.size(1023), "1023 B")
        XCTAssertEqual(AttachmentPolicy.maxNoteMs, 30_000)
    }
}
