// MeshSatBLE: CoreBluetooth for the MeshSat node. Mirrors ble/MeshtasticBle.kt (the GATT
// client, MESHSAT-1322), ble/IridiumBlePipe.kt (the modem pipe on the same connection,
// MESHSAT-1323) and reticulum/RnsBlePeripheralInterface.kt (the GATT server, MESHSAT-1326).
// The platform-free contracts (UUIDs, status bytes, the AT driver) are in MeshSatMeshtastic.
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
