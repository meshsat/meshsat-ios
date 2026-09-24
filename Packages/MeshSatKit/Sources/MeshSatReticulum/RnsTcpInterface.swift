// Mirrors reticulum/RnsTcpInterface.kt: a Reticulum interface over TCP with HDLC framing, wire
// compatible with the Python RNS TCPClientInterface. No handshake: packets flow the moment the
// connection is up. Reconnects every five seconds while running (MESHSAT-268). The socket comes
// from a ByteStreamDialer, so the loop runs on Linux against a loopback in the tests.
import Foundation
import MeshSatNet

public final class RnsTcpInterface: RnsInterface, @unchecked Sendable {
    public static let defaultPort = 4242
    public static let reconnectWaitMs: Int64 = 5_000
    public static let connectTimeoutSeconds: Double = 10

    public enum State: Sendable, Equatable { case disconnected, connecting, connected, error }

    public let interfaceId: String
    public let name = "TCP"
    public let mtu = RnsConstants.mtu
    public let costCents = 0
    public let latencyMs = 50
    public let isBidirectional = true
    public let state = StateBroadcast<State>(.disconnected)
    public let error = StateBroadcast<String>("")
    public var isOnline: Bool { state.value == .connected }

    private let dialer: any ByteStreamDialer
    private let sleep: @Sendable (Int64) async throws -> Void
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var receiveCallback: RnsReceiveCallback?
    private var stream: (any ByteStream)?
    private var running = false
    private var loop: Task<Void, Never>?
    private var hostValue = ""
    private var portValue = RnsTcpInterface.defaultPort
    private var tlsValue: TlsClientOptions?

    public init(
        dialer: any ByteStreamDialer, interfaceId: String = "tcp_rns_0",
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dialer = dialer
        self.interfaceId = interfaceId
        self.sleep = sleep
        self.log = log
    }

    public var host: String {
        lock.lock()
        defer { lock.unlock() }
        return hostValue
    }

    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return portValue
    }

    public var useTls: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tlsValue != nil
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    /// Connect to a remote Reticulum node and keep reconnecting. `tls` non-nil wraps the
    /// connection in TLS (a port 443 behind HAProxy or stunnel), with mTLS when it holds a
    /// client identity.
    public func connect(host: String, port: Int = RnsTcpInterface.defaultPort, tls: TlsClientOptions? = nil) {
        lock.lock()
        hostValue = host
        portValue = port
        tlsValue = tls
        running = true
        let old = loop
        lock.unlock()
        old?.cancel()
        error.send("")
        let task = Task { [self] in await connectionLoop() }
        lock.lock()
        loop = task
        lock.unlock()
    }

    public func start() async {
        // The connection is managed by connect().
    }

    public func stop() async { disconnect() }

    public func disconnect() {
        lock.lock()
        running = false
        let l = loop
        loop = nil
        let s = stream
        stream = nil
        lock.unlock()
        l?.cancel()
        if let s { Task { await s.close() } }
        state.send(.disconnected)
    }

    public func send(_ packet: [UInt8]) async -> String? {
        guard isOnline else { return "tcp interface offline" }
        guard let s = currentStream() else { return "tcp not connected" }
        do {
            try await s.send(RnsHdlc.frame(packet))
            return nil
        } catch {
            self.error.send("\(error)")
            state.send(.error)
            return "tcp send failed: \(error)"
        }
    }

    private func currentStream() -> (any ByteStream)? {
        lock.lock()
        defer { lock.unlock() }
        return stream
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func takeStream() -> (any ByteStream)? {
        lock.lock()
        defer { lock.unlock() }
        let s = stream
        stream = nil
        return s
    }

    private struct Target {
        let host: String
        let port: Int
        let tls: TlsClientOptions?
    }

    private func target() -> Target {
        lock.lock()
        defer { lock.unlock() }
        return Target(host: hostValue, port: portValue, tls: tlsValue)
    }

    private func install(_ s: any ByteStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return false }
        stream = s
        return true
    }

    private func deliver(_ packet: [UInt8]) {
        lock.lock()
        let cb = receiveCallback
        lock.unlock()
        cb?(interfaceId, packet)
    }

    private func connectionLoop() async {
        while isRunning(), !Task.isCancelled {
            let t = target()
            let (h, p, tls) = (t.host, t.port, t.tls)
            state.send(.connecting)
            do {
                let s = try await dialer.dial(host: h, port: p, tls: tls, timeoutSeconds: Self.connectTimeoutSeconds)
                guard install(s) else {
                    await s.close()
                    return
                }
                state.send(.connected)
                log("Connected to \(h):\(p)\(tls != nil ? " (TLS)" : "")")
                await readLoop(s)
            } catch {
                log("TCP connection failed: \(error)")
                self.error.send("\(error)")
            }
            state.send(.disconnected)
            if let s = takeStream() { await s.close() }
            guard isRunning() else { return }
            log("Reconnecting in \(Self.reconnectWaitMs / 1000)s...")
            guard (try? await sleep(Self.reconnectWaitMs)) != nil else { return }
        }
    }

    /// HDLC-framed packets from the stream, delivered whole.
    private func readLoop(_ s: any ByteStream) async {
        var deframer = RnsHdlc.Deframer()
        for await bytes in s.incoming {
            guard isRunning() else { return }
            for frame in deframer.feed(bytes) { deliver(frame) }
        }
    }
}
