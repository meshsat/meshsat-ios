// Mirrors the Bridge's internal/lxmf/fields.go (MESHSAT-1735; Android holds the field numbers
// in LxMessage.kt and no attachment code yet): the LXMF fields a voice note and a photo travel
// in (LXMF/LXMF.py). FIELD_AUDIO is [mode, bytes] with the audio mode below, FIELD_IMAGE is
// [format, bytes] with the format name ("webp"). They are what Sideband and MeshChat send, so a
// note or a photo from either plays here and one from here plays there, with nothing
// MeshSat-specific on the wire. The fields are part of the packed message: a message that
// outgrows one packet goes as a resource with them inside, as upstream does.
import Foundation
import MeshSatRns

public enum LxAttachmentKind: String, Sendable, Equatable {
    case audio
    case image
}

/// One audio or image field of a message.
public struct LxAttachment: Sendable, Equatable {
    public let kind: LxAttachmentKind
    /// Audio: the LXMF audio mode.
    public let mode: Int
    /// Image: the format name, lower case ("webp").
    public let format: String
    public let data: [UInt8]

    public init(kind: LxAttachmentKind, mode: Int = 0, format: String = "", data: [UInt8]) {
        self.kind = kind
        self.mode = mode
        self.format = format
        self.data = data
    }

    public static func audio(mode: Int, data: [UInt8]) -> LxAttachment { LxAttachment(kind: .audio, mode: mode, data: data) }
    public static func image(format: String, data: [UInt8]) -> LxAttachment { LxAttachment(kind: .image, format: format, data: data) }

    /// The attachment's shape: a known audio mode or a plain image format name, and some bytes.
    public func validate() throws {
        guard !data.isEmpty else { throw LxmfError("attachment has no bytes") }
        switch kind {
        case .audio:
            guard LxFields.audioModeKnown(mode) else {
                throw LxmfError(String(format: "unknown audio mode 0x%02x", UInt32(truncatingIfNeeded: mode)))
            }
        case .image:
            guard !format.isEmpty, format.utf8.count <= 8 else { throw LxmfError("image format must be 1 to 8 characters") }
            for c in format.utf8 where !((c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)) {
                throw LxmfError("image format must be lower-case letters and digits")
            }
        }
    }

    /// The media type a client plays or shows the bytes as: Codec2 frames as audio/codec2 (the
    /// mode goes in a header, the bytes carry none), Opus as the Ogg stream it is, an image as
    /// image/<format>.
    public var contentType: String {
        switch kind {
        case .audio:
            if mode >= LxFields.audioModeCodec2First && mode <= LxFields.audioModeCodec2Last { return "audio/codec2" }
            if mode >= LxFields.audioModeOpusFirst && mode <= LxFields.audioModeOpusLast { return "audio/ogg" }
        case .image:
            switch format {
            case LxFields.imageWebP, "png", "gif", "bmp", "avif": return "image/" + format
            case "jpg", "jpeg": return "image/jpeg"
            default: break
            }
        }
        return "application/octet-stream"
    }

    /// A short line for a log or a ledger row: "audio Codec2 700C 1024 B", "image webp 2048 B".
    public var describe: String {
        switch kind {
        case .audio: return "audio \(LxFields.audioModeName(mode)) \(data.count) B"
        case .image: return "image \(format) \(data.count) B"
        }
    }
}

public enum LxFields {
    public static let fieldImage = LxMessage.fieldImage
    public static let fieldAudio = LxMessage.fieldAudio

    // Audio modes (LXMF.py AM_*): Codec2 modes 0x01-0x09 (700C, the default for a satellite,
    // is 0x03), Opus modes 0x10-0x19 (the bytes are an Ogg Opus stream), and 0xFF for a custom
    // codec the two ends agreed on.
    public static let audioModeCodec2First = 0x01
    public static let audioMode700C = 0x03
    public static let audioModeCodec2Last = 0x09
    public static let audioModeOpusFirst = 0x10
    public static let audioModeOpusLast = 0x19
    public static let audioModeCustom = 0xFF

    /// The one image format every client writes.
    public static let imageWebP = "webp"

