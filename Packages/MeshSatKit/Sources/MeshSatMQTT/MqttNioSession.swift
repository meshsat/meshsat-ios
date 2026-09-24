// The MQTTSession on mqtt-nio: one client, 3.1.1, clean session, a last will, keep-alive, TLS
// with the client certificate from PEM and the system roots, SNI on the broker host (the edge
// routes by it, MESHSAT-749), and the automatic reconnect Paho gave Android: after a drop the
// session tries again with a doubling wait and announces `.reconnected`, on which the reporter
// re-subscribes and re-announces (MESHSAT-1235). `disconnect` ends that for good (MESHSAT-1305).
import Foundation
import Logging
import MQTTNIO
import MeshSatNet
import NIOCore

#if canImport(NIOSSL)
import NIOSSL
#elseif canImport(Security)
import Security
#endif

public final class MqttNioSession: MQTTSession, @unchecked Sendable {
    private static let log = Logger(label: "MqttNioSession")
    public static let reconnectMinMs: Int64 = 5_000
    public static let reconnectMaxMs: Int64 = 60_000

    public let inbound = Broadcast<MQTTInbound>(bufferSize: 64)
    public let events = Broadcast<MQTTSessionEvent>(bufferSize: 8)

    private let endpoint: MqttEndpoint
    private let lock = NSLock()
    private var client: MQTTClient?
    private var will: MQTTWill?
    private var closedByUs = false
    private var reconnectTask: Task<Void, Never>?

    public init(endpoint: MqttEndpoint) {
        self.endpoint = endpoint
    }

    public var isConnected: Bool {
        get async { currentClient()?.isActive() ?? false }
    }

    private func currentClient() -> MQTTClient? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    public enum SessionError: Error, Equatable {
        case notConnected
        case tls(String)
    }

    // MARK: Connect

    public func connect(will: MQTTWill?) async throws {
        let c = try makeClient()
        install(c, will: will)
        do {
            _ = try await c.connect(cleanSession: true, will: Self.nioWill(will))
        } catch {
            clearClient()
            try? await c.shutdown()
            throw error
        }
        listen(c)
        c.addCloseListener(named: "meshsat") { [weak self] _ in self?.onClosed(c) }
        Self.log.info("Connected to \(endpoint.host):\(endpoint.port) as \(endpoint.clientId)")
    }

    private func makeClient() throws -> MQTTClient {
        var tls: MQTTClient.TLSConfigurationType?
        if endpoint.useTLS {
            #if canImport(NIOSSL)
            var conf = TLSConfiguration.makeClientConfiguration()
            if endpoint.hasClientCertificate {
                do {
                    let certs = try NIOSSLCertificate.fromPEMBytes(Array(endpoint.clientCertPem.utf8))
                    let key = try NIOSSLPrivateKey(bytes: Array(endpoint.clientKeyPem.utf8), format: .pem)
                    conf.certificateChain = certs.map { .certificate($0) }
                    conf.privateKey = .privateKey(key)
                    Self.log.info("mTLS configured: \(certs.count) certificate(s)")
                } catch {
                    throw SessionError.tls("client certificate: \(error)")
                }
            }
            tls = .niossl(conf)
            #else
            // The phone: Network.framework TLS with the system roots, and the client certificate
            // as a SecIdentity from the Keychain (the Hub's broker drops a bridge without one).
            var identity: SecIdentity?
            if endpoint.hasClientCertificate {
                do {
                    identity = try KeychainClientIdentity.make(certPem: endpoint.clientCertPem, keyPem: endpoint.clientKeyPem)
                    Self.log.info("mTLS configured from the Keychain")
                } catch {
                    throw SessionError.tls("client certificate: \(error)")
                }
            }
            tls = .ts(TSTLSConfiguration(minimumTLSVersion: .tlsV12, clientIdentity: identity))
            #endif
            if !endpoint.certPins.isEmpty {
                // mqtt-nio offers no hook in the handshake for an SPKI check; pins are recorded,
                // not enforced, until it does. mTLS with the system roots is the Hub's main path.
                Self.log.warning("SPKI pins configured but not enforced by this MQTT client")
            }
        }
        let configuration = MQTTClient.Configuration(
            version: .v3_1_1, keepAliveInterval: .seconds(Int64(endpoint.keepAliveSec)),
            connectTimeout: .seconds(Int64(endpoint.connectTimeoutSec)),
            userName: endpoint.username.isEmpty ? nil : endpoint.username, password: endpoint.password.isEmpty ? nil : endpoint.password,
            useSSL: endpoint.useTLS, useWebSockets: endpoint.useWebSockets, tlsConfiguration: tls,
            sniServerName: endpoint.useTLS ? endpoint.host : nil,
            webSocketURLPath: endpoint.useWebSockets ? endpoint.webSocketPath : nil)
        return MQTTClient(
            host: endpoint.host, port: endpoint.port, identifier: endpoint.clientId, eventLoopGroupProvider: .createNew,
            configuration: configuration)
    }

