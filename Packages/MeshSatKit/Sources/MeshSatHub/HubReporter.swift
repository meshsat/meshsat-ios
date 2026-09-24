// Mirrors hub/HubReporter.kt: the meshsat-uplink/v1 reporter, the phone as a mobile field
// node in the Hub fleet. Publishes the bridge birth (retained, signed when there is a key),
// death (a last will and on stop), health on an interval, device births and deaths, positions,
// messages on mo/decoded, SOS events; subscribes to the command topic, the TAK broadcast and
// the MO receipts. Runs over an MQTTSession, so the tests drive it with a fake broker.
import Foundation
import Logging
import MeshSatNet

public struct HubReporterConfig: Sendable, Equatable {
    public var hubUrl: String
    public var bridgeId: String
    public var callsign: String
    public var username: String
    public var password: String
    public var certPin: String
    public var certPinBackup: String
    public var healthIntervalSec: Int
    public var enabled: Bool
    public var clientCertPem: String
    public var clientKeyPem: String
    public var caCertPem: String
    /// The bundle's mqtt_topic_prefix: "meshsat", or "meshsat/{tenant}" for a customer tenant.
    public var topicPrefix: String

    public init(
        hubUrl: String, bridgeId: String, callsign: String = "", username: String = "", password: String = "", certPin: String = "",
        certPinBackup: String = "", healthIntervalSec: Int = 30, enabled: Bool = true, clientCertPem: String = "",
        clientKeyPem: String = "",
        caCertPem: String = "", topicPrefix: String = HubTopics.platformPrefix
    ) {
        self.hubUrl = hubUrl
        self.bridgeId = bridgeId
        self.callsign = callsign
        self.username = username
        self.password = password
        self.certPin = certPin
        self.certPinBackup = certPinBackup
        self.healthIntervalSec = healthIntervalSec
        self.enabled = enabled
        self.clientCertPem = clientCertPem
        self.clientKeyPem = clientKeyPem
        self.caCertPem = caCertPem
        self.topicPrefix = topicPrefix
    }

    /// The MQTT client id: "meshsat-ios-" and the whole bridge id. MQTT allows one session per
    /// client id, so the 12-character suffix Android uses let two bridges whose ids end alike
    /// keep throwing each other off the broker (MESHSAT-1324; Android: MESHSAT-1334).
    public var clientId: String { "meshsat-ios-" + bridgeId }
}

/// What the reporter reads off the phone: the interfaces and their health, the position, the
/// battery, memory and disk, the app version and the device name (GatewayService's role).
public protocol HubReporterHost: Sendable {
    func interfaces() -> [InterfaceInfo]
    func interfaceHealth() -> [InterfaceHealth]
    func capabilities() -> [String]
    func location() -> HubLocation?
    func batteryPct() -> Double
    func memPct() -> Double
    func diskPct() -> Double
    var appVersion: String { get }
    var deviceModel: String { get }
}

public final class HubReporter: @unchecked Sendable {
    private static let log = Logger(label: "HubReporter")
    static let qosFireAndForget = 0
    static let qosAtLeastOnce = 1
    /// The first retry after a failed connect, and the longest wait between tries.
    public static let connectRetryMinMs: Int64 = 5_000
    public static let connectRetryMaxMs: Int64 = 60_000

    public enum State: Sendable, Equatable { case disconnected, connecting, connected, error }

    public let config: HubReporterConfig
    /// The topics under this bridge's tenant namespace.
    var topics: HubTopics { HubTopics(prefix: config.topicPrefix) }
    public var bridgeId: String { config.bridgeId }
    public let state = StateBroadcast<State>(.disconnected)
    /// Why the last connection attempt failed, in the library's words, or empty (MESHSAT-749).
    public let lastError = StateBroadcast<String>("")

