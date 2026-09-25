// Mirrors the safety and diagnostics parts of service/GatewayService.kt: the dead man's
// switch (deadman.go port), the burst queue for a satellite pass, and the release telemetry
// (initTelemetry, MESHSAT-494): crash recovery, a service-start event, the heap sampler every
// 5 minutes and the health heartbeat every minute. Android's Local REST API reads the table;
// on iOS the diagnostics screen will (MESHSAT-1321).
import Foundation
import MeshSatEngine
import MeshSatStore

/// The three, one locked value (the GatewayController body is at the lint limit).
final class SafetyParts: @unchecked Sendable {
    struct State {
        var deadMan: DeadManSwitch?
        var burst: BurstQueue?
        var telemetry: TelemetryLogger?
    }
    private let lock = NSLock()
    private var value = State()
    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func update(_ change: (inout State) -> Void) {
        lock.lock()
        change(&value)
        lock.unlock()
    }
}

extension GatewayController {
    static let burstQueueMaxSize = 10
    static let burstQueueMaxAgeMs: Int64 = 5 * 60_000
    static let heapSampleEveryMs: Int64 = 5 * 60_000
    static let healthSampleEveryMs: Int64 = 60_000

    public var deadManSwitch: DeadManSwitch? { safety.state.deadMan }
    public var telemetryLogger: TelemetryLogger? { safety.state.telemetry }

    // MARK: Dead man's switch

    /// GatewayService's DeadManSwitch: 2 h by default, disabled until the setting says so; the
    /// SOS it starts is the "checkin" trigger, and TAK gets the alarm (MESHSAT-191).
    func initDeadMan() {
        let db = self.db
        let dms = DeadManSwitch(
            timeoutSec: Int64(Int(settings.get(SettingsKey.deadmanTimeoutMin)) ?? 120) * 60,
            latestPosition: { (try? await db.nodePositions.latest()).flatMap { $0 }.map { ($0.latitude, $0.longitude) } })
        dms.setEnabled(settings.get(SettingsKey.deadmanEnabled))
        dms.setSosCallback { [weak self] lat, lon, lastSeen in
            guard let self else { return }
            Self.log.warning("Dead man's switch triggered at \(lat),\(lon) (last seen: \(lastSeen))")
            let elapsed = clock.nowMs() / 1000 - lastSeen
            await takSendDeadman(lat: lat, lon: lon, timeoutSec: Int(elapsed))
            startSos(test: false, trigger: "checkin")
        }
        dms.start()
        safety.update { $0.deadMan = dms }
    }

    /// The settings screen changed the switch: the same values the start read.
    public func applyDeadManSettings() {
        guard let dms = safety.state.deadMan else { return }
        dms.setEnabled(settings.get(SettingsKey.deadmanEnabled))
        dms.timeoutSec = Int64(Int(settings.get(SettingsKey.deadmanTimeoutMin)) ?? 120) * 60
    }

    /// User activity: a message sent, the check-in tapped.
    public func touchDeadMan() { safety.state.deadMan?.touch() }

    // MARK: Burst queue

    func initBurstQueue() {
        safety.update { $0.burst = BurstQueue(maxSize: Self.burstQueueMaxSize, maxAgeMs: Self.burstQueueMaxAgeMs) }
    }

    /// Everything queued for a burst, as one delivery on the satellite lane: through the
    /// delivery queue, never straight to the modem (MESHSAT-1249). The message count, 0 when
    /// nothing waited.
    @discardableResult
    func flushBurst() async -> Int {
        guard let bq = safety.state.burst, let disp = dispatcher else { return 0 }
        let (payload, count) = bq.flush()
        guard let payload, count > 0 else { return 0 }
        _ = await disp.enqueueDirect(
            destInterface: "iridium_0", payload: payload, textPreview: "Batch of \(count) messages", msgRef: "burst:\(clock.nowMs())")
        safety.state.telemetry?.recordEvent(tag: "BurstQueue", message: "Burst flushed", detail: ["count": .int(Int64(count))])
        return count
    }

    // MARK: Telemetry

    func initTelemetry() {
        let settings = self.settings
        let clock = self.clock
        let logger = TelemetryLogger(
            store: db.telemetry, enabled: { settings.get(SettingsKey.telemetryEnabled) }, now: { clock.nowMs() },
            heapSampler: { DeviceMetrics.heapSample() })
        safety.update { $0.telemetry = logger }
        keep(
            Task { [self] in
                // 1. The previous launch's crash first, so it comes before this run's samples.
                if let dump = CrashCapture.takePending() { await logger.recoverPendingCrash(dump) }
                // 2. The start event.
                logger.recordEvent(
                    tag: "GatewayController", message: "Gateway started (v\(appVersion))",
                    detail: [
                        "versionCode": .string(appBuild), "versionName": .string(appVersion), "deviceModel": .string(DeviceMetrics.model()),
                        "osVersion": .string(DeviceMetrics.osVersion()),
                    ])
                // 3. The heap sampler.
                keep(
                    Task { [self] in
                        while !Task.isCancelled {
                            logger.recordHeap()
                            await clock.sleep(ms: Self.heapSampleEveryMs)
                        }
                    })
                // 4. The health heartbeat.
                keep(
                    Task { [self] in
                        while !Task.isCancelled {
                            let ifaces = interfaceManager.getAllStatus()
                            let online = ifaces.filter { $0.state.isAvailable }.count
                            let mode = passScheduler.map { "\($0.mode.value)" } ?? "none"
                            logger.recordHealth(
                                message: "iface \(online)/\(ifaces.count) online, pass mode \(mode)",
                                detail: [
                                    "interfacesOnline": .int(Int64(online)), "interfacesTotal": .int(Int64(ifaces.count)),
                                    "passMode": .string(mode),
                                    "deadManTriggered": .bool(safety.state.deadMan?.isTriggered ?? false),
                                    "sosActive": .bool(sos?.run.value?.active ?? false), "foregroundService": false,
                                ])
                            await clock.sleep(ms: Self.healthSampleEveryMs)
                        }
                    })
                Self.log.info("Telemetry initialized (heap+health samplers started)")
            })
    }

    func stopSafety() {
        let parts = safety.state
        safety.update { $0 = SafetyParts.State() }
        parts.deadMan?.stop()
        Task { await parts.telemetry?.drain() }
    }

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}
