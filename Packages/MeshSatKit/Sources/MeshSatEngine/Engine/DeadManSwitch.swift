// Mirrors engine/DeadManSwitch.kt (a port of the Bridge's internal/engine/deadman.go): an SOS
// when nothing has happened for the timeout. Checks every 60 s; the clock and the sleep are
// injected so the tests never wait.
import Foundation
import Logging

public final class DeadManSwitch: @unchecked Sendable {
    public static let checkIntervalMs: Int64 = 60_000
    public typealias SosCallback = @Sendable (_ lat: Double, _ lon: Double, _ lastSeenEpoch: Int64) async -> Void

    private static let log = Logger(label: "DeadManSwitch")
    private let lock = NSLock()
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let latestPosition: @Sendable () async -> (lat: Double, lon: Double)?
    private var timeoutSecValue: Int64
    private var lastActiveEpoch: Int64
    private var enabledValue = false
    private var triggeredValue = false
    private var callback: SosCallback?
    private var loop: Task<Void, Never>?

    /// `latestPosition` is the newest stored fix, for the SOS's coordinates.
    public init(
        timeoutSec: Int64, latestPosition: @escaping @Sendable () async -> (lat: Double, lon: Double)?,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) {
        self.timeoutSecValue = timeoutSec
        self.latestPosition = latestPosition
        self.now = now
        self.sleep = sleep
        self.lastActiveEpoch = now() / 1000
    }

    public func setSosCallback(_ cb: SosCallback?) {
        lock.lock()
        callback = cb
        lock.unlock()
    }

    /// The check loop, every 60 s.
    public func start() {
        stop()
        Self.log.info("dead man's switch started (timeout=\(timeoutSec)s)")
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, (try? await sleep(Self.checkIntervalMs)) != nil else { return }
                await check()
            }
        }
        lock.lock()
        loop = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let l = loop
        loop = nil
        lock.unlock()
        l?.cancel()
    }

    /// Any user activity: the timer restarts, and a triggered switch may fire again later.
    public func touch() {
        lock.lock()
        lastActiveEpoch = now() / 1000
        triggeredValue = false
        lock.unlock()
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledValue
    }

    public func setEnabled(_ value: Bool) {
        lock.lock()
        enabledValue = value
        lock.unlock()
    }

    public var isTriggered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return triggeredValue
    }

    /// Seconds since the epoch.
    public var lastActivity: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return lastActiveEpoch
    }

    public var timeoutSec: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return timeoutSecValue
        }
        set {
            lock.lock()
            timeoutSecValue = newValue
            lock.unlock()
        }
    }

    /// What the loop runs: fires the callback once when the timeout has passed.
    public func check() async {
        guard let (lastActive, cb) = arm() else { return }
        Self.log.warning("dead man's switch triggered (last_active=\(lastActive))")
        let pos = await latestPosition()
        await cb?(pos?.lat ?? 0, pos?.lon ?? 0, lastActive)
    }

    /// Marks the switch triggered when it should fire; nil otherwise.
    private func arm() -> (Int64, SosCallback?)? {
        lock.lock()
        defer { lock.unlock() }
        guard enabledValue, !triggeredValue else { return nil }
        let elapsed = now() / 1000 - lastActiveEpoch
        guard elapsed > timeoutSecValue else { return nil }
        triggeredValue = true
        return (lastActiveEpoch, callback)
    }
}
