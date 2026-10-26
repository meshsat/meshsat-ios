// Mirrors tak/TakChats.kt: chats addressed to this phone on TAK (MESHSAT-1708). A dispatcher in a
// TAK client, or an operator on the Hub's map, writes to one crew, and the Hub hands the chat to
// the phone that owns that crew on its own tak/cot/in.
import Foundation

public enum TakChats {
    /// A chat a dispatcher wrote to this phone.
    public struct Chat: Sendable, Equatable {
        public let fromUid: String
        public let fromCallsign: String
        public let text: String
        public init(fromUid: String, fromCallsign: String, text: String) {
            self.fromUid = fromUid
            self.fromCallsign = fromCallsign
            self.text = text
        }
    }

    /// The chat `ev` is, when it is a GeoChat addressed to `ownUid` or `ownCallsign`: by the server
    /// routing (`<marti><dest>`, by uid or by callsign) or, without one, by `__chat`. A chat to the
    /// room, to somebody else, from this phone itself, or with no words is not.
    public static func chatFor(_ ev: CotEvent, ownUid: String, ownCallsign: String) -> Chat? {
        guard ev.type == CotType.chat, let d = ev.detail else { return nil }
        let text = (d.remarks?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = d.link?.uid ?? ""
        let fromUid = linked.isEmpty ? (d.chat?.uid0 ?? "") : linked
        let named = d.chat?.senderCallsign ?? ""
        let fromCallsign = named.isEmpty ? (d.contact?.callsign ?? "") : named
        if text.isEmpty || (fromUid.isEmpty && fromCallsign.isEmpty) || fromUid == ownUid { return nil }
        let toMe =
            d.marti.isEmpty
            ? d.chat?.id == ownUid || d.chat?.uid1 == ownUid
            : d.marti.contains { $0.uid == ownUid || ($0.uid.isEmpty && $0.callsign == ownCallsign) }
        return toMe ? Chat(fromUid: fromUid, fromCallsign: fromCallsign, text: text) : nil
    }

    /// A dispatcher on TAK, or an operator on the Hub's map, as a conversation key (Peers.kt
    /// TAK_PREFIX): "tak:<uid>#<callsign>". The callsign is in the key so the conversation can be
    /// named; a TAK uid has no "#".
    public static let peerPrefix = "tak:"

    public static func peer(uid: String, callsign: String) -> String { "\(peerPrefix)\(uid)#\(callsign)" }

    public static func isPeer(_ peer: String) -> Bool { peer.hasPrefix(peerPrefix) && !uid(ofPeer: peer).isEmpty }

    public static func uid(ofPeer peer: String) -> String {
        guard peer.hasPrefix(peerPrefix) else { return "" }
        let rest = peer.dropFirst(peerPrefix.count)
        return String(rest.prefix { $0 != "#" })
    }

    public static func callsign(ofPeer peer: String) -> String {
        guard peer.hasPrefix(peerPrefix), let hash = peer.firstIndex(of: "#") else { return "" }
        return String(peer[peer.index(after: hash)...])
    }
}
