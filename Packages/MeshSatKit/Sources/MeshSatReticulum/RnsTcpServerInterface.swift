// Mirrors rns/TcpServerInterface.kt: an RNS TCPServerInterface that accepts any number of
// TCPClientInterface peers (rnsd, Sideband, CrossTalk, the interop peers) and exchanges HDLC-framed
// packets with each. A transmit goes to every connected peer, as upstream's server interface does.
// The socket comes from a ByteStreamListenerFactory, so the same class runs on NIO in the Linux
// tests and on NWListener in the app (MESHSAT-1553, MESHSAT-1735).
import Foundation
import MeshSatNet

public final class RnsTcpServerInterface: RnsInterface, @unchecked Sendable {
    public let interfaceId: String
    public let name = "TCP server"
    public let mtu = RnsConstants.mtu
    public let costCents = 0
    public let latencyMs = 50
    public let isBidirectional = true
    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private let factory: any ByteStreamListenerFactory
    private let bindAddress: String
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var receiveCallback: RnsReceiveCallback?
    private var listener: (any ByteStreamListener)?
    private var acceptLoop: Task<Void, Never>?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var running = false
    private var wantedPort = 0

    private final class Peer: @unchecked Sendable {
        let stream: any ByteStream
        var reader: Task<Void, Never>?
        init(stream: any ByteStream) { self.stream = stream }
    }

    public init(
        factory: any ByteStreamListenerFactory, interfaceId: String = "tcp_server_0", bindAddress: String = "127.0.0.1",
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.factory = factory
        self.interfaceId = interfaceId
        self.bindAddress = bindAddress
        self.log = log
    }

    /// The port being listened on, 0 when not listening.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return listener?.port ?? 0
    }

    public func peerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peers.count
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    /// The port `start()` (the RnsInterface entry) listens on; 0 picks a free one.
    public func configure(port: Int) {
        lock.lock()
        wantedPort = port
        lock.unlock()
    }

    public func start() async {
        let p = configuredPort()
        do {
            _ = try await listen(port: p)
        } catch {
            log("rns: tcp server \(interfaceId) could not listen on \(bindAddress):\(p): \(error)")
        }
    }

    /// Listens on `port` (0 picks a free one); returns the port.
    @discardableResult
    public func listen(port: Int = 0) async throws -> Int {
        let l = try await factory.listen(host: bindAddress, port: port)
        let loop = Task { [weak self] in
            for await s in l.connections {
                guard let self else {
                    await s.close()
                    return
                }
                self.adopt(s)
            }
        }
        install(listener: l, loop: loop)
        return l.port
    }

    public func stop() async {
        let t = takeDown()
        t.loop?.cancel()
        for p in t.peers {
            p.reader?.cancel()
            await p.stream.close()
        }
        await t.listener?.close()
    }

    // The lock is taken in synchronous helpers: Swift 6 rejects lock()/unlock() straight inside an async function.

    private func configuredPort() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return wantedPort
    }

    private func install(listener l: any ByteStreamListener, loop: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        listener = l
        acceptLoop = loop
        running = true
    }

    private struct Teardown {
        let listener: (any ByteStreamListener)?
        let loop: Task<Void, Never>?
        let peers: [Peer]
    }

    private func takeDown() -> Teardown {
        lock.lock()
        defer { lock.unlock() }
        running = false
        let l = listener
        listener = nil
        let loop = acceptLoop
        acceptLoop = nil
        let ps = Array(peers.values)
        peers = [:]
        return Teardown(listener: l, loop: loop, peers: ps)
    }

    private func currentPeers() -> [Peer] {
        lock.lock()
        defer { lock.unlock() }
        return Array(peers.values)
    }

    /// Sends to every peer. No peer is not a failure (upstream's server interface does the same, nothing).
    public func send(_ packet: [UInt8]) async -> String? {
        let ps = currentPeers()
        if ps.isEmpty { return nil }
        let frame = RnsHdlc.frame(packet)
        var any = false
        for p in ps {
            do {
                try await p.stream.send(frame)
                any = true
            } catch {
                drop(p)
                await p.stream.close()
            }
        }
        return any ? nil : "tcp server: every peer send failed"
    }

    private func adopt(_ s: any ByteStream) {
        let p = Peer(stream: s)
        let count: Int = {
            lock.lock()
            defer { lock.unlock() }
            peers[ObjectIdentifier(p)] = p
            return peers.count
        }()
        log("rns: tcp peer joined \(interfaceId) (\(count))")
        p.reader = Task { [weak self] in
            var deframer = RnsHdlc.Deframer()
            for await bytes in s.incoming {
                guard let self else { return }
                for frame in deframer.feed(bytes) { self.deliver(frame) }
            }
            guard let self else { return }
            self.drop(p)
            self.log("rns: tcp peer left \(self.interfaceId) (\(self.peerCount()) left)")
        }
    }

    private func drop(_ p: Peer) {
        lock.lock()
        peers[ObjectIdentifier(p)] = nil
        lock.unlock()
    }

    private func deliver(_ packet: [UInt8]) {
        lock.lock()
        let cb = receiveCallback
        lock.unlock()
        cb?(interfaceId, packet)
    }
}
