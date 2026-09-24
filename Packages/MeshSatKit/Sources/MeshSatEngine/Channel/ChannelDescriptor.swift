// Mirrors channel/ChannelDescriptor.kt, channel/ChannelRegistry.kt and channel/ChannelDefaults.kt
// (ports of the Bridge's internal/channel): what each transport can do, how it retries, and the
// registry the dispatcher and the rule editor read. Durations are milliseconds.
import Foundation

/// Channel-specific retry behaviour.
public struct RetryConfig: Sendable, Equatable {
    public var enabled: Bool
    public var initialWaitMs: Int64
    public var maxWaitMs: Int64
    /// 0 = infinite.
    public var maxRetries: Int
    /// "exponential", "linear", "isu"
    public var backoffFunc: String

    public init(
        enabled: Bool = false, initialWaitMs: Int64 = 0, maxWaitMs: Int64 = 0, maxRetries: Int = 0, backoffFunc: String = "exponential"
    ) {
        self.enabled = enabled
        self.initialWaitMs = initialWaitMs
        self.maxWaitMs = maxWaitMs
        self.maxRetries = maxRetries
        self.backoffFunc = backoffFunc
    }
}

/// Per-channel config field for the rule editor.
public struct OptionField: Sendable, Equatable {
    public var key: String
    public var label: String
    /// "text", "number", "select", "checkbox"
    public var type: String
    public var defaultValue: String
    public var options: [String]

    public init(key: String, label: String, type: String, defaultValue: String = "", options: [String] = []) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.options = options
    }
}

/// A transport channel's capabilities and constraints.
public struct ChannelDescriptor: Sendable, Equatable {
    public var id: String
    public var label: String
    public var isPaid: Bool
    public var canSend: Bool
    public var canReceive: Bool
    public var binaryCapable: Bool
    /// 0 = unlimited.
    public var maxPayload: Int
    /// 0 = no default TTL.
    public var defaultTtlSeconds: Int
    public var isSatellite: Bool
    public var retryConfig: RetryConfig
    public var options: [OptionField]

    public init(
        id: String, label: String, isPaid: Bool = false, canSend: Bool = true, canReceive: Bool = true, binaryCapable: Bool = false,
        maxPayload: Int = 0, defaultTtlSeconds: Int = 0, isSatellite: Bool = false, retryConfig: RetryConfig = RetryConfig(),
        options: [OptionField] = []
    ) {
        self.id = id
        self.label = label
        self.isPaid = isPaid
        self.canSend = canSend
        self.canReceive = canReceive
        self.binaryCapable = binaryCapable
        self.maxPayload = maxPayload
        self.defaultTtlSeconds = defaultTtlSeconds
        self.isSatellite = isSatellite
        self.retryConfig = retryConfig
        self.options = options
    }
}

/// Thread-safe registry of channel descriptors, in registration order.
public final class ChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var channels: [String: ChannelDescriptor] = [:]

    public init() {}

    public struct AlreadyRegistered: Error, Equatable {
        public let id: String
    }

    /// Register a descriptor; throws if the id is already registered.
    public func register(_ descriptor: ChannelDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        if channels[descriptor.id] != nil { throw AlreadyRegistered(id: descriptor.id) }
        channels[descriptor.id] = descriptor
        order.append(descriptor.id)
    }

    public func get(_ id: String) -> ChannelDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return channels[id]
    }

    public func list() -> [ChannelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { channels[$0] }
    }

    public func ids() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    public func isPaid(_ id: String) -> Bool { get(id)?.isPaid == true }
    public func canSend(_ id: String) -> Bool { get(id)?.canSend == true }
    public func canReceive(_ id: String) -> Bool { get(id)?.canReceive == true }
    public func binaryCapable(_ id: String) -> Bool { get(id)?.binaryCapable == true }

    /// The channel type of an interface id: "iridium_0" is "iridium".
    public static func channelType(of interfaceId: String) -> String {
        guard let i = interfaceId.lastIndex(of: "_") else { return interfaceId }
        return String(interfaceId[..<i])
    }
}

/// The built-in channels of the phone (channel/ChannelDefaults.kt). iOS has no SMS API, but the
/// "sms" channel stays: it is the Messages composer lane (MESHSAT-1328), text only, and a
/// rule may still name it.
public enum ChannelDefaults {
    public static func register(into registry: ChannelRegistry) throws {
        try registry.register(
            ChannelDescriptor(
                id: "mesh", label: "Meshtastic BLE", binaryCapable: true, maxPayload: 237,
                retryConfig: RetryConfig(enabled: false, maxRetries: 1),
                options: [
                    OptionField(key: "channel", label: "Mesh Channel", type: "number", defaultValue: "0"),
                    OptionField(key: "target_node", label: "Target Node", type: "text"),
                ]))
        try registry.register(
            ChannelDescriptor(
                id: "iridium", label: "Iridium SBD", isPaid: true, binaryCapable: true, maxPayload: 340, defaultTtlSeconds: 3600,
                isSatellite: true,
                retryConfig: RetryConfig(enabled: true, initialWaitMs: 180_000, maxWaitMs: 30 * 60_000, maxRetries: 10, backoffFunc: "isu"),
                options: [
                    OptionField(key: "priority", label: "Priority", type: "select", defaultValue: "1", options: ["0", "1", "2"]),
                    OptionField(key: "include_gps", label: "Include GPS", type: "checkbox", defaultValue: "false"),
                ]))
        try registry.register(
            ChannelDescriptor(
                id: "sms", label: "Cellular SMS", isPaid: true, binaryCapable: false, maxPayload: 160, defaultTtlSeconds: 86400,
                retryConfig: RetryConfig(
                    enabled: true, initialWaitMs: 30_000, maxWaitMs: 5 * 60_000, maxRetries: 3, backoffFunc: "exponential")))
        try registry.register(
            ChannelDescriptor(
                id: "mqtt", label: "Hub MQTT", binaryCapable: true, maxPayload: 0, defaultTtlSeconds: 300,
                retryConfig: RetryConfig(
                    enabled: true, initialWaitMs: 5_000, maxWaitMs: 60_000, maxRetries: 10, backoffFunc: "exponential"),
                options: [
                    OptionField(key: "broker_url", label: "Hub Broker URL", type: "text"),
                    OptionField(key: "device_id", label: "Device ID", type: "text"),
                    OptionField(key: "username", label: "Username", type: "text"),
                    OptionField(key: "password", label: "Password", type: "text"),
                ]))
        try registry.register(
            ChannelDescriptor(
                id: "reticulum", label: "Reticulum (LoRa)", binaryCapable: true, maxPayload: 383,
                retryConfig: RetryConfig(enabled: false, maxRetries: 1),
                options: [
                    OptionField(key: "channel", label: "Mesh Channel", type: "number", defaultValue: "0"),
                    OptionField(key: "target_node", label: "Target Node", type: "text"),
                ]))
        try registry.register(
            ChannelDescriptor(
                id: "aprs", label: "APRS (KISS over TCP)", binaryCapable: false, maxPayload: 256,
                retryConfig: RetryConfig(enabled: false, maxRetries: 1),
                options: [
                    OptionField(key: "callsign", label: "Callsign", type: "text"),
                    OptionField(key: "ssid", label: "SSID", type: "number", defaultValue: "7"),
                    OptionField(key: "kiss_host", label: "KISS Host", type: "text", defaultValue: "localhost"),
                    OptionField(key: "kiss_port", label: "KISS Port", type: "number", defaultValue: "8001"),
                ]))
    }
}
