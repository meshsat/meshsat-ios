// Mirrors engine/AckTracker.kt: pending ACKs and their timeouts, for QoS >= 1 deliveries. After
// a send the delivery is ack_status 'pending'; the checker marks timed-out ones 'timeout'; an
// incoming ACK is correlated by (channel, seq_num) and promotes the delivery to 'delivered'.
import Foundation
import Logging
import MeshSatNet

public final class AckTracker: @unchecked Sendable {
    private static let log = Logger(label: "AckTracker")
    public static let checkIntervalMs: Int64 = 30_000
    public static let defaultTimeoutMs: Int64 = 30_000
    public static let satelliteTimeoutMs: Int64 = 2 * 60_000
    /// The channels the checker sweeps; Android lists the three it has.
    public static let channels = ["mesh_0", "iridium_0", "sms_0"]

    private let store: any DeliveryStore
    private let clock: any DriverClock
    private let defaultTimeoutMs: Int64
    private let lock = NSLock()
    private var checker: Task<Void, Never>?
    private var channelTimeouts: [String: Int64] = [:]

    public init(
        store: any DeliveryStore, clock: any DriverClock = SystemDriverClock(), defaultTimeoutMs: Int64 = AckTracker.defaultTimeoutMs
    ) {
        self.store = store
        self.clock = clock
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    /// A custom ACK timeout for a channel type ("iridium").
    public func setChannelTimeout(_ channelType: String, ms: Int64) {
        lock.lock()
        channelTimeouts[channelType] = ms
        lock.unlock()
    }

    public func start() {
        stop()
        let task = Task { [self] in
            while !Task.isCancelled {
                await clock.sleep(ms: Self.checkIntervalMs)
                if Task.isCancelled { break }
                await checkTimeouts()
            }
        }
        lock.lock()
        checker = task
        lock.unlock()
        Self.log.info("ACK tracker started (check interval=\(Self.checkIntervalMs / 1000)s)")
    }

    public func stop() {
        lock.lock()
        let task = checker
        checker = nil
        lock.unlock()
        task?.cancel()
    }

    /// An ACK (or NACK) for (channel, seqNum). True when it matched a pending delivery.
    public func processAck(channel: String, seqNum: Int64, positive: Bool = true) async -> Bool {
        guard let delivery = try? await store.getByChannelAndSeq(channel: channel, seqNum: seqNum), let id = delivery.id else {
            return false
        }
        if delivery.ackStatus != "pending" { return false }
        let now = clock.nowMs()
        if positive {
            try? await store.setAcked(id: id, now: now)
            Self.log.info("Delivery \(id) ACKed -> delivered (channel=\(channel) seq=\(seqNum))")
        } else {
            try? await store.setNacked(id: id, now: now)
            Self.log.warning("Delivery \(id) NACKed (channel=\(channel) seq=\(seqNum))")
        }
        return true
    }

    public func checkTimeouts() async {
        for channel in Self.channels {
            let timeout = timeoutMs(for: channel)
            let now = clock.nowMs()
            let timedOut = (try? await store.timeoutPendingAcks(cutoff: now - timeout, now: now)) ?? 0
            if timedOut > 0 { Self.log.warning("\(channel): \(timedOut) ACKs timed out (timeout=\(timeout / 1000)s)") }
        }
    }

    func timeoutMs(for channel: String) -> Int64 {
        let type = ChannelRegistry.channelType(of: channel)
        lock.lock()
        defer { lock.unlock() }
        if let custom = channelTimeouts[type] { return custom }
        return type == "iridium" ? Self.satelliteTimeoutMs : defaultTimeoutMs
    }
}
