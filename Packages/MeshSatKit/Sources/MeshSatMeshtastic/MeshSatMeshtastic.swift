// MeshSatMeshtastic: the platform-free half of MeshSat Android's ble/ and bt/ packages.
// ble/MeshtasticProtocol + MeshtasticProtoAdapter, ble/NodeProfile, ble/NodeBattery,
// ble/GattOpQueue, ble/IridiumPipeStreams and bt/IridiumSpp (the 9603 AT driver, here
// IridiumATDriver over a ModemLink) are ported into this module. CoreBluetooth itself is in
// Packages/MeshSatApple (MeshSatBLE).
import Foundation
import MeshSatNet

public enum MeshSatMeshtastic {
    public static let module = "MeshSatMeshtastic"
}

/// The clock the drivers and the engine run on lives in MeshSatNet; the names stay here for
/// the driver's callers and tests.
public typealias DriverClock = MeshSatNet.DriverClock
public typealias SystemDriverClock = MeshSatNet.SystemDriverClock
