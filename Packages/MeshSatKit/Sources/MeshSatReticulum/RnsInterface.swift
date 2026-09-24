// Mirrors reticulum/RnsInterface.kt: the contract every Reticulum interface meets (mesh,
// Iridium, MQTT, TCP, the Hub relay, the BLE peripheral). The transport node that drives them
// lands with MESHSAT-1326; the Hub relay (MeshSatHub) conforms already.
import Foundation

/// Receives a raw Reticulum packet from an interface: (interfaceId, packet).
public typealias RnsReceiveCallback = @Sendable (String, [UInt8]) -> Void

public protocol RnsInterface: AnyObject, Sendable {
    /// Unique interface identifier (e.g. "mesh_0", "iridium_0", "hub_relay").
    var interfaceId: String { get }
    /// Human-readable name (e.g. "Meshtastic BLE", "Hub relay").
    var name: String { get }
    /// Largest Reticulum packet this interface carries, in bytes.
    var mtu: Int { get }
    /// Cost per message in USD cents (0 = free), for routing.
    var costCents: Int { get }
    /// Online and able to send and receive right now.
    var isOnline: Bool { get }
    /// Estimated latency in milliseconds, for path costs. 0 = negligible.
    var latencyMs: Int { get }
    /// Some interfaces (an APRS beacon) are send-only.
    var isBidirectional: Bool { get }
    /// Send an already marshalled packet. nil on success, an error message on failure.
    func send(_ packet: [UInt8]) async -> String?
    func setReceiveCallback(_ callback: RnsReceiveCallback?)
    func start() async
    func stop() async
}

public enum RnsConstants {
    /// Reticulum's MTU: the largest packet an interface is asked to carry.
    public static let mtu = 500
}
