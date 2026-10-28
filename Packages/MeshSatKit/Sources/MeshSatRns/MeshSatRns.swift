// MeshSatRns: the Reticulum wire format byte for byte as Python RNS 1.5.x writes it, mirroring
// MeshSat Android's rns/ package (which ports the Bridge's internal/reticulum and
// internal/msgpack). Nothing in here knows about sockets, radios or the app.
//
// The older MeshSatReticulum module is NOT this format: its RnsPacket omits the context byte
// unless the context flag is set, its RnsAnnounce reads a 10-byte ratchet id and it has its own
// link handshake. It stays for the MeshSat-private traffic (meshsat.node, HeMB, time sync, the
// Hub relay); this module is what an lxmf.delivery destination and a stock Reticulum peer speak.
// Tranche 1 (MESHSAT-1735): msgpack, identity, header, announce, token. The node, links, paths,
// resources and IFAC follow in the next tranche (docs/LXMF_PORT.md).

public enum MeshSatRns {
    public static let module = "MeshSatRns"
}
