// A one-shot result that completes exactly once and can be awaited or observed; the Swift stand-in
// for java.util.concurrent.CompletableFuture as MeshSat Android's rns/ and lxmf/ packages use it
// (Link.established, Receipt.result, RequestReceipt.result, OutgoingResource.result). Callbacks
// run outside the lock, on the completing thread; a callback registered after completion runs at
// once. Nothing in here knows about the node.
import Foundation

public struct PromiseTimeout: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String = "timed out") { self.description = description }
}

public final class Promise<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, any Error>?
    private var waiters: [CheckedContinuation<T, any Error>] = []
    private var callbacks: [@Sendable (Result<T, any Error>) -> Void] = []

    public init() {}

    public static func completed(_ value: T) -> Promise<T> {
        let p = Promise<T>()
        p.complete(value)
        return p
    }

    public var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored != nil
    }

    /// The value when completed successfully, nil otherwise.
    public var value: T? {
        if case .success(let v)? = result { return v }
        return nil
    }

    public var result: Result<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// True when this call completed it; false when it already held a result.
    @discardableResult
    public func complete(_ value: T) -> Bool { settle(.success(value)) }

    @discardableResult
    public func fail(_ error: any Error) -> Bool { settle(.failure(error)) }

    private func settle(_ r: Result<T, any Error>) -> Bool {
        lock.lock()
        if stored != nil {
            lock.unlock()
            return false
        }
        stored = r
        let ws = waiters
        let cbs = callbacks
        waiters = []
        callbacks = []
        lock.unlock()
        for w in ws { w.resume(with: r) }
        for cb in cbs { cb(r) }
        return true
    }

    /// Runs `cb` once the promise settles (at once when it already has).
    public func onResult(_ cb: @escaping @Sendable (Result<T, any Error>) -> Void) {
        lock.lock()
        if let r = stored {
            lock.unlock()
            cb(r)
            return
        }
        callbacks.append(cb)
        lock.unlock()
    }

    /// Awaits the value; throws what `fail` was given.
    public func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            lock.lock()
            if let r = stored {
                lock.unlock()
                c.resume(with: r)
                return
            }
            waiters.append(c)
            lock.unlock()
        }
    }

    /// Awaits the value for at most `timeoutMs` of wall-clock time, then throws `PromiseTimeout`.
    public func wait(timeoutMs: Int64) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await self.wait() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
                throw PromiseTimeout("no result after \(timeoutMs) ms")
            }
            let v = try await group.next()!
            group.cancelAll()
            return v
        }
    }
}
