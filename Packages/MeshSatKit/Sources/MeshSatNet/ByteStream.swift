// MeshSatNet: the transport protocols the pure modules speak, so that every network-facing
// component (Reticulum TCP interfaces, APRS-IS, KISS, the Hub relay) is testable on Linux with
// a loopback and runs on Network.framework in Packages/MeshSatApple. Mirrors the places where
// MeshSat Android used java.net.Socket and OkHttp directly.
import Foundation

public protocol ByteStream: Sendable {
    /// Bytes arriving from the peer. Finishes when the stream closes.
    var incoming: AsyncStream<[UInt8]> { get }
    func send(_ bytes: [UInt8]) async throws
    func close() async
}

public protocol WebSocketTransport: Sendable {
    /// Frames from the peer. A `.close` frame is the last element when the peer closed; the
    /// stream ends without one when the transport failed.
    var incoming: AsyncStream<WebSocketFrame> { get }
    func send(_ frame: WebSocketFrame) async throws
    func close(code: UInt16, reason: String) async
}

public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary([UInt8])
    /// The peer's close frame: its status code and reason.
    case close(code: UInt16, reason: String)
}

/// Opens WebSocket client connections (OkHttp's newWebSocket; URLSessionWebSocketTask on Apple).
public protocol WebSocketDialer: Sendable {
    func dial(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> any WebSocketTransport
}

public enum WebSocketDialError: Error, Equatable, Sendable {
    /// The server answered before the upgrade with this HTTP status.
    case refused(Int)
    case failed(String)
}

/// Two ends of an in-memory WebSocket for tests: frames sent by one arrive at the other, and a
/// close from either end is delivered to the other as a `.close` frame that ends its stream.
public final class LoopbackWebSocket: WebSocketTransport, @unchecked Sendable {
    public let incoming: AsyncStream<WebSocketFrame>
    private let feed: AsyncStream<WebSocketFrame>.Continuation
    private let lock = NSLock()
    private var peer: LoopbackWebSocket?
    private var closed = false
    /// The close code and reason this end received from the peer, or sent itself.
    public private(set) var closedWith: (code: UInt16, reason: String)?

    private init() {
        var continuation: AsyncStream<WebSocketFrame>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        feed = continuation
    }

    public static func pair() -> (LoopbackWebSocket, LoopbackWebSocket) {
        let a = LoopbackWebSocket()
        let b = LoopbackWebSocket()
        a.lock.lock()
        a.peer = b
        a.lock.unlock()
        b.lock.lock()
        b.peer = a
        b.lock.unlock()
        return (a, b)
    }

    private func snapshot() -> (closed: Bool, peer: LoopbackWebSocket?) {
        lock.lock()
        defer { lock.unlock() }
        return (closed, peer)
    }

    private func markClosed(code: UInt16, reason: String) -> (wasClosed: Bool, peer: LoopbackWebSocket?) {
        lock.lock()
        defer { lock.unlock() }
        let was = closed
        closed = true
        if closedWith == nil { closedWith = (code, reason) }
        return (was, peer)
    }

    public func send(_ frame: WebSocketFrame) async throws {
        let state = snapshot()
        guard !state.closed, let other = state.peer else { throw ByteStreamError.closed }
        other.feed.yield(frame)
    }

    public func close(code: UInt16, reason: String) async {
        let state = markClosed(code: code, reason: reason)
        guard !state.wasClosed else { return }
        feed.finish()
        if let other = state.peer, !other.markClosed(code: code, reason: reason).wasClosed {
            other.feed.yield(.close(code: code, reason: reason))
            other.feed.finish()
        }
    }
}

public struct HttpResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: [UInt8]
    public init(status: Int, headers: [String: String] = [:], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HttpGetter: Sendable {
    func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> HttpResponse
}

/// TLS for a client connection: the Hub-issued client certificate and key for mTLS, and the CA
/// to trust instead of the system roots when given (mqtt/CertificatePinner.createMtlsSSLSocketFactory).
public struct TlsClientOptions: Sendable, Equatable {
    public var clientCertPem: String
    public var clientKeyPem: String
    public var caCertPem: String
    public init(clientCertPem: String = "", clientKeyPem: String = "", caCertPem: String = "") {
        self.clientCertPem = clientCertPem
        self.clientKeyPem = clientKeyPem
        self.caCertPem = caCertPem
    }
    public var hasClientIdentity: Bool { !clientCertPem.isEmpty && !clientKeyPem.isEmpty }
}

/// Opens TCP (optionally TLS) client connections: java.net.Socket on Android, Network.framework
/// on the phone, a loopback in the tests.
public protocol ByteStreamDialer: Sendable {
    func dial(host: String, port: Int, tls: TlsClientOptions?, timeoutSeconds: Double) async throws -> any ByteStream
}

public enum ByteStreamError: Error, Equatable, Sendable {
    case closed
    case timeout
    case refused(String)
}

/// Two ends of an in-memory pipe for tests: what one side sends, the other receives.
public final class LoopbackByteStream: ByteStream, @unchecked Sendable {
    public let incoming: AsyncStream<[UInt8]>
    private let feed: AsyncStream<[UInt8]>.Continuation
    private let lock = NSLock()
    private var peer: LoopbackByteStream?
    private var closed = false

    private init() {
        var continuation: AsyncStream<[UInt8]>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        feed = continuation
    }

    public static func pair() -> (LoopbackByteStream, LoopbackByteStream) {
        let a = LoopbackByteStream()
        let b = LoopbackByteStream()
        a.lock.lock()
        a.peer = b
        a.lock.unlock()
        b.lock.lock()
        b.peer = a
        b.lock.unlock()
        return (a, b)
    }

    // The lock is taken in synchronous helpers: Swift 6 rejects lock()/unlock() straight inside
    // an async function, and the sections are too small for an actor hop to be worth it.
    private func snapshot() -> (closed: Bool, peer: LoopbackByteStream?) {
        lock.lock()
        defer { lock.unlock() }
        return (closed, peer)
    }

    private func markClosed() -> (wasClosed: Bool, peer: LoopbackByteStream?) {
        lock.lock()
        defer { lock.unlock() }
        let was = closed
        closed = true
        return (was, peer)
    }

    public func send(_ bytes: [UInt8]) async throws {
        let state = snapshot()
        guard !state.closed, let other = state.peer else { throw ByteStreamError.closed }
        other.feed.yield(bytes)
    }

    /// Closing one end closes both, as a socket does: the peer's sends fail and its stream ends.
    public func close() async {
        let state = markClosed()
        guard !state.wasClosed else { return }
        feed.finish()
        if let other = state.peer, !other.markClosed().wasClosed {
            other.feed.finish()
        }
    }
}
