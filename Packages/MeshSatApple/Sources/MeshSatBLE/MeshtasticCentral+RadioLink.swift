// The BLE central as the Reticulum mesh interface sees it (reticulum/RnsMeshtasticBleInterface.kt
// takes the MeshtasticBle): ToRadio out, every FromRadio in, connected or not.
import MeshSatReticulum

extension MeshtasticCentral: MeshRadioLink {
    public var isConnected: Bool { state.value == .connected }
}