    // mqtt-nio takes the will as this tuple.
    // swiftlint:disable:next large_tuple
    private static func nioWill(_ will: MQTTWill?) -> (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool)? {
        guard let will else { return nil }
        return (will.topic, ByteBuffer(bytes: will.payload), Self.qos(will.qos), will.retain)
    }

    private static func qos(_ level: Int) -> MQTTQoS {
        switch level {
        case 0: .atMostOnce
        case 2: .exactlyOnce
        default: .atLeastOnce
        }
    }

    /// Every received message into `inbound`. A callback on the client, not the AsyncSequence
    /// `createPublishListener()`: that object removes its listener in `deinit`, and a
    /// `for await` over a temporary frees it at once, so the client went on acknowledging
    /// messages (QoS 1 PUBACK) that never reached the app. The Hub's pings were lost that way
    /// (MESHSAT-1324). The same name replaces the listener on a reconnect.
    private func listen(_ c: MQTTClient) {
        c.addPublishListener(named: Self.listenerName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                var payload = info.payload
                let bytes = payload.readBytes(length: payload.readableBytes) ?? []
                if !info.topicName.contains("/tak/") { Self.log.info("MQTT received \(info.topicName) (\(bytes.count) bytes)") }
                inbound.send(MQTTInbound(topic: info.topicName, payload: bytes))
            case .failure(let error):
                Self.log.warning("MQTT receive failed: \(error)")
            }
        }
    }

    static let listenerName = "meshsat-inbound"

    /// The connection closed: not by us, so get it back with a doubling wait (Paho's
    /// automatic reconnect), then say so.
    private func onClosed(_ c: MQTTClient) {
        lock.lock()
        let ours = client === c && !closedByUs
        lock.unlock()
        guard ours else { return }
        events.send(.connectionLost("connection closed"))
        Self.log.warning("MQTT connection lost; reconnecting")
        let task = Task { [weak self] in
            var wait = Self.reconnectMinMs
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(wait))
                if Task.isCancelled { return }
                guard let will = willIfStillOurs(c) else { return }
                do {
                    _ = try await c.connect(cleanSession: true, will: Self.nioWill(will))
                    listen(c)
                    events.send(.reconnected)
                    Self.log.info("MQTT reconnected")
                    return
                } catch {
                    Self.log.info("MQTT reconnect failed: \(error); again in \(wait / 1000)s")
                    wait = min(max(wait * 2, Self.reconnectMinMs), Self.reconnectMaxMs)
                }
            }
        }
        lock.lock()
        reconnectTask?.cancel()
        reconnectTask = task
        lock.unlock()
    }

    // MARK: Locked state, in synchronous helpers (never a lock inside an async function)

    private func install(_ c: MQTTClient, will: MQTTWill?) {
        lock.lock()
        closedByUs = false
        self.will = will
        client = c
        lock.unlock()
    }

    private func clearClient() {
        lock.lock()
        client = nil
        lock.unlock()
    }

    /// The will to reconnect with, or nil when this client was replaced or closed by us. The
    /// will is optional itself, so the answer is doubly optional on purpose.
    private func willIfStillOurs(_ c: MQTTClient) -> MQTTWill?? {
        lock.lock()
        defer { lock.unlock() }
        guard client === c && !closedByUs else { return nil }
        return .some(will)
    }

    private struct Teardown {
        let client: MQTTClient?
        let reconnect: Task<Void, Never>?
    }

    private func takeForDisconnect() -> Teardown {
        lock.lock()
        defer { lock.unlock() }
        closedByUs = true
        let out = Teardown(client: client, reconnect: reconnectTask)
        client = nil
        reconnectTask = nil
        return out
    }

    // MARK: Publish, subscribe, disconnect

    public func publish(topic: String, payload: [UInt8], qos: Int, retain: Bool) async throws {
        guard let c = currentClient(), c.isActive() else { throw SessionError.notConnected }
        try await c.publish(to: topic, payload: ByteBuffer(bytes: payload), qos: Self.qos(qos), retain: retain)
    }

    public func subscribe(_ topics: [String], qos: Int) async throws {
        guard let c = currentClient(), c.isActive() else { throw SessionError.notConnected }
        _ = try await c.subscribe(to: topics.map { MQTTSubscribeInfo(topicFilter: $0, qos: Self.qos(qos)) })
    }

    public func disconnect() async {
        let gone = takeForDisconnect()
        gone.client?.removePublishListener(named: Self.listenerName)
        gone.reconnect?.cancel()
        guard let c = gone.client else { return }
        if c.isActive() { try? await c.disconnect() }
        try? await c.shutdown()
    }
}
