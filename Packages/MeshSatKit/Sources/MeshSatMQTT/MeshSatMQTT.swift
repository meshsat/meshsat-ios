// MeshSatMQTT: the MQTT 3.1.1 session the Hub reporter uses (Android: Eclipse Paho behind
// mqtt/MqttTransport.kt, mqtt/PahoClients.kt, CertificatePinner.kt, SniSSLSocketFactory.kt),
// here on swift-server-community/mqtt-nio so that it runs on Linux in tests and on
// NIOTransportServices on the phone. TLS is NIOSSL with the client certificate from PEM,
// SNI forced to the broker host, and SPKI pins checked in the verification callback.

public enum MeshSatMQTT {
    public static let module = "MeshSatMQTT"
}

/// What MeshSatHub needs from an MQTT client; MqttNioSession implements it.
public protocol MQTTSession: Sendable {
    func connect() async throws
    func publish(topic: String, payload: [UInt8], qos: Int, retain: Bool) async throws
    func subscribe(_ topics: [String]) async throws
    func disconnect() async
}
