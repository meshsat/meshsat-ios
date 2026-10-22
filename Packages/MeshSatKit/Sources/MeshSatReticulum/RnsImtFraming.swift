// Mirrors rns/ImtFraming.kt: IMT framing of Reticulum packets, byte-compatible with CrossTalk's
// IridiumIMTInterface (IridiumIMTCodec) and the Bridge's imt_framing.go. Every Iridium Messaging
// Transport message that carries a Reticulum packet is "RNSI" + version 0x01 + the raw packet. A
// message without the header, or whose remainder is not a Reticulum packet, is a text for the
// plain satellite conversation and never a packet. [MESHSAT-1553, MESHSAT-1624]
import Foundation

public enum RnsImtFraming {
    public static let header: [UInt8] = [0x52, 0x4E, 0x53, 0x49, 0x01]

    /// Upstream Reticulum's header sizes and hop limit, as Android's Rns constants have them: the
    /// context byte is always there, and a packet needs at least one byte of data after it.
    static let headerMinSize = 19
    static let headerMaxSize = 35
    static let hashLen = 16
    static let pathfinderM = 128

    public static func encode(_ packet: [UInt8]) -> [UInt8] { header + packet }

    /// The packet inside an IMT message, or nil when the message is not a framed Reticulum packet
    /// (no magic, another version, nothing after the header, or bytes that do not parse as a
    /// packet header, by the same rules as Android's Header.unpack).
    public static func decode(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > header.count, Array(data.prefix(header.count)) == header else { return nil }
        let rest = Array(data.dropFirst(header.count))
        return isPacket(rest) ? rest : nil
    }

    public static func isFramed(_ data: [UInt8]) -> Bool { decode(data) != nil }

    /// Header.unpack's checks: long enough for its header type, a hop count under PATHFINDER_M,
    /// and a data field that is not empty after the context byte.
    static func isPacket(_ raw: [UInt8]) -> Bool {
        guard raw.count >= headerMinSize, Int(raw[1]) < pathfinderM else { return false }
        var pos = 2
        if raw[0] & 0x40 != 0 {
            guard raw.count >= headerMaxSize else { return false }
            pos += hashLen
        }
        pos += hashLen + 1
        return pos < raw.count
    }
}
