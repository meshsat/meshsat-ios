// Mirrors engine/InterfaceManager.kt (the Bridge's engine.InterfaceManager): the lifecycle and
// reconnection of every transport interface. State changes drive the Dispatcher's hold and
// unhold of deliveries.
//
//   Offline --connect--> Connecting --success--> Online
//                                   --fail-----> Error --backoff--> Offline (auto-retry)
//   Online  --disconnect/error--> Offline (auto-retry if enabled)
//   Any     --disable--> Disabled;  Disabled --enable--> Offline
import Foundation
import Logging
import MeshSatNet

public enum InterfaceState: String, Sendable, Equatable {
    case offline, connecting, online, error, disabled
    public var isAvailable: Bool { self == .online }
}

/// Per-interface runtime status snapshot.
public struct InterfaceStatus: Sendable, Equatable {
    public var id: String
    public var channelType: String
    public var state: InterfaceState
    public var error: String
    public var lastOnline: Int64
    public var lastActivity: Int64
    public var reconnectAttempts: Int
}

public struct InterfaceConfig: Sendable, Equatable {
    public var id: String
    public var channelType: String
    public var autoReconnect: Bool
    public var initialBackoffMs: Int64
    public var maxBackoffMs: Int64
    /// Always considered online (e.g. the SMS composer lane).
    public var alwaysOnline: Bool

    public init(
        id: String, channelType: String, autoReconnect: Bool = true, initialBackoffMs: Int64 = 5_000, maxBackoffMs: Int64 = 120_000,
        alwaysOnline: Bool = false
    ) {
        self.id = id
        self.channelType = channelType
        self.autoReconnect = autoReconnect
        self.initialBackoffMs = initialBackoffMs
        self.maxBackoffMs = maxBackoffMs
        self.alwaysOnline = alwaysOnline
    }
}

public final class InterfaceManager: InterfaceStatusProvider, @unchecked Sendable {
    private static let log = Logger(label: "InterfaceMgr")

    public typealias ConnectCallback = @Sendable (_ interfaceId: String) async -> String?
    public typealias DisconnectCallback = @Sendable (_ interfaceId: String) -> Void
    public typealias StateChangeCallback =
        @Sendable (_ id: String, _ channelType: String, _ old: InterfaceState, _ new: InterfaceState) -> Void

    private struct Runtime {
        let config: InterfaceConfig
        var state: InterfaceState
        var errorMsg = ""
        var lastOnline: Int64 = 0
        var lastActivity: Int64 = 0
        var reconnectAttempts = 0

        var status: InterfaceStatus {
            InterfaceStatus(
                id: config.id, channelType: config.channelType, state: state, error: errorMsg, lastOnline: lastOnline,
                lastActivity: lastActivity, reconnectAttempts: reconnectAttempts)
        }
    }

    private let lock = NSLock()
    private var runtimes: [String: Runtime] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var connectCallback: ConnectCallback?
    private var disconnectCallback: DisconnectCallback?
    private var onStateChange: StateChangeCallback?
    private let clock: any DriverClock

    /// Every interface's status, for the screens.
    public let states = StateBroadcast<[String: InterfaceStatus]>([:])

    public init(clock: any DriverClock = SystemDriverClock()) {
        self.clock = clock
    }

    public func setConnectCallback(_ cb: @escaping ConnectCallback) {
        lock.lock()
        connectCallback = cb
        lock.unlock()
    }

    public func setDisconnectCallback(_ cb: @escaping DisconnectCallback) {
        lock.lock()
        disconnectCallback = cb
        lock.unlock()
    }

    /// Fires on every state transition; the Dispatcher holds and unholds deliveries on it.
    public func setStateChangeCallback(_ cb: @escaping StateChangeCallback) {
        lock.lock()
        onStateChange = cb
        lock.unlock()
    }

    public func register(_ config: InterfaceConfig) {
        let now = clock.nowMs()
        let initial: InterfaceState = config.alwaysOnline ? .online : .offline
        lock.lock()
        runtimes[config.id] = Runtime(
            config: config, state: initial, lastOnline: config.alwaysOnline ? now : 0, lastActivity: config.alwaysOnline ? now : 0)
        lock.unlock()
        publish()
        Self.log.info("Registered interface \(config.id) (\(config.channelType)) state=\(initial)")
    }

