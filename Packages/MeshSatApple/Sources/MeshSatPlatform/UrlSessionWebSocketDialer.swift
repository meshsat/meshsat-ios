// MeshSatNet.WebSocketDialer on URLSessionWebSocketTask: the Hub relay's socket (Android used
// OkHttp's newWebSocket). A server answer before the upgrade surfaces as
// WebSocketDialError.refused(status); the peer's close frame ends the incoming stream with
// a .close element carrying its code and reason.
import Foundation
import MeshSatNet

public struct UrlSessionWebSocketDialer: WebSocketDialer {
    public init() {}

    public func dial(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> any WebSocketTransport {
        guard let u = URL(string: url) else { throw WebSocketDialError.failed("bad URL: \(url)") }
        var request = URLRequest(url: u, timeoutInterval: timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let opener = Opener()
        let session = URLSession(configuration: .ephemeral, delegate: opener, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let socket = UrlSessionWebSocket(task: task, session: session)
        task.resume()
        try await opener.opened()
        socket.startReading()
        return socket
    }
}

/// Waits for the upgrade: didOpen resolves it, a completion before that is a refusal or a failure.
private final class Opener: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func opened() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let ready = take(c)
            if let ready { c.resume(with: ready) }
        }
    }

    private func take(_ c: CheckedContinuation<Void, Error>) -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        continuation = c
        return nil
    }

    private func settle(_ r: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        settle(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            settle(.failure(WebSocketDialError.refused(http.statusCode)))
        } else {
            settle(.failure(WebSocketDialError.failed(error?.localizedDescription ?? "connection closed before the upgrade")))
        }
    }
}

final class UrlSessionWebSocket: WebSocketTransport, @unchecked Sendable {
    let incoming: AsyncStream<WebSocketFrame>
    private let feed: AsyncStream<WebSocketFrame>.Continuation
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var closed = false

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
        var continuation: AsyncStream<WebSocketFrame>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        feed = continuation
    }

    func startReading() {
        Task { [self] in
            while !isClosed() {
                do {
                    switch try await task.receive() {
                    case .data(let d): feed.yield(.binary(Array(d)))
                    case .string(let s): feed.yield(.text(s))
                    @unknown default: break
                    }
                } catch {
                    // The peer's close frame, or a failure: the code says which.
                    if task.closeCode != .invalid {
                        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        feed.yield(.close(code: UInt16(task.closeCode.rawValue), reason: reason))
                    }
                    finish()
                    return
                }
            }
        }
    }

    private func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func finish() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        if !was {
            feed.finish()
            session.finishTasksAndInvalidate()
        }
    }

    func send(_ frame: WebSocketFrame) async throws {
        if isClosed() { throw ByteStreamError.closed }
        switch frame {
        case .binary(let b): try await task.send(.data(Data(b)))
        case .text(let s): try await task.send(.string(s))
        case .close(let code, let reason): await close(code: code, reason: reason)
        }
    }

    func close(code: UInt16, reason: String) async {
        if isClosed() { return }
        let c = URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure
        task.cancel(with: c, reason: reason.isEmpty ? nil : Data(reason.utf8))
        finish()
    }
}
