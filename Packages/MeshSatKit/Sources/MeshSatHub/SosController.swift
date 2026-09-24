// Mirrors sos/SosController.kt (MESHSAT-1249): sends an SOS on every route the phone has and
// keeps at it until the user cancels. Every route is a delivery in the queue at priority 0: the
// satellite leg is the frame the Hub decodes into an SOS alert from any modem; the mesh leg is a
// broadcast any MeshSat kit in range relays to the Hub; each emergency contact gets an SMS (on
// iOS: a Messages composer the user sends, the delivery waits for them); and the Hub is told over
// the internet as soon as it is connected. A cancelled SOS stops everything that has not gone
// out, and every route that did carry it carries a cancellation next. A test uses the same routes
// with a text that raises no alarm anywhere. What the controller needs from the running gateway
// is behind `SosEnv`, so the whole thing runs on Linux in the tests.
import Foundation
import MeshSatEngine
import MeshSatNet
import MeshSatWire

/// What the controller needs from the running gateway (Android: SosController.Env).
public protocol SosEnv: AnyObject, Sendable {
    var dispatcher: Dispatcher? { get }
    var hubReporter: HubReporter? { get }
    /// The IMEI of the modem connected now, or else the last one this phone talked to.
    func modemImei() async -> String
    /// A mesh radio is paired, connected or not.
    func meshPaired() async -> Bool
    /// The phone's position and altitude, or nil.
    func location() -> (fix: SosMessages.Fix, altitudeM: Double)?
    /// The phone can send SMS at all (iOS: the Messages composer is available).
    func canSendSms() -> Bool
    func tak(lat: Double, lon: Double, alt: Double, reason: String)
    /// A line in the signed audit log.
    func audit(event: String, detail: String) async
}

/// The deliveries of a run (MessageDeliveryDao's by-prefix queries).
public protocol SosDeliveryQueries: Sendable {
    func getByRefPrefix(_ prefix: String) async throws -> [MessageDelivery]
    @discardableResult func cancelWaitingByRefPrefix(_ prefix: String) async throws -> Int
    /// Every change to the run's deliveries, latest list each time.
    func observeByRefPrefix(_ prefix: String) -> AsyncStream<[MessageDelivery]>
}

/// The settings the run lives in.
public protocol SosSettings: AnyObject, Sendable {
    var sosRunJson: String { get set }
    var sosName: String { get }
    var hubCallsign: String { get }
    var sosContacts: [EmergencyContact] { get }
}

public final class SosController: @unchecked Sendable {
    static let hubRetryMs: Int64 = 15_000
    /// A test that has not finished by then stops what is still waiting.
    public static let testLimitMs: Int64 = 30 * 60_000

    /// The SOS in progress, or the last one: the banner, the Home card and the result screen read it.
    public let run = StateBroadcast<SosRun?>(nil)
    /// A real SOS is on (GatewayService.noteSosActive).
    public let sosActive = StateBroadcast<Bool>(false)
    /// The notification to show: the run and its route statuses (nil clears it).
    public let notification = StateBroadcast<(run: SosRun, statuses: [SosRouteStatus])?>(nil)

