// Mirrors mqtt/MqttTransport.kt: the device's own MQTT connection to a broker (mqtt_0), apart
// from the Hub reporter. Publishes position, SOS, telemetry, decoded MO text, health and
// inbound SMS under meshsat/{deviceId}/..., subscribes to the reverse-path topics, and keeps
// reconnecting with backoff as Paho's automatic reconnect did. The session is injectable, so
// the tests run on the fake one.
import Foundation
import Logging
import MeshSatNet

public final class MqttTransport: @unchecked Sendable {
    public enum State: Sendable, Equatable { case disconnected, connecting, connected, error }
    public typealias MessageCallback = @Sendable (_ topic: String, _ payload: String) -> Void
    public typealias SessionFactory = @Sendable (MqttEndpoint) -> any MQTTSession

    public static let qosAtLeastOnce = 1
    public static let qosExactlyOnce = 2
    public static let connectRetryMinMs: Int64 = 5_000
    public static let connectRetryMaxMs: Int64 = 60_000
    public static let topicRoutes = "meshsat/reticulum/routes"
    public static let topicTakBroadcast = "meshsat/broadcast/tak/cot/in"

    private static let log = Logger(label: "MqttTransport")
    public let state = StateBroadcast<State>(.disconnected)
    private let makeSession: SessionFactory
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let lock = NSLock()
    private var session: (any MQTTSession)?
    private var deviceIdValue = ""
    private var onMessage: MessageCallback?
    private var stopped = true
    private var loop: Task<Void, Never>?
    private var listener: Task<Void, Never>?

    public init(
        makeSession: @escaping SessionFactory, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) {
        self.makeSession = makeSession
        self.now = now
        self.sleep = sleep
    }

    public var deviceId: String {
        lock.lock()
        defer { lock.unlock() }
        return deviceIdValue
    }

    public func setMessageCallback(_ cb: MessageCallback?) {
        lock.lock()
        onMessage = cb
        lock.unlock()
    }

    /// The client id Android uses: meshsat-android-{last 8 of the device id}; here ios.
    public static func clientId(deviceId: String) -> String { "meshsat-ios-" + String(deviceId.suffix(8)) }

    /// Connect to the broker and keep the connection; a second call replaces the first.
    public func connect(endpoint: MqttEndpoint, deviceId: String) {
        guard !endpoint.host.isEmpty, !deviceId.isEmpty else {
            Self.log.warning("Cannot connect: broker or device id blank")
            return
        }
        disconnect()
        lock.lock()
        deviceIdValue = deviceId
        stopped = false
        lock.unlock()
        state.send(.connecting)
        let task = Task { [self] in
            var wait = Self.connectRetryMinMs
            while !isStopped {
                if await connectOnce(endpoint) {
                    wait = Self.connectRetryMinMs
                    // Stay until the session drops, then come back with backoff.
                    await watchUntilDropped()
                    if isStopped { return }
                    state.send(.connecting)
                } else {
                    if isStopped { return }
                    state.send(.error)
                }
                Self.log.info("MQTT: trying again in \(wait / 1000)s")
                guard (try? await sleep(wait)) != nil else { return }
                wait = min(wait * 2, Self.connectRetryMaxMs)
                if !isStopped { state.send(.connecting) }
            }
        }
        lock.lock()
        loop = task
        lock.unlock()
    }

    public func disconnect() {
        lock.lock()
        stopped = true
        let s = session
        session = nil
        let l = loop
        loop = nil
        let li = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        li?.cancel()
        if let s { Task { await s.disconnect() } }
        state.send(.disconnected)
    }

    public var isConnected: Bool { state.value == .connected }

    // MARK: Publishing (the topics of MqttTransport.kt)

    public func publishPosition(lat: Double, lon: Double, alt: Double = 0, source: String = "gps") async {
        await publish(
            topicPosition, qos: Self.qosAtLeastOnce, retained: true,
            Self.json(["lat": lat, "lon": lon, "alt": alt, "source": source, "timestamp": now() / 1000]))
    }

    public func publishSOS(triggered: Bool, lat: Double = 0, lon: Double = 0) async {
        await publish(
            topicSOS, qos: Self.qosExactlyOnce, retained: false,
            Self.json(["triggered": triggered, "lat": lat, "lon": lon, "timestamp": now() / 1000]))
    }

    public func publishTelemetry(battery: Double, temperature: Double = 0, humidity: Double = 0) async {
        await publish(
            topicTelemetry, qos: Self.qosAtLeastOnce, retained: true,
            Self.json(["battery": battery, "temperature": temperature, "humidity": humidity, "timestamp": now() / 1000]))
    }

    public func publishMODecoded(text: String, channel: String = "mesh") async {
        await publish(
            topicMODecoded, qos: Self.qosAtLeastOnce, retained: false,
            Self.json(["text": text, "channel": channel, "timestamp": now() / 1000]))
    }

    public func publishHealth(batteryPct: Int, uptime: Int64) async {
        await publish(
            topicHealth, qos: Self.qosAtLeastOnce, retained: true,
            Self.json(["battery": batteryPct, "uptime": uptime, "last_seen": now() / 1000]))
    }

