// Mirrors lxmf/AttachmentPolicy.kt (MESHSAT-1735): where a voice note or a photo may travel. Only on
// a Reticulum link, as the Bridge's lxmf_0 carries them; every other bearer gets the text alone (a
// satellite frame, a text message, a LongFast packet or the Hub's message route cannot take the
// bytes), and the person is told so before sending, with the size and never a price.
import Foundation

public enum AttachmentPolicy {
    /// The conversation transport that carries attachments: the LXMF endpoint over Reticulum.
    public static let lxmf = "lxmf"

    /// A voice note is at most this long; longer is refused before it is encoded.
    public static let maxNoteMs: Int64 = 30_000

    /// Whether a message on `transport` takes its attachments along.
    public static func carries(_ transport: String) -> Bool { transport == lxmf }

    /// What the person sees as a bearer: the composer's words for it.
    public static func bearerName(_ transport: String) -> String {
        switch transport {
        case "iridium": "satellite"
        case "sms": "SMS"
        case "mesh": "the mesh"
        case "hub": "the Hub"
        case "tak": "TAK"
        case lxmf: "Reticulum"
        default: transport
        }
    }

    /// "12 s" or "0.8 s".
    public static func seconds(_ ms: Int64) -> String {
        ms >= 10_000 ? "\(ms / 1000) s" : String(format: "%.1f s", Double(ms) / 1000)
    }

    /// "18 KB" or "640 B".
    public static func size(_ bytes: Int) -> String { bytes >= 1024 ? "\((bytes + 512) / 1024) KB" : "\(bytes) B" }

    /// The one line under the message box before a send that has attachments pending: what goes,
    /// what stays, and how big it is. Nil when nothing is attached.
    public static func note(_ transport: String, audioBytes: Int, audioMs: Int64, imageBytes: Int) -> String? {
        var parts: [String] = []
        if audioBytes > 0 { parts.append("voice note \(seconds(audioMs)), \(size(audioBytes))") }
        if imageBytes > 0 { parts.append("photo \(size(imageBytes))") }
        guard !parts.isEmpty else { return nil }
        let what = parts.joined(separator: " and ")
        if carries(transport) {
            return "With a \(what), by Reticulum; the far end sees it once the whole message is across."
        }
        return "By \(bearerName(transport)) only the text goes: a \(what) travels by Reticulum alone, so it is not sent."
    }

    /// Whether the send button may act: a text goes anywhere; without one, only a Reticulum message
    /// with an attachment has something to send.
    public static func canSend(_ transport: String, text: String, hasAttachments: Bool) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (hasAttachments && carries(transport))
    }

    /// Whether the bytes fit the wire: the two together under `LxFields.maxAttachmentBytes`.
    public static func fits(audioBytes: Int, imageBytes: Int) -> Bool { audioBytes + imageBytes <= LxFields.maxAttachmentBytes }
}
