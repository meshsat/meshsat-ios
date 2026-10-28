// MeshSatLXMF: the Lightweight Extensible Message Format on MeshSatRns, mirroring MeshSat
// Android's lxmf/ package, itself a port of the Bridge's internal/lxmf, written against Python
// LXMF 1.2.x (LXMF/LXMessage.py, LXMF/LXMF.py, LXMF/LXStamper.py, LXMF/LXMRouter.py). The
// vectors every test here reads were written by Python LXMF (Android's golden.properties) and by
// the Bridge's Go code (go-vectors.properties), so the three implementations pack one message
// to the same bytes. Tranche 1 (MESHSAT-1735): the message, the mid, the audio and image
// fields, the announce app data and the stamps. The router (links, resources, propagation),
// the transport binding and the screens are the next tranches (docs/LXMF_PORT.md).

public enum MeshSatLXMF {
    public static let module = "MeshSatLXMF"
}
