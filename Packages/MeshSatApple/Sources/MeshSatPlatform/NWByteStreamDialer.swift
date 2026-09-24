// MeshSatNet.ByteStreamDialer on Network.framework: the TCP (and TLS) client connections of the
// Reticulum TCP interface (Android: java.net.Socket and an SSLSocketFactory). The Hub-issued
// client certificate is presented as the TLS local identity, from the Keychain as the MQTT
// session does (MESHSAT-1324); the server is checked against the system roots, and the bundle's
// CA, which signs bridge certificates, is never made a server trust root.
import Foundation
import MeshSatMQTT
import MeshSatNet
import Network

public struct NWByteStreamDialer: ByteStreamDialer {
    public init() {}

    public func dial(host: String, port: Int, tls: TlsClientOptions?, timeoutSeconds: Double) async throws -> any ByteStream {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ByteStreamError.refused("bad port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.connectionTimeout = Int(timeoutSeconds)
        let params: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            if tls.hasClientIdentity {
                let identity: SecIdentity
                do {
                    identity = try KeychainClientIdentity.make(certPem: tls.clientCertPem, keyPem: tls.clientKeyPem)
                } catch {
                    throw ByteStreamError.refused("client certificate: \(error)")
                }
                if let sec = sec_identity_create(identity) { sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec) }
            }
            params = NWParameters(tls: options, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        let stream = NWByteStream(connection: connection)
        try await stream.open()
        return stream
    }
}

final class NWByteStream: ByteStream, @unchecked Sendable {
    let incoming: AsyncStream<[UInt8]>
    private let feed: AsyncStream<[UInt8]>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "net.meshsat.ios.tcp")
    private let lock = NSLock()
    private var closed = false
    private var opener: CheckedContinuation<Void, Error>?

    init(connection: NWConnection) {
        self.connection = connection
        var continuation: AsyncStream<[UInt8]>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        feed = continuation
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            setOpener(c)
            connection.stateUpdateHandler = { [weak self] state in self?.onState(state) }
            connection.start(queue: queue)
        }
    }

    private func setOpener(_ c: CheckedContinuation<Void, Error>?) {
        lock.lock()
        opener = c
        lock.unlock()
    }

    private func takeOpener() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = opener
        opener = nil
        return c
    }

    private func onState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            takeOpener()?.resume()
            receiveNext()
        case .failed(let error):
            takeOpener()?.resume(throwing: ByteStreamError.refused(error.localizedDescription))
            finish()
        case .cancelled:
            takeOpener()?.resume(throwing: ByteStreamError.closed)
            finish()
        case .waiting(let error):
            // No route yet (airplane mode, no Wi-Fi): fail the dial so the interface retries.
            takeOpener()?.resume(throwing: ByteStreamError.refused(error.localizedDescription))
            connection.cancel()
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.feed.yield(Array(data)) }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.receiveNext()
        }
    }

    private func finish() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        if !was {
            feed.finish()
            connection.cancel()
        }
    }

    private func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func send(_ bytes: [UInt8]) async throws {
        if isClosed() { throw ByteStreamError.closed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error { c.resume(throwing: ByteStreamError.refused(error.localizedDescription)) } else { c.resume() }
                })
        }
    }

    func close() async { finish() }
}
