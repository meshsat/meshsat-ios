// Mirrors engine/Dispatcher.kt (the Bridge's engine.Dispatcher): evaluates access rules and fans
// messages out to per-channel delivery workers over the delivery ledger. Workers poll their
// channel's pending deliveries; the InterfaceManager's state changes hold and unhold them;
// sequence numbers and ACK tracking give QoS >= 1 at-least-once delivery.
import Crypto
import Foundation
import Logging
import MeshSatNet

public final class Dispatcher: @unchecked Sendable {
    private static let log = Logger(label: "Dispatcher")

    /// A delivery callback's answer when the channel cannot take a message right now for a
    /// reason that is not the message's: this prefix, the milliseconds to wait, then a reason.
    /// The delivery waits without counting a try, and the rest of the batch waits too.
    public static let notNow = "not-now:"
    /// A callback's answer for a message this channel can never carry, however often tried.
    public static let never = "never:"
    /// A callback's answer for a send that may have arrived although it failed.
    public static let unconfirmed = "unconfirmed:"

    static let defaultMaxHops = 8
    static let defaultMaxQueueDepth = 500
    static let maxDedupEntries = 1000
    static let dedupTtlMs: Int64 = 5 * 60_000

    /// Send a message to `interfaceId`, to `recipient` when the delivery names one (empty: the
    /// interface's own destination). `deliveryId` lets the transport record what the send
    /// learned, such as the satellite session's MOMSN (MESHSAT-1246). `sourceBearer` is the
    /// interface the message arrived on, empty when the user wrote it here (MESHSAT-1274).
    /// Nil on success, an error message on failure.
    public typealias DeliveryCallback =
        @Sendable (
            _ interfaceId: String, _ payload: [UInt8], _ textPreview: String, _ recipient: String, _ deliveryId: Int64,
            _ sourceBearer: String
        ) async -> String?

    private let store: any DeliveryStore
    private let accessEvaluator: AccessEvaluator
    private let failoverResolver: FailoverResolver?
    private let registry: ChannelRegistry
    private let deliveryCallback: DeliveryCallback
    private let sequenceTracker: SequenceTracker
    private let clock: any DriverClock
    private let pollIntervalMs: Int64

    private let lock = NSLock()
    private var workers: [String: Task<Void, Never>] = [:]
    private var reapers: [Task<Void, Never>] = []
    private var maxHops = Dispatcher.defaultMaxHops
    private var maxQueueDepth = Dispatcher.defaultMaxQueueDepth
    private var dedupCache: [String: Int64] = [:]
    private var dedupOrder: [String] = []

    // Hooks, set by the gateway
    private var onSentHook: (@Sendable (MessageDelivery) async -> Void)?
    private var onUnconfirmedHook: (@Sendable (MessageDelivery, String) async -> Void)?
    private var mayDeliverHook: (@Sendable (MessageDelivery) async -> Bool)?
    private var onAuditHook:
        (@Sendable (_ event: String, _ interfaceId: String, _ deliveryId: Int64, _ ruleId: Int64?, _ detail: String) async -> Void)?

    // Loop prevention metrics
    private var hopLimitDropsCount: Int64 = 0
    private var visitedSetDropsCount: Int64 = 0
    private var selfLoopDropsCount: Int64 = 0
    private var deliveryDedupsCount: Int64 = 0

    public init(
        store: any DeliveryStore, accessEvaluator: AccessEvaluator, failoverResolver: FailoverResolver?, registry: ChannelRegistry,
        deliveryCallback: @escaping DeliveryCallback, sequenceTracker: SequenceTracker = SequenceTracker(),
        clock: any DriverClock = SystemDriverClock(), pollIntervalMs: Int64 = 2_000
    ) {
        self.store = store
        self.accessEvaluator = accessEvaluator
        self.failoverResolver = failoverResolver
        self.registry = registry
        self.deliveryCallback = deliveryCallback
        self.sequenceTracker = sequenceTracker
        self.clock = clock
        self.pollIntervalMs = pollIntervalMs
    }

