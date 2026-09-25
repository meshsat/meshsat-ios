// Mirrors aprs/AprsBeacon.kt (MESHSAT-231, smart beaconing after hamhud's SmartBeaconing) and
// aprs/AprsMessageTracker.kt (MESHSAT-232, directed messages with ack/rej and three retries
// 30 s apart). Time is injected so the tests never wait.
import Foundation

/// A fix as the beacon needs it (Android's Location).
public struct AprsFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    /// Degrees, negative when unknown.
    public let bearing: Double
    /// Metres per second.
    public let speed: Double
    public init(latitude: Double, longitude: Double, altitude: Double = 0, bearing: Double = -1, speed: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.bearing = bearing
        self.speed = speed
    }
}

public final class AprsBeacon: @unchecked Sendable {
    public static let defaultSlowRateSec = 600
    public static let defaultFastRateSec = 90
    /// APRS courtesy: never faster than 60 s.
    public static let minBeaconIntervalSec = 60
    /// 2 m/s (about 7 km/h) is "moving".
    public static let speedThresholdMps = 2.0
    /// Corner pegging threshold.
    public static let headingChangeDeg = 30.0

    public typealias Handler =
        @Sendable (_ lat: Double, _ lon: Double, _ alt: Double, _ course: Double, _ speed: Double, _ comment: String) -> Void

    private let lock = NSLock()
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private var onBeaconValue: Handler?
    private var loop: Task<Void, Never>?
    private var lastBeaconMs: Int64 = 0
    private var lastHeading = 0.0
    private var lastFix: AprsFix?
    private var enabledValue = false
    private var slowRateSecValue = AprsBeacon.defaultSlowRateSec
    private var fastRateSecValue = AprsBeacon.defaultFastRateSec

    public init(
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledValue
    }

    public var slowRateSec: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return slowRateSecValue
        }
        set {
            lock.lock()
            slowRateSecValue = newValue
            lock.unlock()
        }
    }

    public var fastRateSec: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fastRateSecValue
        }
        set {
            lock.lock()
            fastRateSecValue = newValue
            lock.unlock()
        }
    }

    public func setOnBeacon(_ handler: Handler?) {
        lock.lock()
        onBeaconValue = handler
        lock.unlock()
    }

    /// Start the timer loop: every 10 s, a beacon when the interval for the current speed has passed.
    public func start() {
        stop()
        lock.lock()
        enabledValue = true
        lastBeaconMs = 0
        lock.unlock()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, (try? await sleep(10_000)) != nil else { return }
                checkAndBeacon()
            }
        }
        lock.lock()
        loop = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        enabledValue = false
        let l = loop
        loop = nil
        lock.unlock()
        l?.cancel()
    }

    /// Each fix; a heading change over the threshold while moving beacons at once (corner pegging).
    public func onLocationUpdate(_ fix: AprsFix) {
        lock.lock()
        lastFix = fix
        let enabled = enabledValue
        let last = lastBeaconMs
        let heading = fix.bearing
        let previous = lastHeading
        lastHeading = heading
        lock.unlock()
        guard enabled, fix.speed > Self.speedThresholdMps, last > 0 else { return }
        let delta = abs(heading - previous)
        let normalized = delta > 180 ? 360 - delta : delta
        if normalized >= Self.headingChangeDeg, (now() - last) / 1000 >= Int64(Self.minBeaconIntervalSec) { beacon(fix) }
    }

    /// Runs the check the loop runs; public so a test can drive it without the clock.
    public func checkAndBeacon() {
        lock.lock()
        let fix = lastFix
        let last = lastBeaconMs
        let interval = max((fix?.speed ?? 0) > Self.speedThresholdMps ? fastRateSecValue : slowRateSecValue, Self.minBeaconIntervalSec)
        lock.unlock()
        guard let fix else { return }
        if (now() - last) / 1000 >= Int64(interval) { beacon(fix) }
    }

    private func beacon(_ fix: AprsFix) {
        lock.lock()
        lastBeaconMs = now()
        let handler = onBeaconValue
        lock.unlock()
        handler?(fix.latitude, fix.longitude, fix.altitude, fix.bearing, fix.speed, Self.comment(for: fix))
    }

    /// "25km/h alt=15m MeshSat"
    public static func comment(for fix: AprsFix) -> String {
        var parts: [String] = []
        let kmh = fix.speed * 3.6
        if kmh > 1 { parts.append("\(Int(kmh.rounded()))km/h") }
        if fix.altitude > 0 { parts.append("alt=\(Int(fix.altitude))m") }
        parts.append("MeshSat")
        return parts.joined(separator: " ")
    }
}

