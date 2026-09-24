// The Swift stand-in for Kotlin's SharedFlow/StateFlow: one sender, any number of subscribers,
// each with its own bounded buffer that keeps the newest values. Used by the transports to
// report state, readings and events without holding a reference to whoever listens.
import Foundation

public final class Broadcast<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<T>.Continuation] = [:]
    private var latest: T?
    private let replayLatest: Bool
    private let bufferSize: Int

    /// `replayLatest` makes it a StateFlow: a new subscriber first gets the current value.
    public init(replayLatest: Bool = false, bufferSize: Int = 8) {
        self.replayLatest = replayLatest
        self.bufferSize = bufferSize
    }

    public var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public func send(_ value: T) {
        lock.lock()
        latest = value
        let targets = Array(subscribers.values)
        lock.unlock()
        for c in targets { c.yield(value) }
    }

    public func subscribe() -> AsyncStream<T> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        lock.lock()
        subscribers[id] = continuation
        let replay = replayLatest ? latest : nil
        lock.unlock()
        if let replay { continuation.yield(replay) }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func finish() {
        lock.lock()
        let targets = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for c in targets { c.finish() }
    }
}

/// A mutex for actors: an actor is re-entrant at every `await`, and the AT driver must run one
/// modem command at a time from start to finish, as Android's @Synchronized methods did.
public final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            enqueue(c)
        }
    }

    // Synchronous, so the lock is never taken inside an async function (Swift 6 rejects that).
    private func enqueue(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if !locked {
            locked = true
            lock.unlock()
            c.resume()
            return
        }
        waiters.append(c)
        lock.unlock()
    }

    public func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }

    public func withLock<R: Sendable>(_ body: () async throws -> R) async rethrows -> R {
        await acquire()
        defer { release() }
        return try await body()
    }
}
