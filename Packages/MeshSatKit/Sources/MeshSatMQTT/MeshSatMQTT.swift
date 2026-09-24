// MeshSatMQTT: the MQTT 3.1.1 session the Hub reporter and the device transport use (Android:
// Eclipse Paho behind mqtt/MqttTransport.kt, PahoClients.kt, CertificatePinner.kt,
// SniSSLSocketFactory.kt), here on swift-server-community/mqtt-nio: NIOSSL on Linux and macOS,
// Network.framework on the phone. The session contract itself (MQTTSession) is in MeshSatNet.
import Foundation

public enum MeshSatMQTT {
    public static let module = "MeshSatMQTT"
}

/// Where and how to reach a broker, from the URL forms Android's settings hold:
/// tcp://host:1883, ssl://host:8883, ws://host/mqtt, wss://host/mqtt.
public struct MqttEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var useWebSockets: Bool
    public var webSocketPath: String
    public var clientId: String
    public var username: String
    public var password: String
    /// PEM; both set = mutual TLS with the system roots (the Hub bridge CA in `caCertPem` is
    /// for the relay tunnel's inner TLS, not for the broker, as on Android).
    public var clientCertPem: String
    public var clientKeyPem: String
    public var caCertPem: String
    /// Base64 SHA-256 SPKI pins, primary and backup.
    public var certPins: [String]
    public var keepAliveSec: Int
    public var connectTimeoutSec: Int

    public init(
        host: String, port: Int, useTLS: Bool, useWebSockets: Bool, webSocketPath: String = "/mqtt", clientId: String,
        username: String = "",
        password: String = "", clientCertPem: String = "", clientKeyPem: String = "", caCertPem: String = "", certPins: [String] = [],
        keepAliveSec: Int = 60, connectTimeoutSec: Int = 10
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.useWebSockets = useWebSockets
        self.webSocketPath = webSocketPath
        self.clientId = clientId
        self.username = username
        self.password = password
        self.clientCertPem = clientCertPem
        self.clientKeyPem = clientKeyPem
        self.caCertPem = caCertPem
        self.certPins = certPins
        self.keepAliveSec = keepAliveSec
        self.connectTimeoutSec = connectTimeoutSec
    }

    /// Parse a broker URL. Nil when the scheme is not one of tcp, mqtt, ssl, tls, mqtts, ws, wss
    /// or the host is missing. The default port follows the scheme.
    public static func parse(_ url: String, clientId: String) -> MqttEndpoint? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased(),
            let host = u.host, !host.isEmpty
        else { return nil }
        let tls: Bool
        let ws: Bool
        switch scheme {
        case "tcp", "mqtt": (tls, ws) = (false, false)
        case "ssl", "tls", "mqtts": (tls, ws) = (true, false)
        case "ws": (tls, ws) = (false, true)
        case "wss": (tls, ws) = (true, true)
        default: return nil
        }
        let port = u.port ?? (ws ? (tls ? 443 : 80) : (tls ? 8883 : 1883))
        let path = u.path.isEmpty ? "/mqtt" : u.path
        return MqttEndpoint(host: host, port: port, useTLS: tls, useWebSockets: ws, webSocketPath: path, clientId: clientId)
    }

    public var hasClientCertificate: Bool { !clientCertPem.isEmpty && !clientKeyPem.isEmpty }
}
