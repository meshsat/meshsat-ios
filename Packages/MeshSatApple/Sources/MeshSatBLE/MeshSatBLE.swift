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

    public static let meshtasticService = CBUUID(string: MeshtasticBleContract.serviceUUID)
    public static let iridiumPipeService = CBUUID(string: IridiumPipeContract.serviceUUID)
}