    public func unregister(_ id: String) {
        cancelReconnect(id)
        lock.lock()
        runtimes[id] = nil
        lock.unlock()
        publish()
    }

    public func getState(_ id: String) -> InterfaceState {
        lock.lock()
        defer { lock.unlock() }
        return runtimes[id]?.state ?? .offline
    }

    public func isOnline(_ id: String) -> Bool { getState(id) == .online }

    public func getAllStatus() -> [InterfaceStatus] {
        lock.lock()
        defer { lock.unlock() }
        return runtimes.values.map(\.status)
    }

    /// The transport connected.
    public func setOnline(_ id: String) {
        cancelReconnect(id)
        let now = clock.nowMs()
        guard
            let (old, type) = mutate(
                id,
                { rt in
                    let old = rt.state
                    if old == .online { return nil }
                    rt.state = .online
                    rt.lastOnline = now
                    rt.lastActivity = now
                    rt.errorMsg = ""
                    rt.reconnectAttempts = 0
                    return old
                })
        else { return }
        Self.log.info("\(id) -> Online (was \(old))")
        fire(id, type, old, .online)
    }

    /// The transport disconnected gracefully; auto-reconnect if enabled.
    public func setOffline(_ id: String) {
        guard
            let (old, type) = mutate(
                id,
                { rt in
                    let old = rt.state
                    if old == .offline || old == .disabled { return nil }
                    rt.state = .offline
                    rt.errorMsg = ""
                    return old
                })
        else { return }
        Self.log.info("\(id) -> Offline (was \(old))")
        fire(id, type, old, .offline)
        if config(id)?.autoReconnect == true { scheduleReconnect(id) }
    }

    /// The transport failed; auto-reconnect with backoff. Disabled by the user: an error from
    /// the link going down must not schedule a reconnect.
    public func setError(_ id: String, _ error: String) {
        guard
            let (old, type) = mutate(
                id,
                { rt in
                    let old = rt.state
                    if old == .disabled { return nil }
                    rt.state = .error
                    rt.errorMsg = error
                    return old
                })
        else { return }
        Self.log.warning("\(id) -> Error: \(error) (was \(old))")
        if old != .error { fire(id, type, old, .error) }
        if config(id)?.autoReconnect == true { scheduleReconnect(id) }
    }

    /// Record `error` as the interface's last error without changing its state. For a
    /// transport whose link state is reported separately (the Iridium modem), whose errors
    /// include refusals that are not link failures, such as an SBDIX held after a failed
    /// session: marking those ERROR stopped the delivery worker and held the whole queue
    /// (MESHSAT-1243).
    public func noteError(_ id: String, _ error: String) {
        lock.lock()
        runtimes[id]?.errorMsg = error
        lock.unlock()
        publish()
        Self.log.warning("\(id): \(error)")
    }

    public func setConnecting(_ id: String) {
        _ = mutate(id) { rt in
            if rt.state == .connecting { return nil }
            let old = rt.state
            rt.state = .connecting
            return old
        }
    }

    /// Administratively disable an interface (no auto-reconnect).
    public func disable(_ id: String) {
        cancelReconnect(id)
        let wasOnline = getState(id) == .online
        lock.lock()
        let disconnect = disconnectCallback
        lock.unlock()
        if wasOnline { disconnect?(id) }
        guard
            let (old, type) = mutate(
                id,
                { rt in
                    let old = rt.state
                    rt.state = .disabled
                    rt.reconnectAttempts = 0
                    return old
                })
        else { return }
        Self.log.info("\(id) -> Disabled (was \(old))")
        fire(id, type, old, .disabled)
    }

    /// Re-enable a disabled interface (it will attempt a connection).
    public func enable(_ id: String) {
        guard
            let (_, type) = mutate(
                id,
                { rt in
                    if rt.state != .disabled { return nil }
                    rt.state = .offline
                    rt.reconnectAttempts = 0
                    rt.errorMsg = ""
                    return .disabled
                })
        else { return }
        Self.log.info("\(id) -> Offline (re-enabled)")
        fire(id, type, .disabled, .offline)
        if config(id)?.autoReconnect == true { scheduleReconnect(id) }
    }

    public func recordActivity(_ id: String) {
        let now = clock.nowMs()
        lock.lock()
        runtimes[id]?.lastActivity = now
        lock.unlock()
    }

