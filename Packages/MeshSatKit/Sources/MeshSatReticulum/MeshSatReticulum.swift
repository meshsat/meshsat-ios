// MeshSatReticulum: the Reticulum transport node of MeshSat Android (reticulum/, 24 files, and
// the parts of routing/ still wired by GatewayService). Identities are Ed25519 + X25519, links
// use HKDF-SHA256 and AES-256-GCM (MeshSat mode 0x01) or AES-256-CBC (Reticulum-compatible
// mode 0x00). Interfaces over the mesh, the Iridium pipe, MQTT, TCP and the Hub relay live
// here; the BLE peripheral is in Packages/MeshSatApple.

public enum MeshSatReticulum {
    public static let module = "MeshSatReticulum"

    /// The GATT server other phones connect to (reticulum/RnsBlePeripheralInterface.kt).
    public enum BleContract {
        public static let serviceUUID = "a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
        public static let txUUID = "a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5e"
        public static let rxUUID = "a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5f"
    }
}
