// Mirrors the Bridge's internal/lxmf/fields_test.go: the audio and image fields pack like
// upstream, keep the other fields, and refuse what they must. [MESHSAT-1735]
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatRns

final class LxFieldsTests: XCTestCase {
    /// The smallest valid WebP: a 1x1 lossless (VP8L) image, 34 bytes (fields_test.go testWebP).
    private let webp: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c,
        0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07, 0x00,
    ]
    private let frames: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7]

    func testAttachmentsKeepTheOtherFields() throws {
        var mid = [UInt8](repeating: 0, count: 16)
        mid[0] = 7
        var fields = try LxFields.withAttachments(LxMid.fields(mid), [.audio(mode: LxFields.audioMode700C, data: frames)])
        XCTAssertEqual(LxMid.midOf(fields), mid, "the mid did not survive")
        // Replacing the audio keeps one audio field.
        fields = try LxFields.withAttachments(fields, [.audio(mode: 0x10, data: Array("ogg".utf8))])
        let atts = LxFields.attachmentsOf(fields)
        XCTAssertEqual(atts.count, 1)
        XCTAssertEqual(atts.first?.mode, 0x10)
        XCTAssertEqual(fields.count, 3)
        let bare = LxFields.withoutAttachments(fields)
        XCTAssertEqual(LxFields.attachmentsOf(bare), [])
        XCTAssertEqual(bare.count, 2)
        XCTAssertEqual(LxMid.midOf(bare), mid, "the mid went with the attachments")
        XCTAssertEqual(LxFields.attachmentsOf(fields).count, 1, "withoutAttachments changed its input")
    }

    func testAttachmentsRefused() throws {
        let ok = LxAttachment.audio(mode: LxFields.audioMode700C, data: frames)
        struct Refused {
            let name: String
            let atts: [LxAttachment]
            let want: LxmfError?
        }
        let cases = [
            Refused(
                name: "too large", atts: [.image(format: "webp", data: [UInt8](repeating: 0, count: LxFields.maxAttachmentBytes + 1))],
                want: .attachmentsTooLarge),
            Refused(
                name: "together",
                atts: [
                    .image(format: "webp", data: [UInt8](repeating: 0, count: LxFields.maxAttachmentBytes - 1)),
                    .audio(mode: 3, data: [1, 2]),
                ],
                want: .attachmentsTooLarge),
            Refused(name: "two audios", atts: [ok, ok], want: nil),
            Refused(name: "bad mode", atts: [.audio(mode: 0x0A, data: frames)], want: nil),
            Refused(name: "no bytes", atts: [.audio(mode: 3, data: [])], want: nil),
            Refused(name: "bad format", atts: [.image(format: "WebP", data: webp)], want: nil),
            Refused(name: "long", atts: [.image(format: String(repeating: "a", count: 9), data: webp)], want: nil),
            Refused(name: "empty format", atts: [.image(format: "", data: webp)], want: nil),
        ]
        for c in cases {
            XCTAssertThrowsError(try LxFields.withAttachments([], c.atts), c.name) { error in
                if let want = c.want { XCTAssertEqual(error as? LxmfError, want, c.name) }
            }
        }
        // Exactly the cap is fine, and no attachments leaves the input alone.
        XCTAssertNoThrow(
            try LxFields.withAttachments([], [.image(format: "webp", data: [UInt8](repeating: 0, count: LxFields.maxAttachmentBytes))]))
        let input = [MpEntry(.str("x"), .null)]
        XCTAssertEqual(try LxFields.withAttachments(input, []), input)
    }

    /// A field of another shape is not an attachment: it stays in the map and is not reported.
    func testAttachmentsOfIgnoresOtherShapes() {
        let fields: [MpEntry] = [
            MpEntry(.int(LxFields.fieldAudio), .bin(frames)),
            MpEntry(.int(LxFields.fieldImage), .array([.str("webp")])),
            MpEntry(.str("7"), .array([.int(3), .bin(frames)])),
            MpEntry(.int(LxFields.fieldImage + 100), .array([.str("webp"), .bin(webp)])),
        ]
        XCTAssertEqual(LxFields.attachmentsOf(fields), [])
        XCTAssertEqual(LxFields.withoutAttachments(fields).count, 2, "the two under the field numbers go, whatever their shape")
        XCTAssertEqual(LxFields.attachmentsOf([]), [])
        // An image format sent as bytes, upper case, is read all the same.
        let v = [MpEntry(.int(LxFields.fieldImage), .array([.bin(Array("WEBP".utf8)), .bin(webp)]))]
        XCTAssertEqual(LxFields.attachmentsOf(v), [.image(format: "webp", data: webp)])
        // An empty image or a str payload is not reported.
        XCTAssertEqual(LxFields.attachmentsOf([MpEntry(.int(LxFields.fieldImage), .array([.str("webp"), .bin([])]))]), [])
        XCTAssertEqual(LxFields.attachmentsOf([MpEntry(.int(LxFields.fieldAudio), .array([.int(3), .str("abc")]))]), [])
    }

    func testAttachmentNames() {
        let a = LxAttachment.audio(mode: LxFields.audioMode700C, data: frames)
        XCTAssertEqual(a.contentType, "audio/codec2")
        XCTAssertEqual(a.describe, "audio Codec2 700C 16 B")
        let o = LxAttachment.audio(mode: 0x16, data: frames)
        XCTAssertEqual(o.contentType, "audio/ogg")
        XCTAssertEqual(LxFields.audioModeName(0x16), "Opus STANDARD")
        let i = LxAttachment.image(format: "webp", data: webp)
        XCTAssertEqual(i.contentType, "image/webp")
        XCTAssertEqual(i.describe, "image webp 34 B")
        XCTAssertEqual(LxAttachment.image(format: "jpg", data: [1]).contentType, "image/jpeg")
        XCTAssertEqual(LxAttachment.image(format: "tiff", data: [1]).contentType, "application/octet-stream")
        XCTAssertEqual(LxAttachment.audio(mode: 0xFF, data: [1]).contentType, "application/octet-stream")
        XCTAssertEqual(LxFields.audioModeName(0xFF), "custom")
        XCTAssertEqual(LxFields.audioModeName(0x0A), "mode 0x0a")
        XCTAssertFalse(LxFields.audioModeKnown(0x0A))
        XCTAssertTrue(LxFields.audioModeKnown(0xFF))
        XCTAssertEqual(LxFields.describeAttachments([i, a]), "image webp 34 B, audio Codec2 700C 16 B")
        XCTAssertEqual(LxFields.describeAttachments([]), "")
        XCTAssertEqual(LxFields.attachmentBytes([i, a]), 50)
        XCTAssertEqual(LxFields.fieldAudio, 0x07)
        XCTAssertEqual(LxFields.fieldImage, 0x06)
        XCTAssertNoThrow(try LxAttachment.image(format: "png2", data: [1]).validate())
    }
}
