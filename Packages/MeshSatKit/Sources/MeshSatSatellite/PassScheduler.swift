// Mirrors satellite/PassScheduler.kt: pass-aware scheduling, adapting the signal polling to the
// predicted Iridium passes. Idle (no pass soon, poll every 2 min), PreWake (a pass within 3 min,
// every 15 s), Active (a satellite overhead, every 5 s, flush the burst queue), PostPass (2 min
// after LOS, every 30 s). Times are Unix seconds, as PassPrediction's (MESHSAT-498).
import Foundation
import Logging
import MeshSatNet

public final class PassScheduler: @unchecked Sendable {
    private static let log = Logger(label: "PassScheduler")
    public static let modeCheckIntervalMs: Int64 = 30_000
    public static let preWakeWindowSec: Double = 3 * 60
    public static let postPassWindowSec: Double = 2 * 60

    public enum PassMode: String, Sendable, Equatable {
        case idle, preWake, active, postPass
    }

    public struct TimingParams: Sendable, Equatable {
        public let signalPollIntervalMs: Int64
        public let burstFlushOnEntry: Bool
    }

    public let mode = StateBroadcast<PassMode>(.idle)
    public let nextPassAos = StateBroadcast<UnixSeconds?>(nil)
    public let nextPassLos = StateBroadcast<UnixSeconds?>(nil)

    private let passProvider: @Sendable () -> [PassPrediction]
    private let signalPoller: (@Sendable () async -> Void)?
    private let burstFlusher: (@Sendable () async -> Void)?
    private let clock: any DriverClock
    private let lock = NSLock()
    private var modeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    public init(
        passProvider: @escaping @Sendable () -> [PassPrediction], signalPoller: (@Sendable () async -> Void)? = nil,
        burstFlusher: (@Sendable () async -> Void)? = nil, clock: any DriverClock = SystemDriverClock()
    ) {
        self.passProvider = passProvider
        self.signalPoller = signalPoller
        self.burstFlusher = burstFlusher
        self.clock = clock
    }

    public static func timing(for mode: PassMode) -> TimingParams {
        switch mode {
        case .idle: TimingParams(signalPollIntervalMs: 120_000, burstFlushOnEntry: false)
        case .preWake: TimingParams(signalPollIntervalMs: 15_000, burstFlushOnEntry: false)
        case .active: TimingParams(signalPollIntervalMs: 5_000, burstFlushOnEntry: true)
        case .postPass: TimingParams(signalPollIntervalMs: 30_000, burstFlushOnEntry: true)
        }
    }

    public func start() {
        stop()
        let task = Task { [self] in
            Self.log.info("Pass scheduler started")
            while !Task.isCancelled {
                await updateMode()
                await clock.sleep(ms: Self.modeCheckIntervalMs)
            }
        }
        lock.lock()
        modeTask = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let m = modeTask
        let p = pollTask
        modeTask = nil
        pollTask = nil
        lock.unlock()
        m?.cancel()
        p?.cancel()
        mode.send(.idle)
    }

    /// The mode for `now` given `passes`: pure, so it has a test.
    public static func modeFor(passes: [PassPrediction], now: Double) -> (mode: PassMode, next: PassPrediction?) {
        if let active = passes.first(where: { $0.aos.value <= now && now <= $0.los.value }) { return (.active, active) }
        let next = passes.filter { $0.aos.value > now }.min { $0.aos.value < $1.aos.value }
        if passes.contains(where: { now > $0.los.value && now - $0.los.value < postPassWindowSec }) { return (.postPass, next) }
        if let next, next.aos.value - now < preWakeWindowSec { return (.preWake, next) }
        return (.idle, next)
    }

    /// Re-evaluate the mode once (the loop calls it every 30 s; a test calls it directly).
    public func updateMode() async {
        let now = Double(clock.nowMs()) / 1000
        let passes = passProvider()
        let (newMode, next) = Self.modeFor(passes: passes, now: now)
        nextPassAos.send(next?.aos)
        nextPassLos.send(next?.los)
        let old = mode.value
        if newMode != old {
            mode.send(newMode)
            Self.log.info("Mode transition: \(old) -> \(newMode)")
            await onModeChange(old, newMode)
        }
    }

    private func onModeChange(_ old: PassMode, _ new: PassMode) async {
        let timing = Self.timing(for: new)
        if timing.burstFlushOnEntry && old != .active && old != .postPass, let flush = burstFlusher {
            await flush()
            Self.log.info("Burst queue flushed on \(new) entry")
        }
        var task: Task<Void, Never>?
        if let poll = signalPoller {
            task = Task { [clock] in
                while !Task.isCancelled {
                    await poll()
                    await clock.sleep(ms: timing.signalPollIntervalMs)
                }
            }
        }
        swapPollTask(task)?.cancel()
    }

    /// Install the next poll loop and hand back the previous one to cancel.
    private func swapPollTask(_ next: Task<Void, Never>?) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let previous = pollTask
        pollTask = next
        return previous
    }
}
