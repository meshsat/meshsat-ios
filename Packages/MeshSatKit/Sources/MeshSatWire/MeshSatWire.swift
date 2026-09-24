// MeshSatWire: the wire formats MeshSat iOS shares with the Bridge (Go) and MeshSat
// Android (Kotlin). Mirrors, in meshsat-android app/src/main/java/net/meshsat/android/:
// codec/ (Smaz2, PositionCodec, CannedCodebook, ProtocolVersion), dtn/DtnProtocol,
// timesync/TimeSyncProtocol, engine/IridiumFragment, sos/SosMessages, crypto/AesGcmCrypto,
// crypto/KeyBundleImporter (parse and verify), crypto/MsvqscWire, pair/ContactQR,
// hub/HubProtocol, hub/BirthSigner (canonical JSON), channel/.
//
// Every format here is byte-compatible with the Bridge by contract; the golden tests in
// Tests/MeshSatKitTests/Wire carry the Go-produced byte arrays.

public enum MeshSatWire {
    /// The MeshSat protocol version this build speaks, as MeshSat Android's codec/ProtocolVersion.
    public static let module = "MeshSatWire"
}