    private let host: any HubReporterHost
    private let makeSession: @Sendable (HubReporterConfig) -> any MQTTSession
    private let clock: any DriverClock
    private let lock = NSLock()
    private var session: (any MQTTSession)?
    private var stopped = false
    private var tasks: [Task<Void, Never>] = []
    private var activeDevices: Set<String> = []
    private var announcedImeis: Set<String> = []
    private let startedAt: Int64
    private var onCommandHook: (@Sendable (HubCommand) -> Void)?
    private var onTakCotHook: (@Sendable (String) -> Void)?
    private var onMoAckHook: (@Sendable (_ imei: String, _ momsn: Int) -> Void)?

    public init(
        config: HubReporterConfig, host: any HubReporterHost, makeSession: @escaping @Sendable (HubReporterConfig) -> any MQTTSession,
        clock: any DriverClock = SystemDriverClock()
    ) {
        self.config = config
        self.host = host
        self.makeSession = makeSession
        self.clock = clock
        self.startedAt = clock.nowMs()
    }

    // MARK: Hooks

    public func setCommandCallback(_ cb: (@Sendable (HubCommand) -> Void)?) {
        lock.lock()
        onCommandHook = cb
        lock.unlock()
    }

    /// TAK CoT XML received on the Hub's broadcast.
    public func setTakCotCallback(_ cb: (@Sendable (String) -> Void)?) {
        lock.lock()
        onTakCotHook = cb
        lock.unlock()
    }

    /// The Hub has an MO from one of this phone's modems (MESHSAT-1246).
    public func setMoAckCallback(_ cb: (@Sendable (_ imei: String, _ momsn: Int) -> Void)?) {
        lock.lock()
        onMoAckHook = cb
        lock.unlock()
    }

    private func currentSession() -> (any MQTTSession)? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    public var isConnected: Bool {
        get async {
            guard let s = currentSession() else { return false }
            return await s.isConnected
        }
    }

    private func uptimeSec() -> Int64 { (clock.nowMs() - startedAt) / 1000 }

    // MARK: Lifecycle