    // MARK: Hooks

    /// Called after a delivery went out, e.g. to mark the chat message sent.
    public func setOnSent(_ hook: (@Sendable (MessageDelivery) async -> Void)?) {
        lock.lock()
        onSentHook = hook
        lock.unlock()
    }

    /// Called when a send may have arrived although it reported a failure (`unconfirmed`), e.g.
    /// to mark the chat message "May have been sent". The delivery is retried all the same.
    public func setOnUnconfirmed(_ hook: (@Sendable (MessageDelivery, String) async -> Void)?) {
        lock.lock()
        onUnconfirmedHook = hook
        lock.unlock()
    }

    /// Asked before each send; false stops the delivery for good (dead, "cancelled"). An SOS
    /// cancelled while one of its sends was under way must not go out on the retry (MESHSAT-1249).
    public func setMayDeliver(_ hook: (@Sendable (MessageDelivery) async -> Bool)?) {
        lock.lock()
        mayDeliverHook = hook
        lock.unlock()
    }

    /// The signed audit log (MESHSAT-1249): "deliver" when a delivery went out, "drop" when it
    /// was given up or stopped. `detail` names the kind of message, never its text or recipient.
    public func setOnAudit(
        _ hook: (@Sendable (_ event: String, _ interfaceId: String, _ deliveryId: Int64, _ ruleId: Int64?, _ detail: String) async -> Void)?
    ) {
        lock.lock()
        onAuditHook = hook
        lock.unlock()
    }

    public var hopLimitDrops: Int64 { counter { $0.hopLimitDropsCount } }
    public var visitedSetDrops: Int64 { counter { $0.visitedSetDropsCount } }
    public var selfLoopDrops: Int64 { counter { $0.selfLoopDropsCount } }
    public var deliveryDedups: Int64 { counter { $0.deliveryDedupsCount } }

    private struct Hooks {
        var onSent: (@Sendable (MessageDelivery) async -> Void)?
        var onUnconfirmed: (@Sendable (MessageDelivery, String) async -> Void)?
        var mayDeliver: (@Sendable (MessageDelivery) async -> Bool)?
        var onAudit:
            (@Sendable (_ event: String, _ interfaceId: String, _ deliveryId: Int64, _ ruleId: Int64?, _ detail: String) async -> Void)?
    }

    private func hooks() -> Hooks {
        lock.lock()
        defer { lock.unlock() }
        return Hooks(onSent: onSentHook, onUnconfirmed: onUnconfirmedHook, mayDeliver: mayDeliverHook, onAudit: onAuditHook)
    }

    private func limits() -> (hops: Int, depth: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (maxHops, maxQueueDepth)
    }

    private func counter(_ read: (Dispatcher) -> Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return read(self)
    }

    private func bump(_ write: (Dispatcher) -> Void) {
        lock.lock()
        write(self)
        lock.unlock()
    }

    private func audit(_ event: String, _ channelId: String, _ del: MessageDelivery, why: String = "") async {
        guard let hook = hooks().onAudit, let id = del.id else { return }
        var kind = String(del.msgRef.split(separator: ":", maxSplits: 1).first ?? "")
        if kind.trimmingCharacters(in: .whitespaces).isEmpty { kind = "message" }
        await hook(event, channelId, id, del.ruleId, why.isEmpty ? kind : "\(kind): \(why)")
    }

    // MARK: Queueing

    /// Queue a message the user wrote for `destInterface`, outside the routing rules: stored, so
    /// it survives a restart, and retried until it goes out, with no retry cap and no expiry
    /// (MESHSAT-1243). The delivery id, or nil if it was not stored.
    public func enqueueDirect(
        destInterface: String, payload: [UInt8], textPreview: String, msgRef: String, priority: Int = 1, recipient: String = ""
    ) async -> Int64? {
        let now = clock.nowMs()
        let delivery = MessageDelivery(
            msgRef: msgRef, channel: destInterface, status: "queued", priority: priority, payload: Data(payload),
            textPreview: String(textPreview.prefix(200)), maxRetries: 0, qosLevel: 1, createdAt: now, updatedAt: now,
            recipient: recipient)
        do {
            let id = try await store.insert(delivery)
            Self.log.info("Delivery queued directly: dest=\(destInterface) ref=\(msgRef)")
            return id
        } catch {
            Self.log.error("Failed to queue a direct delivery: \(error)")
            return nil
        }
    }

