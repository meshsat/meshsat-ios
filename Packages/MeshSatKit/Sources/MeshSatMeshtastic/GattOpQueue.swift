// Mirrors ble/GattOpQueue.kt: one GATT operation at a time on one connection (MESHSAT-1236).
// Android refuses or silently drops an operation issued while another is in flight, which is
// how the fromNum subscription used to go missing. CoreBluetooth queues internally, but the
// same discipline keeps the pipe's chunked writes acknowledged one by one, gives every
// operation a timeout, and fails what is queued when the connection goes away. `enqueueUrgent`
// puts an operation ahead of every queued one (never ahead of the one in flight): the 9704's MO
// segment answer, which the modem waits for only about 360 ms (MESHSAT-1674). `onDead` reports a
// connection that refuses every operation for a minute (MESHSAT-1816), so its owner reconnects.
import Foundation

public final class GattOpQueue: @unchecked Sendable {
    // Long enough for the pairing prompt: the first protected operation on a node with a BLE
    // PIN waits while a person types it, and the stack retries it afterwards.
    public static let defaultTimeoutMs: Int64 = 30_000
    public static let statusSuccess = 0
    public static let statusRefused = -1
    public static let statusTimeout = -2
    public static let statusClosed = -3

    /// How long every operation may be refused before the connection counts as dead. The first
    /// subscriptions after a connect can be refused while the link comes up, and the next operation
    /// is accepted; a minute is far beyond that (Android's DEAD_AFTER_MS, MESHSAT-1816).
    public static let deadAfterMs: Int64 = 60_000
    /// And at least this many refusals in that time, so one slow retry is not enough.
    public static let deadAfterRefusals = 3

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
    private let nowMs: @Sendable () -> Int64
    private let lock = NSLock()
    // The run of refusals, guarded by `lock`; one operation runs at a time.
    private var refusedSinceMs: Int64 = 0
    private var refusedCount = 0
    private var deadReported = false
    private var deadHandler: (@Sendable (_ refused: Int, _ forMs: Int64) -> Void)?

    /// Called once when every operation has been refused for `deadAfterMs`, at least
    /// `deadAfterRefusals` of them, with none accepted in between: the connection is dead and its
    /// owner drops it and connects again. On Android a restart of the Bluetooth process left the
    /// client refusing every call with no disconnect callback (MESHSAT-1816); CoreBluetooth reports a
    /// restart as `.resetting`, and this is the guard for a link that still says connected while its
    /// characteristics cannot be found. Timeouts do not count: the node may be slow, not gone.
    public var onDead: (@Sendable (_ refused: Int, _ forMs: Int64) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return deadHandler
        }
        set {
            lock.lock()
            deadHandler = newValue
            lock.unlock()
        }
    }
    private var pending: [Operation] = []
    private var urgent: [Operation] = []
    private var current: Operation?
    private var closed = false
    private var running = false

    public init(
        timeoutMs: Int64 = GattOpQueue.defaultTimeoutMs,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.timeoutMs = timeoutMs
        self.nowMs = nowMs
    }

    /// Queue `start`, which issues the operation and returns false if the stack refused it.
    @discardableResult
    public func enqueue(_ key: String, start: @escaping @Sendable () -> Bool) -> Operation {
        offer(Operation(key: key, start: start), urgent: false)
    }

    /// As `enqueue`, ahead of every operation still waiting.
    @discardableResult
    public func enqueueUrgent(_ key: String, start: @escaping @Sendable () -> Bool) -> Operation {
        offer(Operation(key: key, start: start), urgent: true)
    }

    private func offer(_ op: Operation, urgent isUrgent: Bool) -> Operation {
        lock.lock()
        if closed {
            lock.unlock()
            op.complete(Self.statusClosed)
            return op
        }
        if isUrgent { urgent.append(op) } else { pending.append(op) }
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
        let queued = urgent + pending
        urgent.removeAll()
        pending.removeAll()
        let inFlight = current
        lock.unlock()
        for op in queued { op.complete(Self.statusClosed) }
        inFlight?.complete(Self.statusClosed)
    }

    private func next() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        if urgent.isEmpty && pending.isEmpty {
            running = false
            current = nil
            return nil
        }
        let op = urgent.isEmpty ? pending.removeFirst() : urgent.removeFirst()
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
            // Before the caller hears of the refusal, so the verdict is in when it does.
            noteRefused()
            op.complete(Self.statusRefused)
            return
        }
        noteAccepted()
        // Wait for the callback, or the timeout, whichever comes first.
        let deadline = Task { [timeoutMs] in
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            op.complete(Self.statusTimeout)
        }
        _ = await op.await()
        deadline.cancel()
    }

    private func noteAccepted() {
        lock.lock()
        refusedCount = 0
        lock.unlock()
    }

    private func noteRefused() {
        let now = nowMs()
        lock.lock()
        if refusedCount == 0 { refusedSinceMs = now }
        refusedCount += 1
        let dead = !deadReported && refusedCount >= Self.deadAfterRefusals && now - refusedSinceMs >= Self.deadAfterMs
        if dead { deadReported = true }
        let count = refusedCount
        let since = refusedSinceMs
        let handler = deadHandler
        lock.unlock()
        if dead { handler?(count, now - since) }
    }
}