    /// Reconnect now, whatever the backoff said.
    public func reconnectNow(_ id: String) {
        let state = getState(id)
        if state == .disabled || state == .online { return }
        cancelReconnect(id)
        lock.lock()
        runtimes[id]?.reconnectAttempts = 0
        lock.unlock()
        scheduleReconnect(id, immediate: true)
    }

    /// Stop every reconnect and set every interface offline.
    public func stopAll() {
        lock.lock()
        let tasks = reconnectTasks.values
        reconnectTasks.removeAll()
        var fired: [InterfaceStatus] = []
        for (id, rt) in runtimes where rt.state == .online || rt.state == .connecting {
            fired.append(rt.status)
            runtimes[id]?.state = .offline
        }
        let cb = onStateChange
        lock.unlock()
        for t in tasks { t.cancel() }
        for was in fired { cb?(was.id, was.channelType, was.state, .offline) }
        publish()
    }

    // MARK: Reconnect

    /// Exponential backoff capped at `maxMs`.
    public static func calculateBackoff(attempt: Int, initialMs: Int64, maxMs: Int64) -> Int64 {
        if attempt <= 0 { return initialMs }
        var wait = initialMs
        for _ in 0..<min(attempt, 10) { wait *= 2 }
        return min(wait, maxMs)
    }

    private func scheduleReconnect(_ id: String, immediate: Bool = false) {
        cancelReconnect(id)
        guard let cfg = config(id) else { return }
        lock.lock()
        let attempts = runtimes[id]?.reconnectAttempts ?? 0
        lock.unlock()
        let backoff = immediate ? 0 : Self.calculateBackoff(attempt: attempts, initialMs: cfg.initialBackoffMs, maxMs: cfg.maxBackoffMs)
        let task = Task { [weak self] in
            guard let self else { return }
            if backoff > 0 {
                Self.log.debug("\(id) reconnect in \(backoff / 1000)s (attempt \(attempts + 1))")
                await self.clock.sleep(ms: backoff)
            }
            if Task.isCancelled || self.getState(id) == .disabled { return }
            _ = self.mutate(id) { rt in
                rt.reconnectAttempts += 1
                rt.state = .connecting
                return nil
            }
            self.publish()
            guard let cb = self.currentConnectCallback() else {
                _ = self.mutate(id) { rt in
                    rt.state = .error
                    rt.errorMsg = "no connect callback"
                    return nil
                }
                self.publish()
                return
            }
            if let error = await cb(id) {
                _ = self.mutate(id) { rt in
                    rt.state = .error
                    rt.errorMsg = error
                    return nil
                }
                self.publish()
                Self.log.warning("\(id) reconnect failed: \(error)")
                if cfg.autoReconnect && self.getState(id) != .disabled { self.scheduleReconnect(id) }
            } else {
                // Success: setOnline is called by the transport when it confirms the link.
                Self.log.debug("\(id) reconnect attempt succeeded")
            }
        }
        lock.lock()
        reconnectTasks[id] = task
        lock.unlock()
    }

    private func cancelReconnect(_ id: String) {
        lock.lock()
        let task = reconnectTasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    // MARK: Helpers

    private func currentConnectCallback() -> ConnectCallback? {
        lock.lock()
        defer { lock.unlock() }
        return connectCallback
    }

    private func config(_ id: String) -> InterfaceConfig? {
        lock.lock()
        defer { lock.unlock() }
        return runtimes[id]?.config
    }

    /// Apply `change` under the lock; it answers the previous state when a transition happened.
    private func mutate(_ id: String, _ change: (inout Runtime) -> InterfaceState?) -> (InterfaceState, String)? {
        lock.lock()
        guard var rt = runtimes[id] else {
            lock.unlock()
            return nil
        }
        let old = change(&rt)
        runtimes[id] = rt
        let type = rt.config.channelType
        lock.unlock()
        publish()
        guard let old else { return nil }
        return (old, type)
    }

    private func fire(_ id: String, _ type: String, _ old: InterfaceState, _ new: InterfaceState) {
        lock.lock()
        let cb = onStateChange
        lock.unlock()
        cb?(id, type, old, new)
    }

    private func publish() {
        lock.lock()
        let snapshot = runtimes.mapValues(\.status)
        lock.unlock()
        states.send(snapshot)
    }
}