    private let deliveries: any SosDeliveryQueries
    private let settings: any SosSettings
    private let env: any SosEnv
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let log: @Sendable (String) -> Void
    private let mutex = AsyncMutex()
    private let lock = NSLock()
    private var hubTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    public init(
        deliveries: any SosDeliveryQueries, settings: any SosSettings, env: any SosEnv,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.deliveries = deliveries
        self.settings = settings
        self.env = env
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    /// Pick up an SOS that was in progress when the app stopped.
    public func restore() {
        let saved = SosRun.fromJson(settings.sosRunJson)
        run.send(saved)
        sosActive.send(saved.map { $0.active && !$0.test } ?? false)
        if let saved, saved.active || needsCancelPublish(saved) { follow(saved) }
    }

    public func stop() {
        lock.lock()
        let h = hubTask
        let w = watchTask
        hubTask = nil
        watchTask = nil
        lock.unlock()
        h?.cancel()
        w?.cancel()
    }

    /// The dispatcher asks before it sends a delivery: an SOS delivery of a run that has been
    /// cancelled or replaced is never sent.
    public func mayDeliver(_ del: MessageDelivery) -> Bool {
        guard let (runId, isCancel) = SosRun.parseRef(del.msgRef) else { return true }
        if isCancel { return true }
        // Right after a restart the run may not be loaded yet: read it rather than guess.
        guard let current = run.value ?? SosRun.fromJson(settings.sosRunJson) else { return true }
        return runId == current.id && current.active
    }

    /// A delivery went out: if its SOS was cancelled meanwhile, that route gets the cancellation too.
    public func onSent(_ del: MessageDelivery) async {
        guard let (runId, isCancel) = SosRun.parseRef(del.msgRef), !isCancel else { return }
        await mutex.acquire()
        defer { mutex.release() }
        guard let r = run.value, r.id == runId, !r.test, r.cancelledAt != nil else { return }
        await enqueueCancel(r, del)
    }

    /// Start an SOS, or a test of the alarm. A real SOS replaces a test that is still running.
    public func start(test: Bool, trigger: String) async {
        await mutex.acquire()
        defer { mutex.release() }
        if let current = run.value, current.active {
            if !current.test || test {
                log("An SOS or test is already running (\(current.id)), not starting another")
                return
            }
            await finishLocked(current)
        }
        let t = now()
        let loc = env.location()
        let fix = loc?.fix
        var name = settings.sosName
        if name.isEmpty { name = settings.hubCallsign }
        let contacts = settings.sosContacts
        let imei = await env.modemImei()
        let hub = env.hubReporter
        let bridgeId = hub.map { $0.bridgeId }.flatMap { $0.isEmpty ? nil : $0 } ?? "meshsat-ios"
        let deviceId = imei.isEmpty ? bridgeId : imei
        let prefix = SosRun.refPrefix(t)
        var routes: [SosRun.Route] = []
        var skipped: [String] = []
        let meshText = test ? SosMessages.testText(name: name) : SosMessages.meshText(name: name, fix: fix, nowMs: t)
        // The Hub files the satellite frame's alert as "sos-<bearer>-<bridge>-<time>"; the internet
        // leg uses the same id, so the Hub pages once whichever way it arrives first.
        let hubAlertId = "sos-sbd-\(SosMessages.truncateUtf8(bridgeId, maxBytes: 16))-\(t / 1000)"
        if let disp = env.dispatcher {
            // Satellite
            if !imei.isEmpty {
                let ok: Int64?
                if test, let fix {
                    // The test's satellite leg is a position report: same path to the Hub's uplink
                    // decoder as the SOS frame, and it never reaches the Hub's routing engine.
                    let frame = SosMessages.positionFrame(bridgeId: bridgeId, fix: fix, altitudeM: loc?.altitudeM ?? 0, nowSec: t / 1000)
                    ok = await disp.enqueueDirect(
                        destInterface: "iridium_0", payload: frame, textPreview: "Alarm test: position report to the Hub",
                        msgRef: prefix + "sat",
                        priority: 0)
                } else if test {
                    let tt = SosMessages.testText(name: name)
                    ok = await disp.enqueueDirect(
                        destInterface: "iridium_0", payload: Array(tt.utf8), textPreview: tt, msgRef: prefix + "sat", priority: 0)
                } else {
                    let frame = SosMessages.satFrame(
                        bridgeId: bridgeId, deviceId: imei, fix: fix, message: SosMessages.frameMessage(name: name, fix: fix),
                        nowSec: t / 1000)
                    ok = await disp.enqueueDirect(
                        destInterface: "iridium_0", payload: frame, textPreview: meshText, msgRef: prefix + "sat", priority: 0)
                }
                if ok != nil {
                    routes.append(SosRun.Route(key: "sat", label: "Satellite, to the Hub"))
                } else {
                    skipped.append("Satellite: could not be queued.")
                }
            } else {
                skipped.append("Satellite: no satellite modem has been connected to this phone yet.")
            }
            // Mesh
            if await env.meshPaired() {
                let ok = await disp.enqueueDirect(
                    destInterface: "mesh_0", payload: Array(meshText.utf8), textPreview: meshText, msgRef: prefix + "mesh", priority: 0)
                if ok != nil {
                    routes.append(SosRun.Route(key: "mesh", label: "Mesh, everyone in range"))
                } else {
                    skipped.append("Mesh: could not be queued.")
                }
            } else {
                skipped.append("Mesh: no mesh radio is paired with this phone.")
            }
            // SMS to each emergency contact
            if !env.canSendSms() {
                skipped.append("SMS: this device cannot send SMS.")
            } else if contacts.isEmpty {
                skipped.append("SMS: you have no emergency contacts. Add them in Setup, Safety.")
            } else {
                let sms = test ? SosMessages.testText(name: name) : SosMessages.smsText(name: name, fix: fix, nowMs: t)
                for c in contacts {
                    let key = "sms:\(c.phone)"
                    let who = c.name.isEmpty ? c.phone : c.name
                    let ok = await disp.enqueueDirect(
                        destInterface: "sms_0", payload: Array(sms.utf8), textPreview: sms, msgRef: prefix + key, priority: 0,
                        recipient: c.phone)
                    if ok != nil {
                        routes.append(SosRun.Route(key: key, label: "SMS to \(who)"))
                    } else {
                        skipped.append("SMS to \(who): could not be queued.")
                    }
                }
                // iOS has no SMS API: each one opens the Messages composer for the person to send.
                skipped.append("SMS goes out when you tap Send in Messages, one message per contact.")
            }
        } else {
            skipped.append("The message queue is not running, so nothing could be queued. Restart the app.")
        }
        if hub == nil { skipped.append("Hub: not set up on this phone.") }
        // TAK clients on the same network see the alarm as well (MESHSAT-191).
        if !test, let fix { env.tak(lat: fix.lat, lon: fix.lon, alt: loc?.altitudeM ?? 0, reason: meshText) }
        let newRun = SosRun(
            id: t, test: test, trigger: trigger, name: name, fix: fix, routes: routes, skipped: skipped, hubWanted: hub != nil,
            deviceId: deviceId, hubAlertId: hubAlertId)
        // Route kinds only: the audit log is no place for the contacts' phone numbers.
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in routes {
            let kind = String(r.key.split(separator: ":").first ?? "")
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        let kinds = order.map { counts[$0]! > 1 ? "\($0) x\(counts[$0]!)" : $0 }.joined(separator: ", ") + (hub != nil ? ", hub" : "")
        log("\(test ? "Alarm test" : "SOS") \(newRun.id) started (\(trigger)): \(kinds); skipped \(skipped.count)")
        await env.audit(
            event: test ? "sos_test" : "sos_activated",
            detail: "trigger=\(trigger) routes=\(kinds) position=\(fix != nil ? "known" : "unknown")")
        save(newRun)
        follow(newRun)
    }

    /// Cancel the SOS, or stop the test.
    public func cancel() async {
        await mutex.acquire()
        defer { mutex.release() }
        guard let r = run.value, r.active else { return }
        try? await deliveries.cancelWaitingByRefPrefix(r.refPrefix)
        if r.test {
            await finishLocked(r)
            return
        }
        var cancelled = r
        cancelled.cancelledAt = now()
        save(cancelled)
        // A route that carried the SOS, or may be carrying it right now, is told it is over.
        for del in (try? await deliveries.getByRefPrefix(r.refPrefix)) ?? [] where ["sent", "delivered", "sending"].contains(del.status) {
            await enqueueCancel(cancelled, del)
        }
        log("SOS \(r.id) cancelled")
        await env.audit(event: "sos_cancelled", detail: "sos=\(r.id)")
        follow(cancelled)
    }

    private func finishLocked(_ r: SosRun) async {
        try? await deliveries.cancelWaitingByRefPrefix(r.refPrefix)
        var finished = r
        finished.finishedAt = now()
        save(finished)
        log("Alarm test \(r.id) finished")
    }

    private func enqueueCancel(_ r: SosRun, _ del: MessageDelivery) async {
        let route = String(del.msgRef.dropFirst(r.refPrefix.count))
        let ref = r.refPrefix + "cancel:" + route
        if let existing = try? await deliveries.getByRefPrefix(ref), !existing.isEmpty { return }
        let text = SosMessages.cancelText(name: r.name)
        _ = await env.dispatcher?.enqueueDirect(
            destInterface: del.channel, payload: Array(text.utf8), textPreview: text, msgRef: ref, priority: 0, recipient: del.recipient)
    }

    private func save(_ r: SosRun) {
        run.send(r)
        sosActive.send(r.active && !r.test)
        settings.sosRunJson = r.toJson()
    }

    private func needsCancelPublish(_ r: SosRun) -> Bool {
        !r.test && r.cancelledAt != nil && r.hubSentAt != nil && r.cancelHubSentAt == nil
    }

    /// Save a change to the current run if it is still this one (under the mutex).
    private func update(runId: Int64, _ change: (inout SosRun) -> Void) async {
        await mutex.acquire()
        defer { mutex.release() }
        guard var r = run.value, r.id == runId else { return }
        change(&r)
        save(r)
    }

    /// Keep the Hub informed and the notification current while this run needs it.
    private func follow(_ started: SosRun) {
        let hub = Task { [self] in
            while !Task.isCancelled {
                guard let r = run.value, r.id == started.id else { break }
                let reporter = env.hubReporter
                if r.hubWanted, r.hubSentAt == nil, r.active, let reporter {
                    let text = r.test ? SosMessages.testText(name: r.name) : SosMessages.meshText(name: r.name, fix: r.fix, nowMs: r.id)
                    let sent = await reporter.publishSos(
                        deviceId: r.deviceId, id: r.hubAlertId, text: text, sos: !r.test, type: r.test ? "test" : "triggered",
                        lat: r.fix?.lat,
                        lon: r.fix?.lon, asMessage: !r.test)
                    if sent { await update(runId: r.id) { $0.hubSentAt = now() } }
                }
                if needsCancelPublish(r), let reporter {
                    let sent = await reporter.publishSos(
                        deviceId: r.deviceId, id: r.hubAlertId + "-cancelled", text: SosMessages.cancelText(name: r.name), sos: false,
                        type: "cancelled", lat: r.fix?.lat, lon: r.fix?.lon)
                    if sent { await update(runId: r.id) { $0.cancelHubSentAt = now() } }
                }
                if r.test, r.active {
                    let statuses = SosProgress.routes(r, deliveries: (try? await deliveries.getByRefPrefix(r.refPrefix)) ?? [])
                    if SosProgress.allSettled(r, statuses: statuses) || now() - r.id > Self.testLimitMs {
                        await mutex.acquire()
                        if let cur = run.value, cur.id == r.id, cur.active { await finishLocked(cur) }
                        mutex.release()
                    }
                }
                guard let current = run.value else { break }
                let hubDone = !current.hubWanted || current.hubSentAt != nil || !current.active
                if !current.active, !needsCancelPublish(current), hubDone { break }
                guard (try? await sleep(Self.hubRetryMs)) != nil else { break }
            }
        }
        let watch = Task { [self] in
            for await dels in deliveries.observeByRefPrefix(started.refPrefix) {
                guard let r = run.value, r.id == started.id else { break }
                notify(r, SosProgress.routes(r, deliveries: dels))
            }
        }
        lock.lock()
        hubTask?.cancel()
        watchTask?.cancel()
        hubTask = hub
        watchTask = watch
        lock.unlock()
    }

    private func notify(_ r: SosRun, _ statuses: [SosRouteStatus]) {
        if !r.active, r.test {
            notification.send(nil)
            return
        }
        notification.send((r, statuses))
    }
}

extension SosController {
    /// The notification's title and text for a run (Android's notify).
    public static func notificationText(_ r: SosRun, statuses: [SosRouteStatus]) -> (title: String, text: String) {
        let title = r.test ? "Alarm test running" : (r.cancelledAt != nil ? "SOS cancelled" : "SOS is on")
        let text = r.cancelledAt != nil ? "Telling everyone who got it that you are safe." : SosProgress.summary(statuses)
        return (title, text)
    }
}