    /// Evaluate the access rules for a message arriving on an interface and create a delivery
    /// for each matched rule. Returns how many were created.
    public func dispatchAccess(sourceInterface: String, msg: RouteMessage, payload: [UInt8]) async -> Int {
        let (hops, depthLimit) = limits()
        if msg.visited.count >= hops {
            bump { $0.hopLimitDropsCount += 1 }
            Self.log.warning("Max hops exceeded (\(msg.visited.count)/\(hops)), dropping")
            return 0
        }
        let matches = accessEvaluator.evaluateIngress(sourceInterface, msg)
        if matches.isEmpty { return 0 }

        let now = clock.nowMs()
        let msgRef = "\(now)-\(DispatchTime.now().uptimeNanoseconds % 100_000)"
        var count = 0
        for match in matches {
            var destInterface = match.forwardTo
            if let resolver = failoverResolver {
                let resolved = (try? await resolver.resolve(match.forwardTo)) ?? ""
                if resolved.isEmpty {
                    Self.log.warning("Failover: no available interface for \(match.forwardTo)")
                    continue
                }
                destInterface = resolved
            }
            if destInterface == sourceInterface {
                bump { $0.selfLoopDropsCount += 1 }
                continue
            }
            if msg.visited.contains(destInterface) {
                bump { $0.visitedSetDropsCount += 1 }
                continue
            }

            let desc = registry.get(ChannelRegistry.channelType(of: destInterface))
            var maxRetries = 3
            if let desc, desc.retryConfig.enabled { maxRetries = desc.retryConfig.maxRetries }

            let preview = String(msg.text.prefix(200))
            var visitedSet: [String] = []
            for v in [sourceInterface] + msg.visited where !visitedSet.contains(v) { visitedSet.append(v) }
            let visitedJson = Self.jsonArray(visitedSet)

            // forward_options: TTL and, where the link needs an address, the recipient
            // ({"to": "+31612345678"}), so a rule to SMS can say which number.
            var ttlSeconds = 0
            var ruleRecipient = ""
            let fwdOpts = match.rule.forwardOptions
            if !fwdOpts.isEmpty && fwdOpts != "{}" {
                if let data = fwdOpts.data(using: .utf8), let opts = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    ttlSeconds = (opts["ttl_seconds"] as? NSNumber)?.intValue ?? 0
                }
                ruleRecipient = Self.recipientFromOptions(fwdOpts)
            }
            if ttlSeconds == 0, let desc, desc.defaultTtlSeconds > 0 { ttlSeconds = desc.defaultTtlSeconds }

            if isDeliveryDuplicate(destInterface, payload, now: now) {
                bump { $0.deliveryDedupsCount += 1 }
                continue
            }
            if depthLimit > 0 {
                let depth = (try? await store.queueDepth(channel: destInterface)) ?? 0
                if depth >= depthLimit {
                    Self.log.warning("Queue full for \(destInterface) (\(depth)/\(depthLimit))")
                    continue
                }
            }
            if match.rule.qosLevel == 0 { maxRetries = 0 }
            let expiresAt: Int64? = (ttlSeconds > 0 && match.rule.priority > 0) ? now + Int64(ttlSeconds) * 1000 : nil

            let delivery = MessageDelivery(
                msgRef: msgRef, ruleId: match.rule.id, channel: destInterface, status: "queued", priority: match.rule.priority,
                payload: Data(payload), textPreview: preview, maxRetries: maxRetries, visited: visitedJson, ttlSeconds: ttlSeconds,
                expiresAt: expiresAt, qosLevel: match.rule.qosLevel, createdAt: now, updatedAt: now, recipient: ruleRecipient,
                origin: msg.from)
            do {
                try await store.insert(delivery)
                count += 1
                Self.log.info("Delivery queued: rule=\(match.rule.id ?? 0) dest=\(destInterface) ref=\(msgRef)")
            } catch {
                Self.log.error("Failed to insert delivery: \(error)")
            }
        }
        return count
    }

    // MARK: Workers

    /// Start the dispatcher: per-interface workers and the background reapers.
    public func start(interfaces: [String: String]) {
        let startup = Task { [self] in
            let now = clock.nowMs()
            if let cancelled = try? await store.cancelRunaway(safetyLimit: MessageDelivery.runawaySafetyLimit, now: now), cancelled > 0 {
                Self.log.warning("Cancelled \(cancelled) runaway deliveries")
            }
            if let recovered = try? await store.recoverStale(now: now), recovered > 0 {
                Self.log.info("Recovered \(recovered) stale deliveries")
            }
        }
        for ifaceId in interfaces.keys { startWorker(ifaceId) }
        let pruner = Task { [self] in
            while !Task.isCancelled {
                await clock.sleep(ms: 2 * 60_000)
                pruneDedup()
            }
        }
        let reaper = Task { [self] in
            while !Task.isCancelled {
                await clock.sleep(ms: 60_000)
                if Task.isCancelled { break }
                if let expired = try? await store.expireDeliveries(now: clock.nowMs()), expired > 0 {
                    Self.log.info("TTL reaper: expired \(expired) deliveries")
                }
            }
        }
        lock.lock()
        reapers.append(contentsOf: [startup, pruner, reaper])
        lock.unlock()
        Self.log.info("Dispatcher started with \(interfaces.count) interface workers")
    }

    /// Start a delivery worker for an interface (e.g. when it comes online).
    public func startWorker(_ interfaceId: String) {
        lock.lock()
        if workers[interfaceId] != nil {
            lock.unlock()
            return
        }
        let task = Task { [self] in
            if let unheld = try? await store.unholdForChannel(interfaceId, now: clock.nowMs()), unheld > 0 {
                Self.log.info("Unheld \(unheld) deliveries for \(interfaceId)")
            }
            while !Task.isCancelled {
                await clock.sleep(ms: pollIntervalMs)
                if Task.isCancelled { break }
                await processBatch(interfaceId)
            }
        }
        workers[interfaceId] = task
        lock.unlock()
        Self.log.info("Worker started for \(interfaceId)")
    }

    /// Stop a worker (e.g. when the interface goes offline); its deliveries are held.
    public func stopWorker(_ interfaceId: String) {
        lock.lock()
        let task = workers.removeValue(forKey: interfaceId)
        lock.unlock()
        task?.cancel()
        Task { [self] in
            if let held = try? await store.holdForChannel(interfaceId, now: clock.nowMs()), held > 0 {
                Self.log.info("Held \(held) deliveries for \(interfaceId) (offline)")
            }
        }
    }

    public func stop() {
        lock.lock()
        let tasks = Array(workers.values) + reapers
        workers.removeAll()
        reapers.removeAll()
        lock.unlock()
        for t in tasks { t.cancel() }
    }

    /// An InterfaceManager state change: hold and unhold.
    public func onInterfaceStateChange(_ interfaceId: String, channelType: String, old: InterfaceState, new: InterfaceState) {
        if new == .online && old != .online {
            startWorker(interfaceId)
            // Attempts made while it was down only pushed the backoff out; the link being back
            // is the news they waited for.
            Task { [self] in
                if let due = try? await store.retryNowForChannel(interfaceId, now: clock.nowMs()), due > 0 {
                    Self.log.info("\(due) deliveries for \(interfaceId) are due now: it is online")
                }
            }
        } else if new != .online && old == .online {
            stopWorker(interfaceId)
        } else if new == .error && old != .online {
            Task { [self] in _ = try? await store.holdForChannel(interfaceId, now: clock.nowMs()) }
        }
    }

    /// Make every waiting retry of `channelId` due now, whatever its backoff said: the channel
    /// has just shown it can carry them (the Bridge's opportunistic drain when the modem sees a
    /// satellite). Returns the deliveries woken.
    @discardableResult
    public func drainNow(channelId: String, reason: String) async -> Int {
        let due = (try? await store.retryNowForChannel(channelId, now: clock.nowMs())) ?? 0
        if due > 0 { Self.log.info("\(due) deliveries for \(channelId) are due now: \(reason)") }
        return due
    }

    private func processBatch(_ channelId: String) async {
        let deliveries: [MessageDelivery]
        do {
            deliveries = try await store.getPending(channel: channelId, now: clock.nowMs(), limit: 10)
        } catch {
            Self.log.error("Failed to fetch pending for \(channelId): \(error)")
            return
        }
        for del in deliveries {
            // A send that has started finishes and records its outcome even when the worker is
            // stopped meanwhile: cancelled mid-send, the row stayed 'sending' until the app
            // restarted, and a satellite session that did go out would have been sent (and
            // billed) again. A detached task does not inherit the worker's cancellation.
            let goOn = await Task.detached(priority: .userInitiated) { [self] in await deliver(channelId, del) }.value
            // A channel that cannot take a message right now cannot take the next one either.
            if !goOn { break }
        }
    }

    /// Deliver one message. False when the channel said "not now" and the batch should stop.
    private func deliver(_ channelId: String, _ del: MessageDelivery) async -> Bool {
        guard let id = del.id, let fresh = try? await store.getById(id) else { return true }
        if ["sent", "dead", "cancelled", "delivered"].contains(fresh.status) { return true }
        if let mayDeliver = hooks().mayDeliver, await mayDeliver(fresh) == false {
            try? await store.setStatus(id: id, "dead", lastError: "cancelled", now: clock.nowMs())
            await audit("drop", channelId, fresh, why: "cancelled")
            Self.log.info("Delivery \(id) stopped: \(fresh.msgRef) was cancelled")
            return true
        }
        if accessEvaluator.hasEgressRules(channelId) {
            let matches = accessEvaluator.evaluateEgress(channelId, RouteMessage(text: del.textPreview))
            if matches.isEmpty {
                try? await store.setStatus(id: id, "denied", lastError: "egress rules denied", now: clock.nowMs())
                Self.log.info("Delivery \(id) denied by egress rules on \(channelId)")
                return true
            }
        }
        if del.priority > 0, let expiresAt = del.expiresAt, clock.nowMs() > expiresAt {
            try? await store.setStatus(id: id, "expired", lastError: "TTL expired before send", now: clock.nowMs())
            return true
        }

        try? await store.setStatus(id: id, "sending", lastError: "", now: clock.nowMs())
        let payload = del.payload.map { [UInt8]($0) } ?? Array(del.textPreview.utf8)
        let error = await deliveryCallback(channelId, payload, del.textPreview, del.recipient, id, Self.sourceBearerOf(del.visited))

        guard let error else {
            await handleSuccess(channelId, del)
            return true
        }
        if error.hasPrefix(Self.never) {
            // Trying again cannot help (a message too long for the link): stop here.
            let why = String(error.dropFirst(Self.never.count)).trimmingCharacters(in: .whitespaces)
            try? await store.setStatus(id: id, "dead", lastError: why, now: clock.nowMs())
            await audit("drop", channelId, del, why: String(why.prefix(80)))
            Self.log.warning("Delivery \(id) can never go by \(channelId): \(why)")
            return true
        }
        if error.hasPrefix(Self.notNow) {
            // Not this message's failure (the modem's pause after a session found no network):
            // wait it out without counting a try.
            let rest = String(error.dropFirst(Self.notNow.count))
            let waitMs = Int64(rest.split(separator: " ").first ?? "") ?? 60_000
            try? await store.deferRetry(id: id, nextRetry: clock.nowMs() + waitMs, lastError: error, now: clock.nowMs())
            Self.log.info("Delivery \(id) waits \(waitMs / 1000) s: \(channelId) cannot send now")
            return false
        }
        if error.hasPrefix(Self.unconfirmed), let hook = hooks().onUnconfirmed {
            await hook(del, error)
        }
        await handleFailure(channelId, del, error)
        return true
    }

    private func handleSuccess(_ channelId: String, _ del: MessageDelivery) async {
        guard let id = del.id else { return }
        let seqNum = sequenceTracker.nextEgressSeq(channelId)
        try? await store.setSeqNum(id: id, seqNum, now: clock.nowMs())
        try? await store.setStatus(id: id, "sent", lastError: "", now: clock.nowMs())
        await audit("deliver", channelId, del)
        if let onSent = hooks().onSent { await onSent(del) }
        // The link works right now (for a satellite, the sky is open): whatever else waits for
        // this channel goes next, oldest first, instead of at its own backoff.
        if let woke = try? await store.retryNowForChannel(channelId, now: clock.nowMs()), woke > 0 {
            Self.log.info("\(woke) more deliveries for \(channelId) are due now: a send just worked")
        }
        if del.qosLevel >= 1 {
            try? await store.setAckPending(id: id, now: clock.nowMs())
            Self.log.info("Delivery \(id) sent to \(channelId) (seq=\(seqNum), ack=pending)")
        } else {
            Self.log.info("Delivery \(id) sent to \(channelId) (seq=\(seqNum), qos=0)")
        }
    }

    private func handleFailure(_ channelId: String, _ del: MessageDelivery, _ error: String) async {
        guard let id = del.id else { return }
        if del.qosLevel == 0 {
            try? await store.setStatus(id: id, "dead", lastError: error, now: clock.nowMs())
            await audit("drop", channelId, del, why: String(error.prefix(80)))
            return
        }
        let newRetries = del.retries + 1
        if del.maxRetries > 0 && newRetries >= del.maxRetries {
            try? await store.setStatus(id: id, "dead", lastError: error, now: clock.nowMs())
            await audit("drop", channelId, del, why: String(error.prefix(80)))
            Self.log.warning("Delivery \(id) exhausted retries (\(newRetries)): \(error)")
            return
        }
        let nextRetry = calculateNextRetry(channelId, retries: newRetries, priority: del.priority, moStatus: Self.moStatusOf(error))
        try? await store.scheduleRetry(id: id, retries: newRetries, nextRetry: nextRetry, lastError: error, now: clock.nowMs())
        Self.log.warning("Delivery \(id) retry \(newRetries) scheduled for \(channelId): \(error)")
    }

    func calculateNextRetry(_ channelId: String, retries: Int, priority: Int = 1, moStatus: Int? = nil) -> Int64 {
        let config = registry.get(ChannelRegistry.channelType(of: channelId))?.retryConfig
        let initialWait = config?.initialWaitMs ?? 5_000
        let maxWait = config?.maxWaitMs ?? 5 * 60_000
        let backoffFunc = config?.backoffFunc ?? "linear"
        let now = clock.nowMs()
        if backoffFunc == "isu" {
            // An SOS (priority 0) never backs off beyond the first step.
            return Self.satelliteRetryAt(
                nowMs: now, retries: priority == 0 ? 1 : retries, moStatus: moStatus, initialWaitMs: initialWait, maxWaitMs: maxWait)
        }
        var wait: Int64
        if backoffFunc == "exponential" {
            wait = initialWait
            if retries > 1 { for _ in 0..<(retries - 1) { wait *= 2 } }
        } else {
            wait = initialWait * Int64(retries)
        }
        return now + min(wait, maxWait)
    }

    /// When to retry a satellite delivery, by the modem's +SBDIX MO status, as the Bridge's
    /// dlqBackoff does: 32 (no network service) and 36 (wait 3 minutes since the last
    /// registration): 3 minutes, every time, since the ISU allows one registration every 3
    /// minutes and a satellite crosses the sky in under 10. 35 (busy): 30 s. 17 (the gateway did
    /// not answer): 1 minute. Anything else doubles from `initialWaitMs` per retry up to `maxWaitMs`.
    public static func satelliteRetryAt(nowMs: Int64, retries: Int, moStatus: Int?, initialWaitMs: Int64, maxWaitMs: Int64) -> Int64 {
        let wait: Int64
        switch moStatus {
        case 32, 36: wait = 3 * 60_000
        case 35: wait = 30_000
        case 17: wait = 60_000
        default: wait = min(initialWaitMs * Int64(1 << min(max(retries, 0), 10)), maxWaitMs)
        }
        return nowMs + wait
    }

    /// The address a rule names for links that need one, from its forward options:
    /// `{"to": "+31612345678"}`. Empty when the rule names none, when the options are not
    /// JSON, or when the value is not a string; the delivery then falls back to the number
    /// under Setup. Read by hand, not with a JSON parser, as Android does.
    public static func recipientFromOptions(_ forwardOptions: String) -> String {
        let s = forwardOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "{}" { return "" }
        guard let re = try? NSRegularExpression(pattern: "\"to\"\\s*:\\s*\"([^\"]*)\""),
            let m = re.firstMatch(in: forwardOptions, range: NSRange(forwardOptions.startIndex..., in: forwardOptions)),
            let r = Range(m.range(at: 1), in: forwardOptions)
        else { return "" }
        return String(forwardOptions[r]).trimmingCharacters(in: .whitespaces)
    }

    /// The interface a delivery's message arrived on, from the visited list the dispatcher
    /// writes when a rule matches: the source goes in first. Empty for a message the user
    /// wrote on this phone. Anchored: the column holds a top-level array.
    public static func sourceBearerOf(_ visitedJson: String) -> String {
        if visitedJson.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        guard let re = try? NSRegularExpression(pattern: "^\\s*\\[\\s*\"([^\"]+)\""),
            let m = re.firstMatch(in: visitedJson, range: NSRange(visitedJson.startIndex..., in: visitedJson)),
            let r = Range(m.range(at: 1), in: visitedJson)
        else { return "" }
        return String(visitedJson[r])
    }

    /// The +SBDIX MO status in a satellite delivery's error ("Not sent: status 32, ..."), or nil.
    public static func moStatusOf(_ error: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "\\bstatus (\\d{1,3})\\b"),
            let m = re.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)),
            let r = Range(m.range(at: 1), in: error)
        else { return nil }
        return Int(error[r])
    }

    static func jsonArray(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings), let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    // MARK: Dedup (content hash, per destination)

    private func isDeliveryDuplicate(_ destInterface: String, _ payload: [UInt8], now: Int64) -> Bool {
        if payload.isEmpty { return false }
        var hasher = SHA256()
        hasher.update(data: Data("\(destInterface)|".utf8))
        hasher.update(data: Data(payload))
        let key = hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        defer { lock.unlock() }
        if let existing = dedupCache[key], now - existing < Self.dedupTtlMs {
            // Most recently used goes last, as Android's access-ordered LinkedHashMap.
            dedupOrder.removeAll { $0 == key }
            dedupOrder.append(key)
            return true
        }
        if dedupCache[key] == nil { dedupOrder.append(key) }
        dedupCache[key] = now
        if dedupCache.count > Self.maxDedupEntries, let oldest = dedupOrder.first {
            dedupOrder.removeFirst()
            dedupCache[oldest] = nil
        }
        return false
    }

    private func pruneDedup() {
        let now = clock.nowMs()
        lock.lock()
        dedupOrder.removeAll { key in
            guard let t = dedupCache[key], now - t > Self.dedupTtlMs else { return false }
            dedupCache[key] = nil
            return true
        }
        lock.unlock()
    }
}
