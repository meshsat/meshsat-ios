// MeshSatRns: the Reticulum wire format byte for byte as Python RNS 1.5.x writes it, mirroring
// MeshSat Android's rns/ package (which ports the Bridge's internal/reticulum and
// internal/msgpack). Nothing in here knows about sockets, radios or the app.
//
// The older MeshSatReticulum module is NOT this format: its RnsPacket omits the context byte
// unless the context flag is set, its RnsAnnounce reads a 10-byte ratchet id and it has its own
// link handshake. It stays for the MeshSat-private traffic (meshsat.node, time sync, the
// Hub relay); this module is what an lxmf.delivery destination and a stock Reticulum peer speak.
// Tranche 1 (MESHSAT-1735): msgpack, identity, header, announce, token. Tranches 2 and 3 (7 Nov
// 2026): LinkWire, Proof and Ifac, and the node under Node/ (Node, Link, Resource, Requests,
// Receipts, Transport, AnnounceHandling, PathRequests, Paths, PaidLinks), mirroring rns/*.kt file
// by file; Promise in MeshSatNet stands in for CompletableFuture. The router, the propagation
// client and the transport binding follow (docs/LXMF_PORT.md).

public enum MeshSatRns {
    public static let module = "MeshSatRns"
}
