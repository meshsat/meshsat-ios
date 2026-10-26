// Mirrors ui/Peers.kt: who a conversation is with (MESHSAT-1249). A conversation is keyed by the
// other party: a mesh node id ("!a1b2c3d4"), everyone on the mesh, a phone number, or the
// satellite link (the modem's IMEI, which is what an incoming satellite message is filed under).
import Foundation
import MeshSatHub
import MeshSatMeshtastic
import MeshSatTak

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

    /// Another MeshSat app or kit through the Hub: "bridge:<id>", the Hub's principal (MESHSAT-1584).
    public static let hubPrefix = "bridge:"
    public static func isHub(_ peer: String) -> Bool { !HubMsgWire.bridgeOf(peer).isEmpty }
    /// The principal of a bridge id, as a conversation key.
    public static func hubPeer(_ bridgeId: String) -> String { hubPrefix + bridgeId.trimmingCharacters(in: .whitespaces) }

    /// A dispatcher on TAK, or an operator on the Hub's map, who wrote to this phone (MESHSAT-1708):
    /// "tak:<uid>#<callsign>", the key TakChats.peer writes.
    public static func isTak(_ peer: String) -> Bool { TakChats.isPeer(peer) }
    public static func takPeer(_ uid: String, _ callsign: String) -> String { TakChats.peer(uid: uid, callsign: callsign) }
    public static func takUid(_ peer: String) -> String { TakChats.uid(ofPeer: peer) }
    public static func takCallsign(_ peer: String) -> String { TakChats.callsign(ofPeer: peer) }

    /// The node number of a mesh peer, or nil.
    public static func nodeNum(_ peer: String) -> UInt32? { isMeshNode(peer) ? UInt32(peer.dropFirst(), radix: 16) : nil }

    /// How a reply goes by default: the way this kind of peer is reached.
    public static func defaultTransport(_ peer: String) -> String {
        if isTak(peer) { return "tak" }
        if isHub(peer) { return "hub" }
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
        if isHub(peer) { return String(peer.dropFirst(hubPrefix.count)) }
        if isTak(peer) { return takCallsign(peer).isEmpty ? takUid(peer) : takCallsign(peer) }
        return peer
    }

    /// A second line under the name: the id people may need, never the modem's IMEI.
    public static func detail(_ peer: String) -> String? {
        if isMeshNode(peer) { return peer }
        if isSatellite(peer) { return "By satellite, through Rock7 to the Hub" }
        if peer == meshAll { return "The mesh channel" }
        if isHub(peer) { return "Through the Hub to its MeshSat app" }
        if isTak(peer) { return "On TAK, through the Hub" }
        return nil
    }
}
