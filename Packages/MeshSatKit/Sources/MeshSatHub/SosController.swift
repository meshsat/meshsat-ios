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
    /// The Hub session the SOS uses (default: hubReporter).
    var sosHub: (any SosHubLink)? { get }
}

/// What the SOS needs of the Hub session: the HubReporter, or a test's (C10, MESHSAT-1584).
public protocol SosHubLink: AnyObject, Sendable {
    var bridgeId: String { get }
    var isConnected: Bool { get async }
    // swiftlint:disable:next function_parameter_count
    func publishSos(deviceId: String, id: String, text: String, sos: Bool, type: String, lat: Double?, lon: Double?, asMessage: Bool)
        async -> Bool
    func publishSosEvent(_ event: JSONBody) async -> Bool
}

extension HubReporter: SosHubLink {}

extension SosEnv {
    /// The Hub session the SOS uses: the reporter, unless a test gives its own.
    public var sosHub: (any SosHubLink)? { hubReporter }
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
    /// The last hub/caps the Hub sent, as it came (C10): kept, because an SOS may have to go by
    /// satellite with no Hub session at all.
    var hubCapsJson: String { get set }
    /// Earlier runs whose cancellation is still owed (C10, r16 review R4), as a JSON array of
    /// runs: a new SOS does not end the last one's obligation.
    var sosPrevRunsJson: String { get set }
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
    private var prevTask: Task<Void, Never>?
    private var prevRunning = false
    /// The most earlier runs whose cancellation is still followed.
    static let prevMax = 8
    /// Earlier runs whose cancellation is still owed (r16 review C10-R4), under the mutex: a new
    /// SOS does not end the older one's obligation, which goes on until its own ack or its day.
    private var prev: [SosRun] = []

    /// The run with id: the current one, or an earlier one still owed its cancellation (mutex).
    private func findLocked(_ id: Int64) -> SosRun? {
        if let r = run.value, r.id == id { return r }
        return prev.first { $0.id == id }
    }

    /// Changes the run with id and keeps it, current or earlier (mutex); nil when not kept.
    @discardableResult private func updateLocked(_ id: Int64, _ change: (inout SosRun) -> Void) -> SosRun? {
        if var r = run.value, r.id == id {
            change(&r)
            save(r)
            return r
        }
        guard let i = prev.firstIndex(where: { $0.id == id }) else { return nil }
        change(&prev[i])
        savePrev()
        return prev[i]
    }

    private func savePrev() { settings.sosPrevRunsJson = "[" + prev.map { $0.toJson() }.joined(separator: ",") + "]" }

    /// The run's cancellation is still owed to the Hub, the old way or under C10.
    private func cancelOwed(_ r: SosRun) -> Bool { needsCancelPublish(r) || SosV2.cancelPending(r) }

