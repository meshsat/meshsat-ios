// MeshSatNet.ByteStreamDialer on Network.framework: the TCP (and TLS) client connections of the
// Reticulum TCP interface (Android: java.net.Socket and an SSLSocketFactory). The Hub-issued
// client certificate for mTLS is not yet applied: Network.framework needs a SecIdentity built
// from the PEM pair, the same gap as MqttNioSession on iOS (MESHSAT-1324); a CA PEM in the
// options is likewise not yet pinned, the system roots are trusted.
import Foundation
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
        let params = tls != nil ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
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
