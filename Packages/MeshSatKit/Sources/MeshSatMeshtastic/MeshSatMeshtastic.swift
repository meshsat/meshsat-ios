// MeshSatMeshtastic: the platform-free half of MeshSat Android's ble/ and bt/ packages.
// ble/MeshtasticProtocol + MeshtasticProtoAdapter, ble/NodeProfile, ble/NodeBattery,
// ble/GattOpQueue, ble/IridiumPipeStreams and bt/IridiumSpp (the 9603 AT driver, here
// IridiumATDriver over a ModemLink) are ported into this module. CoreBluetooth itself is in
// Packages/MeshSatApple (MeshSatBLE).

public enum MeshSatMeshtastic {
    public static let module = "MeshSatMeshtastic"
}

/// The link the 9603 AT driver talks over: Android's ModemLink, backed by the BLE pipe on
/// the phone and by a scripted fake in the tests.
public protocol ModemLink: Sendable {
    func write(_ bytes: [UInt8]) async throws
    var incoming: AsyncStream<[UInt8]> { get }
    func clear() async
}