    /// What one message's attachments may weigh together: a 10 s Codec2 700C note is about 1 KB
    /// and a 320 px WebP a few KB, so 64 KB holds every note and photo a kit or the Hub should
    /// carry and keeps a store of them bounded by count.
    public static let maxAttachmentBytes = 64 * 1024

    private static let codec2Names: [Int: String] = [
        0x01: "450PWB", 0x02: "450", 0x03: "700C", 0x04: "1200", 0x05: "1300", 0x06: "1400", 0x07: "1600", 0x08: "2400",
        0x09: "3200",
    ]

    private static let opusNames: [Int: String] = [
        0x10: "OGG", 0x11: "LBW", 0x12: "MBW", 0x13: "PTT", 0x14: "RT_HDX", 0x15: "RT_FDX", 0x16: "STANDARD", 0x17: "HQ",
        0x18: "BROADCAST", 0x19: "LOSSLESS",
    ]

    /// The mode's name as LXMF.py spells it ("Codec2 700C", "Opus OGG", "custom"), or "mode 0x.." for one it does not know.
    public static func audioModeName(_ mode: Int) -> String {
        if let n = codec2Names[mode] { return "Codec2 " + n }
        if let n = opusNames[mode] { return "Opus " + n }
        if mode == audioModeCustom { return "custom" }
        return String(format: "mode 0x%02x", UInt32(truncatingIfNeeded: mode))
    }

    /// Whether `mode` is one LXMF.py names.
    public static func audioModeKnown(_ mode: Int) -> Bool {
        codec2Names[mode] != nil || opusNames[mode] != nil || mode == audioModeCustom
    }

    public static func describeAttachments(_ atts: [LxAttachment]) -> String { atts.map(\.describe).joined(separator: ", ") }

    public static func attachmentBytes(_ atts: [LxAttachment]) -> Int { atts.reduce(0) { $0 + $1.data.count } }

    /// The audio and image fields of a received message, the image first (field order), each
    /// only when it has the documented shape; a field of another shape is left where it is and
    /// not reported.
    public static func attachmentsOf(_ fields: [MpEntry]) -> [LxAttachment] {
        let v = MpValue.map(fields)
        var out = [LxAttachment]()
        if let img = v[fieldImage]?.asArray, img.count == 2, let formatBytes = img[0].asBytes,
            case .bin(let data) = img[1], !data.isEmpty
        {
            let format = String(decoding: formatBytes, as: UTF8.self).lowercased()
            if !format.isEmpty { out.append(.image(format: format, data: data)) }
        }
        if let aud = v[fieldAudio]?.asArray, aud.count == 2, let mode = aud[0].asInt, case .bin(let data) = aud[1], !data.isEmpty {
            out.append(.audio(mode: Int(mode), data: data))
        }
        return out
    }

    /// The fields with the attachments put in, one audio and one image at most, replacing a
    /// field of the same kind. Every attachment is validated and their total must fit
    /// maxAttachmentBytes; an error leaves the input as it was.
    public static func withAttachments(_ fields: [MpEntry], _ atts: [LxAttachment]) throws -> [MpEntry] {
        if atts.isEmpty { return fields }
        if attachmentBytes(atts) > maxAttachmentBytes { throw LxmfError.attachmentsTooLarge }
        var seen = Set<LxAttachmentKind>()
        for a in atts {
            try a.validate()
            guard seen.insert(a.kind).inserted else { throw LxmfError("more than one \(a.kind.rawValue) attachment") }
        }
        var out = withoutAttachments(fields)
        for a in atts {
            switch a.kind {
            case .audio: out.append(MpEntry(.int(fieldAudio), .array([.int(Int64(a.mode)), .bin(a.data)])))
            case .image: out.append(MpEntry(.int(fieldImage), .array([.str(a.format), .bin(a.data)])))
            }
        }
        return out
    }

    /// The fields without their audio and image fields.
    public static func withoutAttachments(_ fields: [MpEntry]) -> [MpEntry] {
        fields.filter { e in
            guard let k = e.key.asInt else { return true }
            return k != fieldAudio && k != fieldImage
        }
    }
}
