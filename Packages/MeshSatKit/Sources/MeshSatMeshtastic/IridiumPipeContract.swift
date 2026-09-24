// Mirrors ble/IridiumBlePipe.kt's IridiumPipeContract: the node's serial pipe from Bluetooth
// to the RockBLOCK 9603 (meshsat-esp32 docs/IRIDIUM-BLE.md owns this contract; changes go
// through that repo). The pipe runs on the same GATT connection as the Meshtastic service.

public enum IridiumPipeContract {
    public static let serviceUUID = "b3d305a2-7310-4877-ad12-8e245e71951a"
    /// Phone to modem, write.
    public static let rxUUID = "b9e2d4ba-f386-4728-b77a-7df7121db7a9"
    /// Modem to phone, notify. Subscribing to TX is what claims the modem.
    public static let txUUID = "469354dc-4c89-41ed-b939-d707c7a11f49"
    /// [version = 1, owner]. Read after subscribing, and notified on change.
    public static let statusUUID = "69a4064d-78b9-46e5-a30a-1862e553245a"

    /// The node buffers this much inbound data; writes are paced against it.
    public static let nodeInboundBytes = 1024
    /// Chunks smaller than this are never sent (the node's pipe reads at least 20 bytes).
    public static let minChunkBytes = 20
    public static let statusVersion: UInt8 = 1

    public enum Owner: UInt8, Sendable, Equatable {
        case none = 0
        case phone = 1
        case node = 2
    }

    public struct Status: Sendable, Equatable {
        public let version: UInt8
        public let owner: Owner
        public init(version: UInt8, owner: Owner) {
            self.version = version
            self.owner = owner
        }
    }

    /// nil for an empty value, an unknown version or an unknown owner byte, as Android's parseStatus.
    public static func parseStatus(_ bytes: [UInt8]) -> Status? {
        guard bytes.count >= 2, bytes[0] == statusVersion, let owner = Owner(rawValue: bytes[1]) else { return nil }
        return Status(version: bytes[0], owner: owner)
    }
}
