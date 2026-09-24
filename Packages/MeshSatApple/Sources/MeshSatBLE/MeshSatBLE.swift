// MeshSatBLE: CoreBluetooth for the MeshSat node. MeshtasticCentral mirrors ble/MeshtasticBle.kt
// (the GATT client, MESHSAT-1322) and carries the node's Iridium pipe (ble/IridiumBlePipe.kt,
// MESHSAT-1323, whose logic is IridiumBlePipe in MeshSatMeshtastic); the Reticulum GATT server
// (reticulum/RnsBlePeripheralInterface.kt, MESHSAT-1326) follows. The platform-free contracts
// (UUIDs, status bytes, the AT driver, the radio state) are in MeshSatMeshtastic.
import CoreBluetooth
import MeshSatMeshtastic

public enum MeshSatBLE {
    public static let module = "MeshSatBLE"
    /// CBCentralManagerOptionRestoreIdentifierKey: iOS relaunches the app for this central.
    public static let centralRestoreIdentifier = "net.meshsat.ios.central"
    /// CBPeripheralManagerOptionRestoreIdentifierKey for the Reticulum GATT server.
    public static let peripheralRestoreIdentifier = "net.meshsat.ios.peripheral"

    // Computed, not stored: CBUUID is not Sendable, so a stored static would be shared mutable
    // state under Swift 6's strict concurrency.
    public static var meshtasticService: CBUUID { CBUUID(string: MeshtasticBleContract.serviceUUID) }
    public static var iridiumPipeService: CBUUID { CBUUID(string: IridiumPipeContract.serviceUUID) }
}
