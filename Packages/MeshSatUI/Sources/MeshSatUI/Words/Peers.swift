// Mirrors ui/Peers.kt: who a conversation is with (MESHSAT-1249). A conversation is keyed by the
// other party: a mesh node id ("!a1b2c3d4"), everyone on the mesh, a phone number, or the
// satellite link (the modem's IMEI, which is what an incoming satellite message is filed under).
import Foundation
import MeshSatMeshtastic

public enum Peers {
    /// Everyone on the mesh channel: Meshtastic's own name for a broadcast.
    public static let meshAll = "^all"
    /// The satellite conversation before the modem's IMEI is known.
    public static let satellite = "satellite"
    /// Legacy key of messages sent before the redesign, with no recipient.
    public static let legacySelf = "self"

    public static func isMeshNode(_ peer: String) -> Bool {
        peer.count == 9 && peer.hasPrefix("!") && peer.dropFirst().allSatisfy { $0.isHexDigit }
    }

    public static func isSatellite(_ peer: String) -> Bool { peer == satellite || (peer.count == 15 && peer.allSatisfy { $0.isNumber }) }
    public static func isMesh(_ peer: String) -> Bool { peer == meshAll || isMeshNode(peer) }

    /// The node number of a mesh peer, or nil.
    public static func nodeNum(_ peer: String) -> UInt32? { isMeshNode(peer) ? UInt32(peer.dropFirst(), radix: 16) : nil }

    /// How a reply goes by default: the way this kind of peer is reached.
    public static func defaultTransport(_ peer: String) -> String {
        if isMesh(peer) { return "mesh" }
        if isSatellite(peer) || peer == legacySelf { return "iridium" }
        return "sms"
    }

    /// The ways a message to this peer can go.
    public static func transportsFor(_ peer: String) -> [String] { [defaultTransport(peer)] }

    /// What the user calls this peer.
    public static func displayName(_ peer: String, nodes: [MeshtasticProtocol.MeshNodeInfo] = []) -> String {
        if peer == meshAll { return "Everyone on the mesh" }
        if isMeshNode(peer) {
            if let node = nodes.first(where: { MeshtasticProtocol.formatNodeId($0.nodeNum) == peer }), !node.longName.isEmpty {
                return node.longName
            }
            return "Node \(peer)"
        }
        if isSatellite(peer) { return "Satellite" }
        if peer == legacySelf { return "Sent from this phone" }
        return peer
    }

    /// A second line under the name: the id people may need, never the modem's IMEI.
    public static func detail(_ peer: String) -> String? {
        if isMeshNode(peer) { return peer }
        if isSatellite(peer) { return "By satellite, through Rock7 to the Hub" }
        if peer == meshAll { return "The mesh channel" }
        return nil
    }
}