    /// An SMS that reached the phone, relayed to the Hub (MESHSAT-196).
    public func publishSmsInbound(
        sender: String, text: String, rawText: String = "", wasEncrypted: Bool = false, wasCompressed: Bool = false
    ) async {
        var fields: [String: Any] = [
            "sender": sender, "text": text, "encrypted": wasEncrypted, "compressed": wasCompressed, "timestamp": now() / 1000,
        ]
        if !rawText.isEmpty { fields["raw"] = rawText }
        await publish(topicSmsInbound, qos: Self.qosAtLeastOnce, retained: false, Self.json(fields))
    }

    /// Text on any topic; throws when not connected or refused (RnsMqttInterface's need).
    public func publishRaw(topic: String, qos: Int, retained: Bool, payload: String) async throws {
        guard let s = currentSession(), await s.isConnected else { throw MqttTransportError.notConnected }
        try await s.publish(topic: topic, payload: Array(payload.utf8), qos: qos, retain: retained)
    }

    // MARK: Topics

    public var topicPosition: String { "meshsat/\(deviceId)/position" }
    public var topicSOS: String { "meshsat/\(deviceId)/sos" }
    public var topicTelemetry: String { "meshsat/\(deviceId)/telemetry" }
    public var topicMODecoded: String { "meshsat/\(deviceId)/mo/decoded" }
    public var topicHealth: String { "meshsat/\(deviceId)/status/health" }
    public var topicMTSend: String { "meshsat/\(deviceId)/mt/send" }
    public var topicTakInbound: String { "meshsat/\(deviceId)/tak/cot/in" }
    public var topicConfigUpdate: String { "meshsat/\(deviceId)/config/update" }
    public var topicSmsInbound: String { "meshsat/\(deviceId)/sms/inbound" }
    public var topicSmsOutbound: String { "meshsat/\(deviceId)/sms/outbound" }
    public var topicReticulumRx: String { "meshsat/\(deviceId)/reticulum/rx" }

    /// What the transport listens to, in Android's order.
    public var subscriptions: [String] {
        [topicMTSend, topicTakInbound, Self.topicTakBroadcast, topicConfigUpdate, topicSmsOutbound, topicReticulumRx, Self.topicRoutes]
    }

    // MARK: Internals

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func currentSession() -> (any MQTTSession)? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func adopt(_ s: any MQTTSession, listener: Task<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        session = s
        self.listener = listener
        return true
    }

    private func connectOnce(_ endpoint: MqttEndpoint) async -> Bool {
        let s = makeSession(endpoint)
        do {
            try await s.connect(will: nil)
            // Subscribed to the inbound stream before the subscriptions are placed, so nothing
            // published in between is lost.
            let inbound = s.inbound.subscribe()
            let listener = Task { [weak self] in
                for await m in inbound { self?.deliver(m) }
            }
            guard adopt(s, listener: listener) else {
                listener.cancel()
                await s.disconnect()
                return false
            }
            try await s.subscribe(subscriptions, qos: Self.qosAtLeastOnce)
            state.send(.connected)
            Self.log.info("Connected to \(endpoint.host):\(endpoint.port) as \(endpoint.clientId); \(subscriptions.count) topics")
            return true
        } catch {
            Self.log.error("Connect failed: \(error)")
            await s.disconnect()
            return false
        }
    }

    /// Returns when the session reports a drop (or is gone).
    private func watchUntilDropped() async {
        guard let s = currentSession() else { return }
        for await event in s.events.subscribe() {
            switch event {
            case .connectionLost(let why):
                Self.log.warning("Connection lost: \(why)")
                dropSession(s)?.cancel()
                state.send(.disconnected)
                return
            case .reconnected:
                // The client came back by itself with a clean session: subscribe again.
                try? await s.subscribe(subscriptions, qos: Self.qosAtLeastOnce)
            }
        }
    }

    /// Forgets a dropped session; the listener to cancel.
    private func dropSession(_ s: any MQTTSession) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if session === s { session = nil }
        let li = listener
        listener = nil
        return li
    }

    private func deliver(_ m: MQTTInbound) {
        lock.lock()
        let cb = onMessage
        lock.unlock()
        let payload = String(decoding: m.payload, as: UTF8.self)
        Self.log.debug("Received on \(m.topic): \(payload.prefix(100))")
        cb?(m.topic, payload)
    }

    private func publish(_ topic: String, qos: Int, retained: Bool, _ payload: String) async {
        guard let s = currentSession(), await s.isConnected else {
            Self.log.debug("Not connected, dropping publish to \(topic)")
            return
        }
        do {
            try await s.publish(topic: topic, payload: Array(payload.utf8), qos: qos, retain: retained)
        } catch {
            Self.log.warning("Publish to \(topic) failed: \(error)")
        }
    }

    /// JSONObject.toString() style: compact, keys in insertion order are not guaranteed there
    /// either, so sorted here for stable tests.
    static func json(_ fields: [String: Any]) -> String {
        var parts: [String] = []
        for key in fields.keys.sorted() {
            let v = fields[key] ?? NSNull()
            let text: String
            switch v {
            case let s as String:
                text = "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            case let b as Bool: text = b ? "true" : "false"
            case let i as Int: text = String(i)
            case let i as Int64: text = String(i)
            case let d as Double: text = d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)"
            default: text = "null"
            }
            parts.append("\"\(key)\":\(text)")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

public enum MqttTransportError: Error, Equatable { case notConnected }