    private static func runs(fromJson s: String) -> [SosRun] {
        guard let data = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { o in
            (try? JSONSerialization.data(withJSONObject: o)).flatMap { SosRun.fromJson(String(decoding: $0, as: UTF8.self)) }
        }
    }

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
        prev = Self.runs(fromJson: settings.sosPrevRunsJson)
        if !prev.isEmpty { followPrev() }
        var saved = SosRun.fromJson(settings.sosRunJson)
        // A run kept from before C10 takes the old-format id, the same on every route (MESHSAT-1584).
        let bridge = env.sosHub?.bridgeId ?? ""
        if var r = saved, !r.test, r.sosId.isEmpty, !bridge.isEmpty {
            r.sosId = HubMsgIds.legacySosId(bridgeId: bridge, runStartMs: r.id)
            if r.bridgeId.isEmpty { r.bridgeId = bridge }
            settings.sosRunJson = r.toJson()
            saved = r
        }
        run.send(saved)
        sosActive.send(saved.map { $0.active && !$0.test } ?? false)
        if let saved, saved.active || needsCancelPublish(saved) || SosV2.cancelPending(saved) { follow(saved) }
    }

    /// The Hub's caps say sos_v2 (the last ones it sent, kept).
    private var capsV2: Bool { SosV2.capsSayV2(settings.hubCapsJson) }

    /// The Hub's ack of this phone's SOS start or cancel (sos/ack, C10): it has it. A start's ends
    /// the hub leg's repeats; a cancel's ends the cancel's and stops the satellite's 0x08 if it
    /// has not gone. An ack for another run changes nothing.
    public func onAck(_ payload: String) async {
        guard let a = SosV2.parseAck(payload) else { return }
        await mutex.acquire()
        defer { mutex.release() }
        guard let r = ([run.value].compactMap { $0 } + prev).first(where: { !$0.sosId.isEmpty && $0.sosId == a.sosId }) else {
            log("An ack for an SOS this phone no longer follows, ignored")
            return
        }
        let t = now()
        switch a.kind {
        case "start":
            // The Hub has the start of a run cancelled here: it is owed the cancel, even when the
            // cancel was made before anything said the start had left (C10-R5).
            let owe = r.cancelledAt != nil && r.cancelHubAckedAt == nil && !r.cancelGaveUp && !r.cancelV2Owed
            let next = updateLocked(r.id) {
                if $0.hubSentAt == nil { $0.hubSentAt = t }
                $0.hubV2 = true
                $0.hubState = a.state
                if owe { $0.cancelV2Owed = true }
            }
            if owe, let next {
                if next.id == run.value?.id { follow(next) } else { followPrev() }
            }
        case "cancel":
            guard r.cancelledAt != nil, r.cancelHubAckedAt == nil else { return }
            updateLocked(r.id) { $0.cancelHubAckedAt = t }
            try? await deliveries.cancelWaitingByRefPrefix(r.refPrefix + "cancel:sat")
            let before = prev.count
            prev.removeAll { $0.id == r.id && !cancelOwed($0) }
            if prev.count != before { savePrev() }
            log("SOS \(r.id) cancelled: the Hub has the cancellation")
        default: break
        }
    }

    /// del is the satellite leg of r and carried the 0x07: its cancel is the 0x08 (C10).
    private func isSatV2(_ r: SosRun, _ del: MessageDelivery) -> Bool { r.satV2 && !r.sosId.isEmpty && del.msgRef == r.refPrefix + "sat" }

    /// A start's delivery went out, or may have: sent, delivered, being sent.
    private func startWent(_ del: MessageDelivery) -> Bool { ["sent", "delivered", "sending"].contains(del.status) }

    public func stop() {
        lock.lock()
        let h = hubTask
        let w = watchTask
        let p = prevTask
        hubTask = nil
        watchTask = nil
        prevTask = nil
        lock.unlock()
        h?.cancel()
        w?.cancel()
        p?.cancel()
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
        guard let r = findLocked(runId), !r.test, r.cancelledAt != nil else { return }
        if isSatV2(r, del) {
            // The 0x07 went after the cancel: the Hub is owed the cancel under the run's id.
            if !r.cancelV2Owed, let owed = updateLocked(r.id, { $0.cancelV2Owed = true }) {
                if owed.id == run.value?.id { follow(owed) } else { followPrev() }
            }
            return
        }
        await enqueueCancel(r, del)
    }

    /// The run a new one replaces keeps its owed cancellation (C10-R4), under the mutex.
    private func keepOwedLocked() {
        guard let current = run.value, !current.test, !current.active, cancelOwed(current), !prev.contains(where: { $0.id == current.id })
        else { return }
        prev.append(current)
        if prev.count > Self.prevMax { prev.removeFirst(prev.count - Self.prevMax) }
        savePrev()
        followPrev()
        log("A new SOS starts; the last one's cancellation is still followed")
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
        keepOwedLocked()
        let t = max(now(), (prev.map { $0.id }.max() ?? 0) + 1, (run.value?.id ?? 0) + 1)
        let loc = env.location()
        let fix = loc?.fix
        var name = settings.sosName
        if name.isEmpty { name = settings.hubCallsign }
        let contacts = settings.sosContacts
        let imei = await env.modemImei()
        let hub = env.sosHub
        let bridgeId = hub.map { $0.bridgeId }.flatMap { $0.isEmpty ? nil : $0 } ?? "meshsat-ios"
        let deviceId = imei.isEmpty ? bridgeId : imei
        let prefix = SosRun.refPrefix(t)
        var routes: [SosRun.Route] = []
        var skipped: [String] = []
        let meshText = test ? SosMessages.testText(name: name) : SosMessages.meshText(name: name, fix: fix, nowMs: t)
        // Its own identity (C10): the same on every route and after a restart; the frames and the
        // Hub's event go under it while the Hub says sos_v2 (MESHSAT-1584).
        let sosId = test ? "" : HubMsgIds.newSosId(t)
        let v2 = !test && hub != nil && capsV2
        var satV2 = false
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
                } else if v2, let id = HubMsgIds.parseCanonical(sosId) {
                    let frame = SosMessages.satFrameStart(
                        bridgeId: bridgeId, deviceId: imei, fix: fix, message: SosMessages.frameMessage(name: name, fix: fix),
                        nowSec: t / 1000, sosId: id, runStartMs: t)
                    ok = await disp.enqueueDirect(
                        destInterface: "iridium_0", payload: frame, textPreview: meshText, msgRef: prefix + "sat", priority: 0)
                    satV2 = ok != nil
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
        var newRun = SosRun(
            id: t, test: test, trigger: trigger, name: name, fix: fix, routes: routes, skipped: skipped, hubWanted: hub != nil,
            deviceId: deviceId, hubAlertId: hubAlertId)
        newRun.sosId = sosId
        newRun.bridgeId = bridgeId
        newRun.satV2 = satV2
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
        // A route that carried the SOS, or may be carrying it right now, is told it is over. Under
        // C10 the satellite's is the 0x08 (the follow loop queues it, after the grace) and the
        // Hub's the v2 event, both under the run's id.
        // hubV2 is kept before the first start publish: one under way may reach the Hub (C10-R5).
        var owed = r.hubV2
        for del in (try? await deliveries.getByRefPrefix(r.refPrefix)) ?? [] where startWent(del) {
            if isSatV2(cancelled, del) { owed = true } else { await enqueueCancel(cancelled, del) }
        }
        if owed {
            cancelled.cancelV2Owed = true
            save(cancelled)
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

    /// The cancel goes the old way: the Hub had the start the old way and not its cancel yet.
    private func needsCancelPublish(_ r: SosRun) -> Bool {
        !r.test && r.cancelledAt != nil && r.hubSentAt != nil && !r.hubV2 && r.cancelHubSentAt == nil
    }

    /// Save a change to the run with runId, current or earlier (under the mutex).
    private func update(runId: Int64, _ change: (inout SosRun) -> Void) async {
        await mutex.acquire()
        defer { mutex.release() }
        updateLocked(runId, change)
    }

    /// Keep the Hub informed and the notification current while this run needs it.
    private func follow(_ started: SosRun) {
        let hub = Task { [self] in
            var startPublished = 0
            var nextStart: Int64 = 0
            var cancelPublished = 0
            var nextCancel: Int64 = 0
            while !Task.isCancelled {
                guard let r = run.value, r.id == started.id else { break }
                let reporter = env.sosHub
                let t = now()
                if r.hubWanted, r.hubSentAt == nil, r.active, let reporter, SosV2.hubLegV2(r, capsV2: capsV2) {
                    // C10: the v2 start, again and again until the Hub's ack (onAck). The attempt is
                    // kept before the publish: once it is under way the start may reach the Hub
                    // whatever the answer, so a cancel from now on owes the cancel (C10-R5).
                    var attempt = false
                    if t >= nextStart { attempt = await reporter.isConnected }
                    if attempt, !r.hubV2 { await update(runId: r.id) { $0.hubV2 = true } }
                    if attempt,
                        await reporter.publishSosEvent(
                            SosV2.startEvent(r, text: SosMessages.meshText(name: r.name, fix: r.fix, nowMs: r.id)))
                    {
                        startPublished += 1
                        nextStart = t + SosV2.repeatAfter(startPublished)
                        if r.hubPublishedAt == nil {
                            await update(runId: r.id) {
                                $0.hubPublishedAt = t
                                $0.hubV2 = true
                            }
                        }
                    }
                } else if r.hubWanted, r.hubSentAt == nil, r.active, let reporter {
                    let text = r.test ? SosMessages.testText(name: r.name) : SosMessages.meshText(name: r.name, fix: r.fix, nowMs: r.id)
                    let sent = await reporter.publishSos(
                        deviceId: r.deviceId, id: r.hubAlertId, text: text, sos: !r.test, type: r.test ? "test" : "triggered",
                        lat: r.fix?.lat,
                        lon: r.fix?.lon, asMessage: !r.test)
                    if sent { await update(runId: r.id) { $0.hubSentAt = now() } }
                }
                await followCancelOldWay(r, reporter)
                if SosV2.cancelPending(r),
                    let n = await followCancelV2(r, nowMs: t, hub: reporter, published: cancelPublished, next: nextCancel)
                {
                    cancelPublished = n.published
                    nextCancel = n.next
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
                if !current.active, !cancelOwed(current), hubDone { break }
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

    /// The old-way cancellation, once, for a start that went the old way.
    private func followCancelOldWay(_ r: SosRun, _ reporter: (any SosHubLink)?) async {
        guard needsCancelPublish(r), let reporter else { return }
        let sent = await reporter.publishSos(
            deviceId: r.deviceId, id: r.hubAlertId + "-cancelled", text: SosMessages.cancelText(name: r.name), sos: false,
            type: "cancelled", lat: r.fix?.lat, lon: r.fix?.lon, asMessage: true)
        if sent { await update(runId: r.id) { $0.cancelHubSentAt = now() } }
    }

    private func claimPrevLoop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if prevRunning { return false }
        prevRunning = true
        return true
    }

    private func releasePrevLoop() {
        lock.lock()
        prevRunning = false
        lock.unlock()
    }

    private func setPrevTask(_ t: Task<Void, Never>) {
        lock.lock()
        prevTask = t
        lock.unlock()
    }

    /// Follows the cancellations earlier runs still owe (C10-R4): one loop over all of them, each
    /// with its own repeat, until each is acked or given up; then it is no longer kept.
    private func followPrev() {
        guard claimPrevLoop() else { return }
        let task = Task { [self] in
            defer { releasePrevLoop() }
            var repeats: [Int64: (published: Int, next: Int64)] = [:]
            while !Task.isCancelled {
                await mutex.acquire()
                let runs = prev
                mutex.release()
                if runs.isEmpty { break }
                let reporter = env.sosHub
                let t = now()
                for r in runs {
                    await followCancelOldWay(r, reporter)
                    if SosV2.cancelPending(r) {
                        let st = repeats[r.id] ?? (0, 0)
                        if let n = await followCancelV2(r, nowMs: t, hub: reporter, published: st.published, next: st.next) {
                            repeats[r.id] = n
                        }
                    }
                }
                await mutex.acquire()
                let before = prev.count
                prev.removeAll { !cancelOwed($0) }
                if prev.count != before { savePrev() }
                mutex.release()
                guard (try? await sleep(Self.hubRetryMs)) != nil else { break }
            }
        }
        setPrevTask(task)
    }

    /// One round of the cancel under the run's identity (C10): after a day it is given up and the
    /// 0x08 still waiting stops; else the v2 cancel is published when its repeat is due, and the
    /// 0x08 is queued on the satellite that carried the 0x07 once the grace is over (at once with
    /// no Hub session). Answers the publish count and the next publish time when it published.
    private func followCancelV2(_ r: SosRun, nowMs t: Int64, hub: (any SosHubLink)?, published: Int, next: Int64) async
        -> (published: Int, next: Int64)?
    {
        if SosV2.cancelOver(r, nowMs: t) {
            await update(runId: r.id) { $0.cancelGaveUp = true }
            try? await deliveries.cancelWaitingByRefPrefix(r.refPrefix + "cancel:sat")
            log("SOS \(r.id) cancelled: no ack from the Hub in a day; the cancel is no longer repeated")
            return nil
        }
        var up = false
        if let hub { up = await hub.isConnected }
        var result: (published: Int, next: Int64)?
        if up, t >= next, let hub, await hub.publishSosEvent(SosV2.cancelEvent(r)) {
            result = (published + 1, t + SosV2.repeatAfter(published + 1))
            if r.cancelHubPublishedAt == nil { await update(runId: r.id) { $0.cancelHubPublishedAt = t } }
        }
        let sat = ((try? await deliveries.getByRefPrefix(r.refPrefix + "sat")) ?? []).first { $0.msgRef == r.refPrefix + "sat" }
        if SosV2.cancelFrameDue(r, nowMs: t, hubUp: up, satStartWent: sat.map(startWent) ?? false) {
            // The frame is owed until its row exists: a failed enqueue is tried again next round,
            // and a row already under its reference (a crash before the run was kept) counts, so
            // the satellite never gets two (C10-R3).
            await mutex.acquire()
            if let cur = findLocked(r.id), !cur.cancelFrameDone, let id = HubMsgIds.parseCanonical(cur.sosId) {
                let ref = cur.refPrefix + "cancel:sat"
                var queued = ((try? await deliveries.getByRefPrefix(ref)) ?? []).contains { $0.msgRef == ref }
                if !queued {
                    let bridge = cur.bridgeId.isEmpty ? (hub?.bridgeId ?? "") : cur.bridgeId
                    let frame = SosMessages.cancelFrame(
                        bridgeId: bridge, sosId: id, runStartMs: cur.id, nowSec: (cur.cancelledAt ?? t) / 1000)
                    let text = SosMessages.cancelText(name: cur.name)
                    queued =
                        await env.dispatcher?.enqueueDirect(
                            destInterface: "iridium_0", payload: frame, textPreview: text, msgRef: ref, priority: 0) != nil
                }
                if queued {
                    updateLocked(cur.id) { $0.cancelFrameDone = true }
                    log("SOS \(cur.id) cancelled: the cancel frame is queued on the satellite")
                } else {
                    log("SOS \(cur.id) cancelled: the cancel frame could not be queued; tried again")
                }
            }
            mutex.release()
        }
        return result
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
