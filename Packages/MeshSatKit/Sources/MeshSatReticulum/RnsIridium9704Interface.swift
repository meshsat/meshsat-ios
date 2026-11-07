// Mirrors reticulum/RnsIridium9704Interface.kt: Reticulum over Iridium IMT, the RockBLOCK 9704 behind
// the node's pipe, IMT topic 244 (MESHSAT-272, MESHSAT-1553 P6). Every packet goes out as "RNSI" + 0x01 +
// the raw packet, CrossTalk's framing, so a Reticulum packet and a plain satellite text never get
// confused on the same modem; on receive only a framed message whose remainder parses as a packet is
// one, everything else stays a text for the satellite conversation.
//
// Packets go to the modem one at a time, in the order they were handed over, and a failed MO is
// retried before the next packet goes: a Reticulum link sends its RTT packet and the first message
// back to back, and the far end drops a message that overtakes the RTT packet (the Bridge's
// sat_interface.go). The node never waits for an MO: send() queues and returns. The driver's single MT
// sink stays with the controller, which hands framed payloads to `deliverMt`.
import Foundation
import MeshSatMeshtastic
import MeshSatNet

public final class RnsIridium9704Interface: RnsInterface, @unchecked Sendable {
    public static let defaultRetryBackoffMs: [Int64] = [5_000, 15_000, 30_000, 60_000, 120_000]
    public static let moAcknowledged = "mo_ack_received"

    public let interfaceId: String
    public let name = "Iridium 9704 IMT"
    public let mtu = Iridium9704Driver.imtMaxSize
    public let costCents = 5
    public let latencyMs = 60_000
    public let isBidirectional = true
    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    /// The send queue's counters.
    public struct QueueStats: Sendable, Equatable {
        public var queued: Int64 = 0
        public var sent: Int64 = 0
        public var retried: Int64 = 0
        public var dropped: Int64 = 0
        public var waiting = 0
        public init() {}
    }

    private struct Out: Sendable {
        let wire: [UInt8]
        let queuedAtMs: Int64
    }

    private let driver: Iridium9704Driver
    private let clock: any DriverClock
    private let queueSize: Int
    /// A packet not sent by then is dropped.
    private let maxAgeMs: Int64
    /// Waits between attempts; the last one repeats.
    private let retryBackoffMs: [Int64]
    private let log: @Sendable (String) -> Void
    private let dedup = ImtDedup()
    private let lock = NSLock()
    private var ready = false
    private var receiveCallback: RnsReceiveCallback?
    private var stats = QueueStats()
    private var queue: AsyncStream<Out>.Continuation?
    private var sender: Task<Void, Never>?
    private var stateWatch: Task<Void, Never>?

    public init(
        driver: Iridium9704Driver, interfaceId: String = "iridium9704_0", queueSize: Int = 64, maxAgeMs: Int64 = 15 * 60_000,
        retryBackoffMs: [Int64] = RnsIridium9704Interface.defaultRetryBackoffMs, clock: any DriverClock = SystemDriverClock(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.driver = driver
        self.interfaceId = interfaceId
        self.queueSize = queueSize
        self.maxAgeMs = maxAgeMs
        self.retryBackoffMs = retryBackoffMs.isEmpty ? Self.defaultRetryBackoffMs : retryBackoffMs
        self.clock = clock
        self.log = log
    }

    public func queueStats() -> QueueStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    /// Follows the driver's state; the modem's own lifecycle is the controller's.
    public func start() async {
        let watch = Task { [weak self, driver] in
            for await state in driver.stateChanges.subscribe() {
                guard let self else { return }
                self.setReady(state == .ready)
            }
        }
        installWatch(watch)
    }

    public func stop() async {
        let t = takeDown()
        t.watch?.cancel()
        t.queue?.finish()
        t.sender?.cancel()
    }

    // The lock is taken in synchronous helpers: Swift 6 rejects lock()/unlock() straight inside an async function.

    private struct Teardown {
        let watch: Task<Void, Never>?
        let queue: AsyncStream<Out>.Continuation?
        let sender: Task<Void, Never>?
    }

    private func takeDown() -> Teardown {
        lock.lock()
        defer { lock.unlock() }
        let t = Teardown(watch: stateWatch, queue: queue, sender: sender)
        stateWatch = nil
        queue = nil
        sender = nil
        return t
    }

    private func setReady(_ r: Bool) {
        lock.lock()
        ready = r
        lock.unlock()
    }

    private func installWatch(_ t: Task<Void, Never>) {
        lock.lock()
        stateWatch?.cancel()
        stateWatch = t
        lock.unlock()
    }

    private func bump(_ f: (inout QueueStats) -> Void) {
        lock.lock()
        f(&stats)
        lock.unlock()
    }

    /// Queues a packet for the modem; nil means queued, not sent.
    public func send(_ packet: [UInt8]) async -> String? {
        let wire = RnsImtFraming.encode(packet)
        guard wire.count <= mtu else { return "packet exceeds IMT MTU" }
        let q = senderQueue()
        switch q.yield(Out(wire: wire, queuedAtMs: clock.nowMs())) {
        case .enqueued:
            bump {
                $0.queued += 1
                $0.waiting += 1
            }
            return nil
        default:
            bump { $0.dropped += 1 }
            return "9704 send queue full (\(queueSize))"
        }
    }

    private func senderQueue() -> AsyncStream<Out>.Continuation {
        lock.lock()
        defer { lock.unlock() }
        if let q = queue { return q }
        var continuation: AsyncStream<Out>.Continuation!
        let stream = AsyncStream<Out>(bufferingPolicy: .bufferingOldest(queueSize)) { continuation = $0 }
        let q = continuation!
        queue = q
        sender = Task { [weak self] in
            for await out in stream {
                guard let self else { return }
                self.bump { $0.waiting -= 1 }
                await self.sendOne(out)
            }
        }
        return q
    }

    /// One packet until it is sent or too old; the packets behind it wait, order matters more than latency.
    private func sendOne(_ out: Out) async {
        var attempt = 0
        while !Task.isCancelled {
            let age = clock.nowMs() - out.queuedAtMs
            if age > maxAgeMs {
                bump { $0.dropped += 1 }
                log("RNS packet dropped, not sent in \(age / 1000) s after \(attempt) attempts")
                return
            }
            if isOnline {
                let status = await driver.sendMessageBlocking(out.wire, topicId: Iridium9704Driver.rawTopic)
                if status == Self.moAcknowledged {
                    bump { $0.sent += 1 }
                    log("RNS packet sent over IMT: \(out.wire.count) B, attempt \(attempt + 1)")
                    return
                }
                log("IMT MO failed (\(status ?? "no answer")), attempt \(attempt + 1)")
            } else {
                log("9704 not ready, RNS packet waits (attempt \(attempt + 1))")
            }
            bump { $0.retried += 1 }
            let wait = retryBackoffMs[min(attempt, retryBackoffMs.count - 1)]
            attempt += 1
            await clock.sleep(ms: wait)
        }
    }

    /// A message the 9704 brought in: true when it was a framed Reticulum packet (delivered to the node, or a
    /// repeat dropped), false when it is a text for the plain satellite conversation.
    @discardableResult
    public func deliverMt(_ mt: [UInt8]) -> Bool {
        guard let packet = RnsImtFraming.decode(mt) else { return false }
        if dedup.seen(mt, nowMs: clock.nowMs()) {
            log("repeated IMT frame dropped")
            return true
        }
        log("RNS packet received over IMT: \(packet.count) B")
        lock.lock()
        let cb = receiveCallback
        lock.unlock()
        cb?(interfaceId, packet)
        return true
    }
}
