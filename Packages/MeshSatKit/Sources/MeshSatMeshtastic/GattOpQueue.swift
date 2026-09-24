// Mirrors ble/GattOpQueue.kt: one GATT operation at a time on one connection (MESHSAT-1236).
// Android refuses or silently drops an operation issued while another is in flight, which is
// how the fromNum subscription used to go missing. CoreBluetooth queues internally, but the
// same discipline keeps the pipe's chunked writes acknowledged one by one, gives every
// operation a timeout, and fails what is queued when the connection goes away.
import Foundation

public final class GattOpQueue: @unchecked Sendable {
    // Long enough for the pairing prompt: the first protected operation on a node with a BLE
    // PIN waits while a person types it, and the stack retries it afterwards.
    public static let defaultTimeoutMs: Int64 = 30_000
    public static let statusSuccess = 0
    public static let statusRefused = -1
    public static let statusTimeout = -2
    public static let statusClosed = -3

    /// One operation. `key` names what its callback will report (e.g. "w:<uuid>"), so a late
    /// callback for an operation that already timed out cannot complete the next one.
    public final class Operation: @unchecked Sendable {
        public let key: String
        let start: @Sendable () -> Bool
        private let lock = NSLock()
        private var result: Int?
        private var waiters: [CheckedContinuation<Int, Never>] = []

        init(key: String, start: @escaping @Sendable () -> Bool) {
            self.key = key
            self.start = start
        }

        /// The GATT status of the operation (0 = success), or one of the negative status codes.
        public func await() async -> Int {
            await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                enqueue(c)
            }
        }

        private func enqueue(_ c: CheckedContinuation<Int, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                c.resume(returning: result)
                return
            }
            waiters.append(c)
            lock.unlock()
        }

        /// First completion wins, as CompletableDeferred.complete.
        @discardableResult
        func complete(_ status: Int) -> Bool {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return false
            }
            result = status
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for w in pending { w.resume(returning: status) }
            return true
        }

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return result != nil
        }
    }

    private let timeoutMs: Int64
    private let lock = NSLock()
    private var pending: [Operation] = []
    private var current: Operation?
    private var closed = false
    private var running = false

    public init(timeoutMs: Int64 = GattOpQueue.defaultTimeoutMs) {
        self.timeoutMs = timeoutMs
    }

    /// Queue `start`, which issues the operation and returns false if the stack refused it.
    @discardableResult
    public func enqueue(_ key: String, start: @escaping @Sendable () -> Bool) -> Operation {
        let op = Operation(key: key, start: start)
        lock.lock()
        if closed {
            lock.unlock()
            op.complete(Self.statusClosed)
            return op
        }
        pending.append(op)
        let startRunner = !running
        if startRunner { running = true }
        lock.unlock()
        if startRunner {
            Task { [self] in await self.drain() }
        }
        return op
    }

    /// Called from the GATT callback that finishes the operation reported as `key`.
    public func complete(_ key: String, status: Int) {
        lock.lock()
        let op = current
        lock.unlock()
        guard let op, op.key == key else { return }
        op.complete(status)
    }

    /// Fail everything still queued; used when the connection goes away.
    public func close() {
        lock.lock()
        closed = true
        let queued = pending
        pending.removeAll()
        let inFlight = current
        lock.unlock()
        for op in queued { op.complete(Self.statusClosed) }
        inFlight?.complete(Self.statusClosed)
    }

    private func next() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty {
            running = false
            current = nil
            return nil
        }
        let op = pending.removeFirst()
        current = op
        return op
    }

    private func drain() async {
        while let op = next() {
            await run(op)
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func run(_ op: Operation) async {
        if isClosed {
            op.complete(Self.statusClosed)
            return
        }
        if !op.start() {
            op.complete(Self.statusRefused)
            return
        }
        // Wait for the callback, or the timeout, whichever comes first.
        let deadline = Task { [timeoutMs] in
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            op.complete(Self.statusTimeout)
        }
        _ = await op.await()
        deadline.cancel()
    }
}
