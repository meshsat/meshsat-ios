// MeshSatHub: mirrors hub/HubReporter.kt (the meshsat-uplink/v1 MQTT contract: birth, death,
// health, positions, commands, MO acks), crypto/ProvisionImporter + ProvisionClaim (the QR and
// meshsat://provision deep link) and hub/relay/ (the WebSocket tunnel to a kit) over the
// MeshSatNet and MeshSatMQTT protocols.

public enum MeshSatHub {
    public static let module = "MeshSatHub"
    public static let defaultBrokerUrl = "wss://mqtt-hub.meshsat.net/mqtt"
    public static let protocolVersion = "meshsat-uplink/v1"
    public static let clientIdPrefix = "meshsat-ios-"
}