public final class AprsMessageTracker: @unchecked Sendable {
    public static let maxRetries = 3
    public static let retryIntervalMs: Int64 = 30_000

    public enum DeliveryStatus: Sendable, Equatable { case pending, acked, rejected, failed }

    public struct PendingMessage: Sendable, Equatable {
        public let to: String
        public let text: String
        public let msgId: String
        public var retries = 0
        public var status = DeliveryStatus.pending
    }

    private let lock = NSLock()
    private let sleep: @Sendable (Int64) async throws -> Void
    private var nextId = 1
    private var pending: [String: PendingMessage] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var onSendValue: (@Sendable (_ to: String, _ text: String, _ msgId: String) -> Void)?
    private var onStatusChangeValue: (@Sendable (_ msgId: String, _ status: DeliveryStatus) -> Void)?

    public init(sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }) {
        self.sleep = sleep
    }

    public func setOnSend(_ cb: (@Sendable (String, String, String) -> Void)?) {
        lock.lock()
        onSendValue = cb
        lock.unlock()
    }

    public func setOnStatusChange(_ cb: (@Sendable (String, DeliveryStatus) -> Void)?) {
        lock.lock()
        onStatusChangeValue = cb
        lock.unlock()
    }

    /// Send a directed message with ack tracking; returns its id.
    @discardableResult
    public func send(to: String, text: String) -> String {
        lock.lock()
        let msgId = String(nextId)
        nextId += 1
        pending[msgId] = PendingMessage(to: to, text: text, msgId: msgId)
        let onSend = onSendValue
        lock.unlock()
        onSend?(to, text, msgId)
        let task = Task { [weak self] in
            for attempt in 0..<Self.maxRetries {
                guard (try? await self?.sleep(Self.retryIntervalMs)) != nil, let self else { return }
                guard retryIfPending(msgId, attempt: attempt + 1) else { return }
            }
            self?.failIfPending(msgId)
        }
        lock.lock()
        retryTasks[msgId] = task
        lock.unlock()
        return msgId
    }

    private func retryIfPending(_ msgId: String, attempt: Int) -> Bool {
        lock.lock()
        guard var m = pending[msgId], m.status == .pending else {
            lock.unlock()
            return false
        }
        m.retries = attempt
        pending[msgId] = m
        let onSend = onSendValue
        lock.unlock()
        onSend?(m.to, m.text, msgId)
        return true
    }

    private func failIfPending(_ msgId: String) {
        lock.lock()
        guard var m = pending[msgId], m.status == .pending else {
            lock.unlock()
            return
        }
        m.status = .failed
        pending[msgId] = m
        let cb = onStatusChangeValue
        lock.unlock()
        cb?(msgId, .failed)
    }

    private func settle(_ msgId: String, _ status: DeliveryStatus) {
        lock.lock()
        guard var m = pending[msgId] else {
            lock.unlock()
            return
        }
        m.status = status
        pending[msgId] = m
        let task = retryTasks.removeValue(forKey: msgId)
        let cb = onStatusChangeValue
        lock.unlock()
        task?.cancel()
        cb?(msgId, status)
    }

    public func handleAck(_ msgId: String) { settle(msgId, .acked) }
    public func handleRej(_ msgId: String) { settle(msgId, .rejected) }

    /// An inbound packet that is an ack or rej for one of ours: handled, true.
    public func processInbound(_ pkt: AprsPacket) -> Bool {
        guard pkt.dataType == ":" else { return false }
        let msg = pkt.message
        for (prefix, status) in [("ack", DeliveryStatus.acked), ("rej", .rejected)] where msg.hasPrefix(prefix) {
            let id = String(msg.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            lock.lock()
            let known = !id.isEmpty && pending[id] != nil
            lock.unlock()
            if known {
                settle(id, status)
                return true
            }
        }
        return false
    }

    public func getStatus(_ msgId: String) -> DeliveryStatus? {
        lock.lock()
        defer { lock.unlock() }
        return pending[msgId]?.status
    }

    public func getPending() -> [PendingMessage] {
        lock.lock()
        defer { lock.unlock() }
        return pending.values.filter { $0.status == .pending }.sorted { Int($0.msgId) ?? 0 < Int($1.msgId) ?? 0 }
    }

    public func cancelAll() {
        lock.lock()
        let tasks = Array(retryTasks.values)
        retryTasks.removeAll()
        pending.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
}
