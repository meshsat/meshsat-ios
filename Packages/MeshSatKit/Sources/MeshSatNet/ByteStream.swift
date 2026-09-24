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
    var incoming: AsyncStream<WebSocketFrame> { get }
    func send(_ frame: WebSocketFrame) async throws
    func close(code: UInt16, reason: String) async
}

public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary([UInt8])
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
        a.lock.lock(); a.peer = b; a.lock.unlock()
        b.lock.lock(); b.peer = a; b.lock.unlock()
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
