// MeshSatNet.ByteStreamListener on Network.framework: the listening side of the Reticulum TCP
// server interface (Android: java.net.ServerSocket in TcpServerInterface.kt), so a Sideband or an
// rnsd on the same WiFi can connect to the phone while the app is in the foreground. Plain TCP; each
// accepted connection is an NWByteStream like the dialer's.
import Foundation
import MeshSatNet
import Network

public struct NWByteStreamListenerFactory: ByteStreamListenerFactory {
    public init() {}

    public func listen(host: String, port: Int) async throws -> any ByteStreamListener {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ByteStreamError.refused("bad port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcp)
        if host == "127.0.0.1" || host == "localhost" {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: p)
        } catch {
            throw ByteStreamError.refused("listen: \(error)")
        }
        let l = NWByteStreamListener(listener: listener)
        try await l.start()
        return l
    }
}

final class NWByteStreamListener: ByteStreamListener, @unchecked Sendable {
    let connections: AsyncStream<any ByteStream>
    private let feed: AsyncStream<any ByteStream>.Continuation
    private let listener: NWListener
    private let queue = DispatchQueue(label: "net.meshsat.ios.tcp.listener")
    private let lock = NSLock()
    private var starter: CheckedContinuation<Void, Error>?
    private var closed = false

    init(listener: NWListener) {
        self.listener = listener
        var continuation: AsyncStream<any ByteStream>.Continuation!
        connections = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        feed = continuation
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            starter = c
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in self?.onState(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    private func takeStarter() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = starter
        starter = nil
        return c
    }

    private func onState(_ state: NWListener.State) {
        switch state {
        case .ready:
            takeStarter()?.resume()
        case .failed(let error):
            takeStarter()?.resume(throwing: ByteStreamError.refused(error.localizedDescription))
            finish()
        case .cancelled:
            takeStarter()?.resume(throwing: ByteStreamError.closed)
            finish()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let stream = NWByteStream(connection: connection)
        Task { [feed] in
            do {
                try await stream.open()
                feed.yield(stream)
            } catch {
                await stream.close()
            }
        }
    }

    private func finish() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        if !was { feed.finish() }
    }

    func close() async {
        finish()
        listener.cancel()
    }
}

/// The phone's own address on the WiFi, for the Setup card ("add a TCP client interface to <ip> port N"
/// in Sideband); mirrors RnsTcpServerInterface.wifiAddress() on Android.
public enum LocalNetwork {
    public static func wifiAddress() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                if name == "en0" { break }
            }
        }
        return found
    }
}
