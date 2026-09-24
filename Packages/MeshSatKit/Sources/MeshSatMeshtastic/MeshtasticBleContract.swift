// Mirrors the constants of ble/MeshtasticBle.kt: the Meshtastic BLE service and its three
// characteristics, and the MTU the phone asks for. CoreBluetooth lives in Packages/MeshSatApple;
// this module holds only what is platform-free.

public enum MeshtasticBleContract {
    public static let serviceUUID = "6ba1b218-15a8-461f-9fa8-5dcae273eafd"
    /// Phone to radio: write a ToRadio protobuf.
    public static let toRadioUUID = "f75c76d2-129e-4dad-a1dd-7866124401e7"
    /// Radio to phone: read a FromRadio protobuf; an empty read means the queue is drained.
    public static let fromRadioUUID = "2c55e69e-4993-11ed-b878-0242ac120002"
    /// Notifies when FromRadio has something new.
    public static let fromNumUUID = "ed9da18c-a800-4f66-a670-aa7547de15e6"
    public static let clientCharacteristicConfigUUID = "00002902-0000-1000-8000-00805f9b34fb"
    /// What Android requests; iOS takes what CoreBluetooth reports instead.
    public static let requestedMtu = 517
    /// The LoRa payload budget Reticulum's Meshtastic interface fragments against.
    public static let loraPayloadBudget = 230
    /// Meshtastic portnum used for Reticulum frames (PRIVATE_APP).
    public static let reticulumPortnum: UInt32 = 256
}
