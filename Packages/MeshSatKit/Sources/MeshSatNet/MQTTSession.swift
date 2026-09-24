// What the Hub reporter and the device MQTT transport need from an MQTT 3.1.1 client, so the
// reporter runs against a fake in the tests and against mqtt-nio (MeshSatMQTT) in the app.
import Foundation

/// The last will the broker publishes when the session drops without a disconnect.
public struct MQTTWill: Sendable, Equatable {
    public let topic: String
    public let payload: [UInt8]
    public let qos: Int
    public let retain: Bool
    public init(topic: String, payload: [UInt8], qos: Int, retain: Bool) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
    }
}

/// A message the broker delivered on a subscription.
public struct MQTTInbound: Sendable, Equatable {
    public let topic: String
    public let payload: [UInt8]
    public init(topic: String, payload: [UInt8]) {
        self.topic = topic
        self.payload = payload
    }
}

public enum MQTTSessionEvent: Sendable, Equatable {
    /// The client got back in on its own after a drop; subscriptions are gone (clean session).
    case reconnected
    case connectionLost(String)
}

public protocol MQTTSession: AnyObject, Sendable {
    var isConnected: Bool { get async }
    /// Connect once; throws with the broker's or the transport's reason.
    func connect(will: MQTTWill?) async throws
    /// Publish and, for QoS 1, wait for the broker's acknowledgement.
    func publish(topic: String, payload: [UInt8], qos: Int, retain: Bool) async throws
    func subscribe(_ topics: [String], qos: Int) async throws
    /// A graceful disconnect; the will is not published.
    func disconnect() async
    /// Everything delivered on the subscriptions.
    var inbound: Broadcast<MQTTInbound> { get }
    /// Drops and self-reconnects.
    var events: Broadcast<MQTTSessionEvent> { get }
}
