// Mirrors reticulum/RnsMqttInterface.kt: a Reticulum interface over MQTT (MESHSAT-220, 354).
// Publishes packets base64 on meshsat/{deviceId}/reticulum/tx; the Hub publishes relayed
// packets to meshsat/{deviceId}/reticulum/rx, which the gateway's inbound handler routes to
// processIncomingMessage. MTU 500, free, latency under a second.
import Foundation
import MeshSatWire

/// The MQTT transport as this interface needs it (mqtt/MqttTransport.kt).
public protocol RnsMqttLink: AnyObject, Sendable {
    var isConnected: Bool { get }
    func publishRaw(topic: String, qos: Int, retained: Bool, payload: String) async throws
}

public final class RnsMqttInterface: RnsInterface, @unchecked Sendable {
    /// Outbound Reticulum packets (phone to Hub).
    public static let topicTxSuffix = "/reticulum/tx"
    /// Inbound Reticulum packets (Hub to phone).
    public static let topicRxSuffix = "/reticulum/rx"

    public let interfaceId: String
    public let name = "MQTT Hub"
    public let mtu = RnsConstants.mtu
    public let costCents = 0
    public let latencyMs = 100
    public let isBidirectional = true
    public var isOnline: Bool { mqtt.isConnected }
    private let mqtt: any RnsMqttLink
    private let deviceId: @Sendable () -> String
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var receiveCallback: RnsReceiveCallback?

    public init(
        mqtt: any RnsMqttLink, deviceId: @escaping @Sendable () -> String, interfaceId: String = "mqtt_rns_0",
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.interfaceId = interfaceId
        self.log = log
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    public func send(_ packet: [UInt8]) async -> String? {
        guard isOnline else { return "MQTT interface offline" }
        let topic = "meshsat/\(deviceId())\(Self.topicTxSuffix)"
        do {
            try await mqtt.publishRaw(topic: topic, qos: 1, retained: false, payload: Base64Std.encode(packet))
            log("RNS packet sent via MQTT: \(packet.count)B to \(topic)")
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// An inbound MQTT message that may be a Reticulum packet (base64 on .../reticulum/rx).
    /// True when it was one.
    @discardableResult
    public func processIncomingMessage(topic: String, payload: String) -> Bool {
        guard topic.hasSuffix(Self.topicRxSuffix), let packet = Base64Std.decode(payload) else { return false }
        lock.lock()
        let cb = receiveCallback
        lock.unlock()
        cb?(interfaceId, packet)
        log("RNS packet received via MQTT: \(packet.count)B")
        return true
    }

    public func start() async { log("RNS MQTT interface started for device \(deviceId())") }
    public func stop() async { log("RNS MQTT interface stopped") }
}