    /// Connect, announce, start the health loop. A first connect that fails is tried again,
    /// with backoff, until it works or the reporter is stopped (MESHSAT-749).
    public func start() {
        guard !config.hubUrl.isEmpty, !config.bridgeId.isEmpty else {
            Self.log.warning("Cannot start: Hub URL or bridge ID not configured")
            return
        }
        lock.lock()
        stopped = false
        lock.unlock()
        state.send(.connecting)
        let task = Task { [self] in
            var wait = Self.connectRetryMinMs
            while !isStopped {
                if await connectOnce() { return }
                if isStopped { return }
                Self.log.info("Hub connect: trying again in \(wait / 1000)s")
                await clock.sleep(ms: wait)
                wait = Self.nextConnectRetry(wait)
                if !isStopped { state.send(.connecting) }
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    /// One attempt with a fresh session. True when connected and announced.
    private func connectOnce() async -> Bool {
        let s = makeSession(config)
        Self.log.info("Connecting to \(config.hubUrl) as \(config.clientId) (cert=\(!config.clientCertPem.isEmpty))")
        let will = MQTTWill(
            topic: topics.bridgeDeath(config.bridgeId),
            payload: Array(BridgeDeath(bridgeId: config.bridgeId, reason: "lwt").toJson().text().utf8),
            qos: Self.qosAtLeastOnce, retain: false)
        do {
            try await s.connect(will: will)
        } catch {
            Self.log.error("Hub connect failed: \(error)")
            lastError.send(Self.connectFailureMessage(error))
            state.send(.error)
            await s.disconnect()
            return false
        }
        if isStopped {
            await s.disconnect()
            return false
        }
        setSession(s)
        // Observing before "connected" is announced: a message delivered the moment a caller
        // sees the connected state must already have a subscriber (seen under test load).
        observe(s)
        state.send(.connected)
        lastError.send("")
        Self.log.info("Connected to Hub at \(config.hubUrl)")
        await subscribeAndAnnounce(s)
        startHealthLoop()
        return true
    }

    private func observe(_ s: any MQTTSession) {
        // Subscribed here, synchronously, so nothing sent before the tasks first run is lost.
        let inboundStream = s.inbound.subscribe()
        let eventStream = s.events.subscribe()
        let inbound = Task { [self] in
            for await m in inboundStream {
                await handleInbound(topic: m.topic, payload: String(decoding: m.payload, as: UTF8.self))
            }
        }
        let events = Task { [self] in
            for await e in eventStream {
                switch e {
                case .connectionLost(let why):
                    Self.log.warning("Hub connection lost: \(why)")
                    state.send(.disconnected)
                case .reconnected:
                    if isStopped || currentSession() !== s {
                        // A client that was stopped got back in on its own (MESHSAT-1305).
                        await s.disconnect()
                        continue
                    }
                    // A clean session: the broker forgot the subscriptions and the Hub marked
                    // the bridge offline on the will, so do what the first connect did (MESHSAT-1235).
                    state.send(.connected)
                    await subscribeAndAnnounce(s)
                }
            }
        }
        lock.lock()
        tasks.append(contentsOf: [inbound, events])
        lock.unlock()
    }

    /// Publish death, disconnect. Closed in every state (MESHSAT-1305).
    public func stop() async {
        let gone = takeEverything()
        let s = gone.session
        for task in gone.tasks { task.cancel() }
        if let s, await s.isConnected {
            for deviceId in gone.devices { await publishDeviceDeath(deviceId, reason: "bridge_shutdown", on: s) }
            try? await s.publish(
                topic: topics.bridgeDeath(config.bridgeId), payload: Array(BridgeDeath(bridgeId: config.bridgeId).toJson().text().utf8),
                qos: Self.qosAtLeastOnce, retain: false)
        }
        await s?.disconnect()
        state.send(.disconnected)
    }

    // MARK: Publishing

    /// Send a message to the Hub the way a kit does: on mo/decoded, where the routing engine
    /// picks it up (MESHSAT-1261). `channel` is the link it arrived on in the Hub's vocabulary
    /// (MESHSAT-1274); `messageId` is stable across retries. False when not connected or refused.
    public func publishMessage(
        deviceId: String, text: String, recipient: String = "", source: String = "ios", channel: String = "mqtt", messageId: String = ""
    ) async -> Bool {
        guard let s = currentSession(), await s.isConnected else { return false }
        // The plain id in the body, the percent-encoded one in the topic: a raw "+" is an MQTT
        // wildcard and the broker drops the connection (MESHSAT-1274).
        var decoded = JSONBody()
        if !messageId.isEmpty { decoded.put("id", messageId) }
        decoded.put("imei", deviceId)
        decoded.put("device_id", deviceId)
        decoded.put("bridge_id", config.bridgeId)
        decoded.put("text", text)
        decoded.put("sos", false)
        decoded.put("channel", channel)
        decoded.put("source", source)
        if !recipient.isEmpty { decoded.put("to", recipient) }
        decoded.put("timestamp", HubProtocol.isoTimestamp())
        do {
            try await s.publish(
                topic: topics.deviceMODecoded(deviceId), payload: Array(decoded.text().utf8),
                qos: Self.qosAtLeastOnce, retain: false)
            return true
        } catch {
            Self.log.warning("Message publish to the Hub failed: \(error)")
            return false
        }
    }

    /// An SOS over the internet, as a kit sends it (MESHSAT-1249): the message on mo/decoded
    /// with "sos" set, and the event on the device's sos topic. `id` is the alert's id at the
    /// Hub, the one the same SOS gets by satellite. A test goes with `asMessage` false.
    public func publishSos(  // swiftlint:disable:this function_parameter_count
        deviceId: String, id: String, text: String, sos: Bool, type: String, lat: Double?, lon: Double?, asMessage: Bool = true
    ) async -> Bool {
        guard let s = currentSession(), await s.isConnected else { return false }
        let device = deviceId
        let now = HubProtocol.isoTimestamp()
        var decoded = JSONBody()
        decoded.put("id", id)
        decoded.put("imei", deviceId)
        decoded.put("bridge_id", config.bridgeId)
        decoded.put("text", text)
        decoded.put("sos", sos)
        decoded.put("channel", "mqtt")
        decoded.put("source", "ios_sos")
        if let lat, let lon {
            decoded.put("lat", lat)
            decoded.put("lon", lon)
        }
        decoded.put("timestamp", now)
        var event = JSONBody()
        event.put("device_id", deviceId)
        event.put("bridge_id", config.bridgeId)
        event.put("type", type)
        event.put("message", text)
        if let lat, let lon {
            event.put("lat", lat)
            event.put("lon", lon)
        }
        event.put("timestamp", now)
        do {
            if asMessage {
                try await s.publish(
                    topic: topics.deviceMODecoded(device), payload: Array(decoded.text().utf8), qos: Self.qosAtLeastOnce, retain: false)
            }
            try await s.publish(
                topic: topics.deviceSOS(device), payload: Array(event.text().utf8), qos: Self.qosAtLeastOnce, retain: false)
            return true
        } catch {
            Self.log.warning("SOS publish to the Hub failed: \(error)")
            return false
        }
    }

    public func publishDeviceBirth(_ birth: DeviceBirth) async {
        trackDevice(birth.deviceId, active: true)
        await publish(topics.deviceBirth(config.bridgeId, birth.deviceId), qos: Self.qosAtLeastOnce, retain: false, birth.toJson())
    }

    public func publishDeviceDeath(_ deviceId: String, reason: String = "offline") async {
        trackDevice(deviceId, active: false)
        guard let s = currentSession() else { return }
        await publishDeviceDeath(deviceId, reason: reason, on: s)
    }

    private func publishDeviceDeath(_ deviceId: String, reason: String, on s: any MQTTSession) async {
        let death = DeviceDeath(deviceId: deviceId, bridgeId: config.bridgeId, reason: reason)
        try? await s.publish(
            topic: topics.deviceDeath(config.bridgeId, deviceId), payload: Array(death.toJson().text().utf8), qos: Self.qosAtLeastOnce,
            retain: false)
    }

    public func publishDevicePosition(_ deviceId: String, _ position: DevicePosition) async {
        await publish(topics.devicePosition(deviceId), qos: Self.qosAtLeastOnce, retain: true, position.toJson())
    }

    public func publishDeviceTelemetry(_ deviceId: String, _ telemetry: DeviceTelemetry) async {
        await publish(topics.deviceTelemetry(deviceId), qos: Self.qosAtLeastOnce, retain: true, telemetry.toJson())
    }

    public func publishCommandResponse(_ response: CommandResponse) async {
        await publish(topics.bridgeCmdResponse(config.bridgeId), qos: Self.qosAtLeastOnce, retain: false, response.toJson())
    }

    /// A QoS 1 publish on the health topic, timed; throws when not connected.
    public func ping() async throws -> Int64 {
        guard let s = currentSession() else { throw HubError.notConnected }
        let start = clock.nowMs()
        try await s.publish(topic: topics.bridgeHealth(config.bridgeId), payload: Array("{\"ping\":true}".utf8), qos: 1, retain: false)
        return clock.nowMs() - start
    }

    public enum HubError: Error, Equatable { case notConnected }

    // MARK: Internals

    private func subscribeAndAnnounce(_ s: any MQTTSession) async {
        do {
            try await s.subscribe(
                [topics.bridgeCmd(config.bridgeId)] + (topics.mayReceiveTakBroadcast ? [HubTopics.takBroadcast] : []) + [
                    topics.bridgeMOAck(config.bridgeId)
                ],
                qos: Self.qosAtLeastOnce)
        } catch {
            Self.log.warning("Hub subscribe failed: \(error)")
        }
        await publishBirth(s)
    }

    static func modemImeis(_ interfaces: [InterfaceInfo]) -> Set<String> {
        Set(interfaces.map(\.imei).filter { !$0.isEmpty })
    }

    private func publishBirth(_ s: any MQTTSession) async {
        let birth = buildBirthCertificate()
        setAnnounced(Self.modemImeis(birth.interfaces))
        var json = birth.toJson()
        if !config.clientCertPem.isEmpty && !config.clientKeyPem.isEmpty {
            let signed = BirthSigner.sign(&json, certPem: config.clientCertPem, keyPem: config.clientKeyPem)
            Self.log.info("Birth \(signed ? "signed" : "unsigned"): \(config.bridgeId)")
        }
        try? await s.publish(
            topic: topics.bridgeBirth(config.bridgeId), payload: Array(json.text().utf8), qos: Self.qosAtLeastOnce, retain: true)
        Self.log.info("Published bridge birth: \(config.bridgeId)")
    }

    func buildBirthCertificate() -> BridgeBirth {
        BridgeBirth(
            bridgeId: config.bridgeId, version: host.appVersion, hostname: host.deviceModel, mode: "ios", tenantId: "default",
            location: host.location(), interfaces: host.interfaces(), capabilities: host.capabilities(),
            cotCallsign: config.callsign.isEmpty ? host.deviceModel : config.callsign, uptimeSec: uptimeSec())
    }

    private func startHealthLoop() {
        let task = Task { [self] in
            while !Task.isCancelled {
                await clock.sleep(ms: Int64(config.healthIntervalSec) * 1000)
                if Task.isCancelled { break }
                guard let s = currentSession(), await s.isConnected else { continue }
                // The Hub links a satellite device to this bridge only from a birth, and a modem
                // is often paired after the connect: re-announce when the set changes (MESHSAT-1235).
                if Self.modemImeis(host.interfaces()) != announced() {
                    Self.log.info("Modem set changed, re-publishing birth")
                    await publishBirth(s)
                }
                await publishHealth(s)
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    private func publishHealth(_ s: any MQTTSession) async {
        let health = BridgeHealth(
            bridgeId: config.bridgeId, uptimeSec: uptimeSec(), batteryPct: host.batteryPct(), memPct: host.memPct(),
            diskPct: host.diskPct(),
            interfaces: host.interfaceHealth())
        try? await s.publish(
            topic: topics.bridgeHealth(config.bridgeId), payload: Array(health.toJson().text().utf8), qos: Self.qosFireAndForget,
            retain: false)
    }

    func handleInbound(topic: String, payload: String) async {
        if topic.contains("/tak/cot/in") {
            hooks().tak?(payload)
            return
        }
        if topic.hasSuffix("/mo/ack") {
            handleMoAck(payload)
            return
        }
        guard topic.hasSuffix("/cmd") else {
            Self.log.info("Hub message on \(topic) ignored (\(payload.utf8.count) bytes)")
            return
        }
        guard let json = JSONBody.parse(Data(payload.utf8)) else {
            Self.log.warning("Hub command not JSON on \(topic): \(payload.prefix(200))")
            return
        }
        let cmd = HubCommand.fromJson(json)
        Self.log.info("Hub command: \(cmd.cmd) (\(cmd.requestId))")
        if cmd.cmd == "ping" {
            Self.log.info("Hub ping: answering on \(topics.bridgeCmdResponse(config.bridgeId))")
            await publishCommandResponse(CommandResponse(requestId: cmd.requestId, cmd: "ping", status: "ok"))
            return
        }
        hooks().command?(cmd)
    }

    /// {imei, momsn, ...}: checked before use, as anything read off the network is.
    func handleMoAck(_ payload: String) {
        guard let json = JSONBody.parse(Data(payload.utf8)), let imei = json.string("imei"), let momsn = json.int("momsn") else {
            Self.log.warning("Ignoring a malformed MO receipt")
            return
        }
        guard imei.count == 15, imei.allSatisfy(\.isNumber), (0...65535).contains(momsn) else {
            Self.log.warning("Ignoring a malformed MO receipt")
            return
        }
        Self.log.info("The Hub has MOMSN \(momsn)")
        lock.lock()
        let hook = onMoAckHook
        lock.unlock()
        hook?(imei, Int(momsn))
    }

    // Synchronous helpers: the lock is never taken inside an async function.

    private struct Hooks {
        let command: (@Sendable (HubCommand) -> Void)?
        let tak: (@Sendable (String) -> Void)?
    }

    private func hooks() -> Hooks {
        lock.lock()
        defer { lock.unlock() }
        return Hooks(command: onCommandHook, tak: onTakCotHook)
    }

    private func setSession(_ s: any MQTTSession) {
        lock.lock()
        session = s
        lock.unlock()
    }

    private struct Teardown {
        let session: (any MQTTSession)?
        let tasks: [Task<Void, Never>]
        let devices: Set<String>
    }

    private func takeEverything() -> Teardown {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        let out = Teardown(session: session, tasks: tasks, devices: activeDevices)
        session = nil
        tasks.removeAll()
        activeDevices.removeAll()
        return out
    }

    private func trackDevice(_ id: String, active: Bool) {
        lock.lock()
        if active { activeDevices.insert(id) } else { activeDevices.remove(id) }
        lock.unlock()
    }

    private func setAnnounced(_ imeis: Set<String>) {
        lock.lock()
        announcedImeis = imeis
        lock.unlock()
    }

    private func announced() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return announcedImeis
    }

    private func publish(_ topic: String, qos: Int, retain: Bool, _ body: JSONBody) async {
        guard let s = currentSession(), await s.isConnected else {
            Self.log.warning("Hub not connected, dropping publish to \(topic)")
            return
        }
        do {
            try await s.publish(topic: topic, payload: Array(body.text().utf8), qos: qos, retain: retain)
            if topic.hasSuffix("/cmd/response") { Self.log.info("Hub command answered on \(topic)") }
        } catch {
            Self.log.warning("Hub publish to \(topic) failed: \(error)")
        }
    }

    // MARK: Pure helpers with tests

    /// The wait after `previousMs`: doubled, never above a minute, never below five seconds.
    public static func nextConnectRetry(_ previousMs: Int64) -> Int64 {
        min(max(previousMs * 2, connectRetryMinMs), connectRetryMaxMs)
    }

    /// A connection failure as a person can read it: the outermost message and, when it
    /// differs, the innermost underlying error's, which is where the real reason sits.
    /// What Setup > Hub says when a connect fails. A refused password after provisioning means
    /// the Hub minted new credentials (a newer provisioning QR code) or revoked this bridge;
    /// retrying cannot fix that, so the words say what does.
    public static func connectFailureMessage(_ error: Error) -> String {
        let text = connectFailureText(error)
        return isAuthFailure(text) || isAuthFailure(String(describing: error))
            ? "The Hub refused this phone's credentials. They were replaced by a newer provisioning QR code, or the bridge was removed: "
                + "scan a new provisioning QR code in Setup > Hub."
            : text
    }

    public static func isAuthFailure(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        return ["notauthorized", "badusernamepassword", "authenticationerror", "authorizationviolation"].contains { t.contains($0) }
    }

    public static func connectFailureText(_ error: Error) -> String {
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let e = current, chain.count < 8 {
            chain.append(e)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        func text(_ e: NSError) -> String {
            let described = (e as Error) as? CustomStringConvertible
            let message = e.userInfo[NSLocalizedDescriptionKey] as? String ?? described?.description ?? e.localizedDescription
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(type(of: e as Error))" : trimmed
        }
        guard let first = chain.first else { return "" }
        let outer = text(first)
        guard chain.count > 1, let last = chain.last else { return outer }
        let inner = text(last)
        return inner != outer && !outer.contains(inner) ? "\(outer): \(inner)" : outer
    }
}
