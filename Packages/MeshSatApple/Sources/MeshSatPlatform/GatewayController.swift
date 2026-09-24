// Mirrors service/GatewayService.kt (the parts of Milestone A, MESHSAT-1319): the object that
// owns the transports and the engine for the life of the app, in the same order Android
// creates them. Android's foreground service is iOS's app process kept alive by the
// Bluetooth background mode and state restoration (BackgroundCoordinator, later).
//
// Built here: the node link (MeshtasticCentral), the node's Iridium pipe and the 9603 driver on
// it, the InterfaceManager, the Dispatcher over the delivery ledger, the mesh receive path into
// the store, MT messages, signal history, the compose paths for mesh and satellite. Not yet:
// the Hub, Reticulum, APRS, TAK, MSVQ-SC, the SMS composer lane, SOS; each keeps its Android
// shape when it lands.
import Foundation
import Logging
import MeshSatBLE
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatNet
import MeshSatSatellite
import MeshSatStore
import MeshSatWire

public final class GatewayController: @unchecked Sendable {
    static let log = Logger(label: "MeshSat")
    public static let iridiumQueued = "iridium:queued"
    public static let iridiumUnconfirmed = "iridium:unconfirmed"
    public static let iridiumDelivered = "iridium:delivered"
    public static let iridiumMinSignalBars = 1
    static let pipeClaimRetryMs: Int64 = 15_000
    static let pipeClaimFirstRetryMs: Int64 = 3_000
    static let pipeRecoveryCooldownMs: Int64 = 60_000
    static let nodeBatterySampleMs: Int64 = 60_000
    static let signalPollMs: Int64 = 60_000

    /// Android's Peers: where a sent message is filed.
    public enum Peers {
        public static let meshAll = "^all"
        public static let satellite = "satellite"
    }

    public struct NodeBatteryNow: Sendable, Equatable {
        public let nodeNum: UInt32
        public let level: Int
        public let voltage: Float
        public let hoursLeft: Double?
        public let atMs: Int64
    }

    public struct MailboxCheck: Sendable, Equatable {
        public var running = false
        public var result: IridiumATDriver.MailboxResult?
        public var finishedAt: Int64 = 0
        public init() {}
    }

    public let settings: SettingsRepository
    public let db: AppDatabase
    public let central: MeshtasticCentral
    public let driver: IridiumATDriver
    public let interfaceManager: InterfaceManager
    public let registry = ChannelRegistry()
    public let sequenceTracker = SequenceTracker()
    public let deduplicator = Deduplicator()
    public private(set) var dispatcher: Dispatcher?
    public private(set) var accessEvaluator: AccessEvaluator?
    public private(set) var ackTracker: AckTracker?
    public let creditTracker: CreditTracker
    public let location = LocationProvider()
    public private(set) var tleFetcher: TleFetcher?
    public private(set) var passScheduler: PassScheduler?
    /// The predicted passes for the phone's position, three hours back and six ahead, refreshed
    /// every five minutes while the scheduler runs (MESHSAT-498, MESHSAT-1300).
    public let passes = StateBroadcast<[PassPrediction]>([])
    static let passCacheTtlMs: Int64 = 5 * 60_000
    static let tleRefreshEveryMs: Int64 = 12 * 3_600_000

    /// The phone's own node's battery, as last reported (MESHSAT-1315).
    public let nodeBattery = StateBroadcast<NodeBatteryNow?>(nil)
    /// The last mailbox check the user asked for.
    public let mailbox = StateBroadcast<MailboxCheck>(MailboxCheck())
    /// Lets the InterfaceManager release the node's modem without changing the saved setting.
    private let iridiumWanted = StateBroadcast<Bool>(true)
    /// A message arrived: title and text, for the notification the app shows.
    public let messageNotifications = Broadcast<(title: String, text: String)>(bufferSize: 8)

    let clock: any DriverClock
    let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    var nodeBatteryStoredMs: Int64 = 0
    private var started = false

    public init(
        settings: SettingsRepository, db: AppDatabase, central: MeshtasticCentral = MeshtasticCentral(),
        clock: any DriverClock = SystemDriverClock()
    ) {
        self.settings = settings
        self.db = db
        self.central = central
        self.clock = clock
        self.driver = IridiumATDriver(clock: clock)
        self.interfaceManager = InterfaceManager(clock: clock)
        self.creditTracker = CreditTracker(store: db.iridiumCredits)
    }

    func keep(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    // MARK: Lifecycle (GatewayService.onCreate)

    public func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        // Every satellite session is kept, taken or not, for the chart's session dots (MESHSAT-1300).
        keep(
            Task { [self] in
                for await ok in driver.sessionOutcomes.subscribe() {
                    try? await db.signals.insert(SignalRecord(timestamp: clock.nowMs(), source: "gss", value: ok ? 1 : 0))
                }
            })
        // Any satellite session can bring a message in: it is stored the moment it arrives.
        keep(
            Task { [self] in
                await driver.setMtSink { [self] bytes in await storeIridiumMt(String(decoding: bytes, as: UTF8.self)) }
            })
        initInterfaceManager()
        initDispatcher()
        observeTransports()
        reconnectSavedNode()
        observeIridiumPipe()
        startSignalPolling()
        startLocationUpdates()
        initPassScheduler()
        Self.log.info("GatewayController started")
    }

    public func stop() {
        dispatcher?.stop()
        ackTracker?.stop()
        passScheduler?.stop()
        location.stop()
        interfaceManager.stopAll()
        lock.lock()
        let t = tasks
        tasks.removeAll()
        started = false
        lock.unlock()
        for task in t { task.cancel() }
        Task { await driver.detach() }
        central.disconnect()
    }

    // MARK: Actions (GatewayService.onStartCommand)

    /// Connect re-arms the auto-reconnect that Disconnect switched off (MESHSAT-1239).
    public func connectMesh(address: String) {
        interfaceManager.enable("mesh_0")
        central.connect(address: address)
        settings.setMeshtasticBleAddress(address)
    }

    /// Disconnect switches the auto-reconnect off and forgets the node.
    public func disconnectMesh() {
        interfaceManager.disable("mesh_0")
        central.disconnect()
        settings.clearMeshtasticBleAddress()
    }

    /// A text for the mesh, from the compose bar.
    public func sendMeshMessage(_ text: String, to: UInt32 = MeshtasticProtocol.broadcastNodeNum, channel: Int = 0) {
        guard central.state.value == .connected else { return }
        let outText = OutgoingText.onMesh(text)
        let proto = MeshtasticProtocol.encodeTextMessage(outText, to: to, channel: channel)
        // Writing to a node we have no name for: ask it, so the conversation gets one.
        if to != MeshtasticProtocol.broadcastNodeNum { central.askWhoIs(to) }
        central.sendToRadio(proto)
        let recipient = to == MeshtasticProtocol.broadcastNodeNum ? Peers.meshAll : MeshtasticProtocol.formatNodeId(to)
        Task { [self] in
            try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "mesh", direction: "tx", sender: "self", recipient: recipient, text: text))
        }
    }

    /// A message the user wrote for Iridium: shown in the chat at once as queued, stored in the
    /// delivery queue and retried until it goes out, whether or not the modem is there right
    /// now (MESHSAT-1243). A failed session never drops it.
    public func queueIridiumMessage(_ text: String, recipient: String) {
        Task { [self] in
            let msgId =
                (try? await db.messages.insert(
                    MessageRecord(
                        timestamp: clock.nowMs(), transport: "iridium", direction: "tx", sender: "self", recipient: recipient, text: text,
                        forwarded: true, forwardedTo: Self.iridiumQueued))) ?? 0
            let payload = encodeIridiumPayload(text)
            let queued = await dispatcher?.enqueueDirect(
                destInterface: "iridium_0", payload: payload, textPreview: text, msgRef: "msg:\(msgId)")
            if queued == nil {
                try? await db.messages.setForwardedTo(id: msgId, "iridium:failed")
                messageNotifications.send((title: "Iridium message not queued", text: "The delivery queue is not running."))
            }
        }
    }

    /// What goes into the MO buffer for `text`: the bare UTF-8 until MSVQ-SC lands (MESHSAT-1329).
    func encodeIridiumPayload(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Check the satellite mailbox on request. False when a check is already running.
    @discardableResult
    public func checkIridiumMailbox() -> Bool {
        var startIt = false
        mailbox.update { m in
            if m.running { return m }
            startIt = true
            var next = MailboxCheck()
            next.running = true
            return next
        }
        guard startIt else { return false }
        Task { [self] in
            let result = await driver.checkMailbox { [self] bytes in await storeIridiumMt(String(decoding: bytes, as: UTF8.self)) }
            Self.log.info("Iridium mailbox check: \(result)")
            var done = MailboxCheck()
            done.result = result
            done.finishedAt = clock.nowMs()
            mailbox.send(done)
        }
        return true
    }

    // MARK: InterfaceManager (GatewayService.initInterfaceManager)

    private func initInterfaceManager() {
        let mgr = interfaceManager
        mgr.register(InterfaceConfig(id: "mesh_0", channelType: "mesh", autoReconnect: true, initialBackoffMs: 5_000, maxBackoffMs: 60_000))
        mgr.register(
            InterfaceConfig(id: "iridium_0", channelType: "iridium", autoReconnect: true, initialBackoffMs: 10_000, maxBackoffMs: 120_000))
        // The SMS lane is the Messages composer (MESHSAT-1328); until it exists the interface is
        // disabled, so a rule to it holds its deliveries instead of dropping them.
        mgr.register(InterfaceConfig(id: "sms_0", channelType: "sms", autoReconnect: false, alwaysOnline: true))
        mgr.register(InterfaceConfig(id: "hub_0", channelType: "hub", autoReconnect: false))
        mgr.register(
            InterfaceConfig(id: "mqtt_0", channelType: "mqtt", autoReconnect: true, initialBackoffMs: 5_000, maxBackoffMs: 120_000))
        mgr.register(
            InterfaceConfig(id: "aprs_0", channelType: "aprs", autoReconnect: true, initialBackoffMs: 10_000, maxBackoffMs: 120_000))
        mgr.register(
            InterfaceConfig(id: "tcp_rns_0", channelType: "tcp", autoReconnect: true, initialBackoffMs: 5_000, maxBackoffMs: 60_000))

        mgr.setConnectCallback { [self] interfaceId in
            if interfaceId.hasPrefix("mesh") {
                // The address was saved on first connect; the central keeps the last one.
                central.reconnect()
                return nil  // async: setOnline comes from the state observer
            }
            if interfaceId == "iridium_0" {
                // The 9603 arrives with the MeshSat node's BLE link; this only allows taking it.
                iridiumWanted.send(true)
                // A modem still connected is simply online again: its state will not say
                // Connected a second time, so nothing else would restart the worker.
                if await driver.state == .connected { mgr.setOnline("iridium_0") }
                return nil
            }
            return "\(interfaceId) is not built yet"
        }
        mgr.setDisconnectCallback { [self] interfaceId in
            if interfaceId.hasPrefix("mesh") { central.disconnect() }
            if interfaceId == "iridium_0" { iridiumWanted.send(false) }
        }

        // BLE state drives the manager
        keep(
            Task { [self] in
                for await state in central.state.subscribe() {
                    switch state {
                    case .connected: mgr.setOnline("mesh_0")
                    case .disconnected: mgr.setOffline("mesh_0")
                    case .scanning, .connecting: mgr.setConnecting("mesh_0")
                    }
                }
            })
        keep(
            Task { [self] in
                for await state in driver.stateChanges.subscribe() {
                    switch state {
                    case .connected: mgr.setOnline("iridium_0")
                    case .disconnected: mgr.setOffline("iridium_0")
                    case .connecting: mgr.setConnecting("iridium_0")
                    }
                }
            })
        // Interfaces this phone has no hardware or configuration for are Disabled rather than
        // left at Offline (MESHSAT-1261).
        mgr.disable("sms_0")
        if !settings.get(SettingsKey.mqttEnabled) { mgr.disable("mqtt_0") }
        if !settings.get(SettingsKey.aprsEnabled) { mgr.disable("aprs_0") }
        if !settings.get(SettingsKey.hubEnabled) { mgr.disable("hub_0") }
        if !settings.get(SettingsKey.rnsTcpEnabled) { mgr.disable("tcp_rns_0") }

        keep(
            Task { [self] in
                for await err in central.errors.subscribe() where !err.isEmpty {
                    mgr.setError("mesh_0", err)
                }
            })
        // The modem's errors never change the interface state: its link state comes from the
        // driver's state above, and most of these are refusals, not link failures.
        keep(
            Task { [self] in
                for await err in driver.errors.subscribe() where !err.isEmpty {
                    mgr.noteError("iridium_0", err)
                }
            })
    }

    // MARK: Dispatcher (GatewayService.initDispatcher)

    private func initDispatcher() {
        keep(
            Task { [self] in
                do {
                    try ChannelDefaults.register(into: registry)
                    let eval = AccessEvaluator(rules: db.accessRules, groups: db.objectGroups)
                    try await eval.reloadFromDb()
                    accessEvaluator = eval
                    let failover = FailoverResolver(store: db.failoverGroups, status: interfaceManager)
                    let disp = Dispatcher(
                        store: db.deliveries, accessEvaluator: eval, failoverResolver: failover, registry: registry,
                        deliveryCallback: { [self] interfaceId, payload, textPreview, recipient, deliveryId, sourceBearer in
                            await deliverToTransport(
                                interfaceId, payload: payload, textPreview: textPreview, recipient: recipient, deliveryId: deliveryId,
                                sourceBearer: sourceBearer)
                        },
                        sequenceTracker: sequenceTracker, clock: clock)
                    interfaceManager.setStateChangeCallback { id, type, old, new in
                        disp.onInterfaceStateChange(id, channelType: type, old: old, new: new)
                    }
                    // Iridium sends (MESHSAT-1243): mark the chat message sent, or record a
                    // rule-forwarded one.
                    disp.setOnSent { [self] del in
                        guard del.channel == "iridium_0" else { return }
                        if del.msgRef.hasPrefix("msg:"), let msgId = Int64(del.msgRef.dropFirst(4)) {
                            try? await db.messages.setForwardedToUnlessDelivered(id: msgId, "iridium:sbd")
                        } else {
                            try? await db.messages.insert(
                                MessageRecord(
                                    timestamp: clock.nowMs(), transport: "iridium", direction: "tx", sender: "self",
                                    recipient: Peers.satellite,
                                    text: del.textPreview, forwarded: true, forwardedTo: "iridium:sbd"))
                        }
                    }
                    // A satellite send that reported a failure after the upload may have arrived: the
                    // chat shows "May have been sent" until a retry is confirmed.
                    disp.setOnUnconfirmed { [self] del, _ in
                        if del.channel == "iridium_0", del.msgRef.hasPrefix("msg:"), let msgId = Int64(del.msgRef.dropFirst(4)) {
                            try? await db.messages.setForwardedTo(id: msgId, Self.iridiumUnconfirmed)
                        }
                    }
                    disp.start(interfaces: [
                        "mesh_0": "mesh", "iridium_0": "iridium", "sms_0": "sms", "hub_0": "hub", "mqtt_0": "mqtt", "aprs_0": "aprs",
                    ])
                    dispatcher = disp
                    let tracker = AckTracker(store: db.deliveries, clock: clock)
                    tracker.start()
                    ackTracker = tracker
                    Self.log.info("Dispatcher initialized (\(eval.ruleCount()) access rules, ACK tracker started)")
                } catch {
                    Self.log.error("Dispatcher init failed: \(error)")
                }
            })
    }

    // Delivery callback: sends a payload to the named interface. Nil on success. Six
    // parameters, as the Dispatcher's callback and Android's deliverToTransport have.
    // swiftlint:disable:next function_parameter_count
    func deliverToTransport(
        _ interfaceId: String, payload: [UInt8], textPreview: String, recipient: String, deliveryId: Int64, sourceBearer: String
    ) async -> String? {
        if interfaceId.hasPrefix("mesh") {
            guard central.state.value == .connected else { return "mesh not connected" }
            central.sendToRadio(MeshtasticProtocol.encodeTextMessage(textPreview))
            try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "mesh", direction: "tx", sender: "self", recipient: Peers.meshAll,
                    text: textPreview,
                    forwarded: true, forwardedTo: "mesh:broadcast"))
            return nil
        }
        if interfaceId == "iridium_0" {
            guard await driver.state == .connected else { return "iridium not connected" }
            // The modem's pause after a session found no network is not this message's failure:
            // it waits without using up a try (MESHSAT-1243).
            let hold = await driver.sbdixHoldRemainingMs()
            if hold > 0 { return "\(Dispatcher.notNow)\(hold) the satellite modem pauses after a session found no network" }
            let data = payload.isEmpty ? Array(textPreview.utf8) : payload
            // One message, one frame (MESHSAT-1280).
            if !SatelliteLimits.fits(data.count) { return "\(Dispatcher.never) \(SatelliteLimits.tooLong(data.count))" }
            guard await driver.writeMoBuffer(data) else { return "Could not hand the message to the modem" }
            guard let result = await driver.sbdix() else { return "The modem gave no readable answer" }
            if !result.moSuccess {
                let why = "status \(result.moStatus), \(IridiumATDriver.moStatusText(result.moStatus)), MOMSN \(result.moMsn)"
                // The upload may have reached the gateway before the link was cut: say so, and
                // retry all the same (a duplicate costs a credit, a lost message costs more).
                return IridiumATDriver.moMaybeSent.contains(result.moStatus) ? "\(Dispatcher.unconfirmed) \(why)" : "Not sent: \(why)"
            }
            try? await creditTracker.recordMo(moMsn: result.moMsn)
            // The session's MOMSN, for the Hub's receipt (MESHSAT-1246).
            let imei = await driver.modemInfo.imei
            if deliveryId > 0 && !imei.isEmpty && result.moMsn >= 0 {
                try? await db.deliveries.setSatRef(id: deliveryId, "\(imei):\(result.moMsn)")
            }
            return nil
        }
        return "\(interfaceId) is not built yet"
    }

    // MARK: The node and its modem

    /// Reconnect to the MeshSat node chosen last (MESHSAT-1239): at start here, and after any
    /// drop through mesh_0's auto-reconnect, which uses the same address. Only the user's
    /// Disconnect forgets it.
    private func reconnectSavedNode() {
        let addr = settings.meshtasticBleAddress
        guard !addr.isEmpty else { return }
        central.rememberNode(address: addr)
        guard central.state.value == .disconnected else { return }
        Self.log.info("Reconnecting to the MeshSat node \(addr)")
        central.connect(address: addr)
    }

    /// The RockBLOCK 9603 is reached through the MeshSat node's BLE pipe (MESHSAT-1236). While a
    /// node offers it, the setting allows it and the interface is wanted, the phone subscribes,
    /// which asks the node for the modem, and runs the 9603 driver whenever STATUS says the
    /// phone owns it. Otherwise it lets go, so the node's own logic can use the modem.
    private func observeIridiumPipe() {
        // A pipe that stops taking writes never mended itself (MESHSAT-1270): drop the link and
        // let the node reconnect, which re-runs the claim and the attach below.
        keep(
            Task { [self] in
                var lastRecoveryMs: Int64 = 0
                for await _ in driver.linkFaults.subscribe() {
                    interfaceManager.noteError("iridium_0", "The phone cannot reach the node's modem")
                    await driver.detach()
                    let nowMs = clock.nowMs()
                    if nowMs - lastRecoveryMs < Self.pipeRecoveryCooldownMs {
                        Self.log.warning("Iridium: the pipe takes no writes; waiting out the reconnect cooldown")
                        continue
                    }
                    lastRecoveryMs = nowMs
                    Self.log.warning("Iridium: the pipe takes no writes; reconnecting to the node")
                    central.forceReconnect()
                }
            })
        keep(
            Task { [self] in
                var session: Task<Void, Never>?
                for await pipe in central.iridiumPipe.subscribe() {
                    session?.cancel()
                    await driver.detach()
                    guard let pipe else { continue }
                    session = Task { [self] in await runPipeSession(pipe) }
                }
                session?.cancel()
            })
    }

    /// One pipe's life: claim it until the phone holds the modem, attach the driver while it
    /// does, let go when the setting or the manager says so.
    private func runPipeSession(_ pipe: IridiumBlePipe) async {
        let enabled = settings.get(SettingsKey.iridiumNodePipeEnabled)
        if !enabled || !iridiumWanted.value {
            await pipe.release()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            // Keep at it until the phone holds the modem (MESHSAT-1239): a claim can race the
            // link's encryption or the node's config dump and go unanswered, and a node busy
            // with its own modem hands it over later. STATUS is read again in case its
            // notification was lost.
            group.addTask { [self] in
                var attempt = 0
                while !Task.isCancelled {
                    switch pipe.owner.value {
                    case .phone: break
                    case .node: pipe.refreshStatus()
                    default:
                        if !(await pipe.claim()) { Self.log.info("Iridium: no handover from the node yet; asking again") }
                    }
                    await clock.sleep(ms: attempt == 0 ? Self.pipeClaimFirstRetryMs : Self.pipeClaimRetryMs)
                    attempt += 1
                }
            }
            group.addTask { [self] in
                for await owner in pipe.owner.subscribe() {
                    if Task.isCancelled { break }
                    if owner == .phone {
                        if await driver.state == .disconnected { await driver.attach(pipe) }
                    } else {
                        await driver.detach()
                    }
                }
            }
            // The setting or the manager can withdraw the modem mid-session.
            group.addTask { [self] in
                for await wanted in iridiumWanted.subscribe() where !wanted {
                    await driver.detach()
                    await pipe.release()
                    break
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: The phone's position (GatewayService.startLocationUpdates, locationListener)

    private func startLocationUpdates() {
        keep(
            Task { [self] in
                for await fix in location.phoneLocation.subscribe() {
                    guard let fix else { continue }
                    // Stored under the special node id 0, as Android does.
                    try? await db.nodePositions.insert(
                        NodePosition(
                            timestamp: fix.timeMs, nodeId: 0, nodeName: "Phone", latitude: fix.latitude, longitude: fix.longitude,
                            altitude: Int(fix.altitude)))
                }
            })
        location.start()
    }

    // MARK: Passes (GatewayService.initPassScheduler, startTleRefresh)

    private func initPassScheduler() {
        // Offline first: the last download or the snapshot shipped in the app, never the network.
        let fetcher = TleFetcher(store: db.tleCache, http: UrlSessionTleHttp())
        tleFetcher = fetcher
        keep(
            Task { [self] in
                var lastAttemptMs: Int64 = 0
                while !Task.isCancelled {
                    let now = clock.nowMs()
                    if now - lastAttemptMs >= Self.tleRefreshEveryMs, await fetcher.isCacheStale() {
                        lastAttemptMs = now
                        _ = await fetcher.refreshFromNetwork()
                    }
                    await clock.sleep(ms: 3_600_000)
                }
            })
        let cache = PassCache()
        let scheduler = PassScheduler(
            passProvider: { [self] in cache.current(nowMs: clock.nowMs()) },
            // Gated so the 5-second poll tick does nothing when no modem is there (MESHSAT-499).
            signalPoller: { [self] in
                if await driver.state == .connected { _ = await driver.pollSignal() }
            },
            // Through the delivery queue, never straight to the modem (MESHSAT-1249): what waits
            // for the satellite goes now.
            burstFlusher: { [self] in
                if await driver.state == .connected { await dispatcher?.drainNow(channelId: "iridium_0", reason: "a pass began") }
            },
            clock: clock)
        // The predictions themselves: recomputed every five minutes while a position is known,
        // and only what has not ended yet reaches the scheduler; the chart gets three hours back.
        keep(
            Task { [self] in
                while !Task.isCancelled {
                    if let loc = location.phoneLocation.value {
                        let set = await fetcher.localTles()
                        let nowSec = Double(clock.nowMs()) / 1000
                        let observer = Observer(latDeg: loc.latitude, lonDeg: loc.longitude, altKm: loc.altitude / 1000)
                        let all = PassPredictor.predictAllPasses(
                            set.tles, observer: observer, start: UnixSeconds(nowSec - 3 * 3600), end: UnixSeconds(nowSec + 6 * 3600),
                            now: UnixSeconds(nowSec))
                        Self.log.info("Pass prediction: \(set.tles.count) TLEs (\(set.source)), \(all.count) passes")
                        cache.replace(all, atMs: clock.nowMs())
                        passes.send(all)
                    }
                    await clock.sleep(ms: Self.passCacheTtlMs)
                }
            })
        scheduler.start()
        passScheduler = scheduler
    }

    /// The cached predictions the scheduler reads: those that have not ended, from the last
    /// computation, so SGP4 does not run every 30 s (MESHSAT-498).
    private final class PassCache: @unchecked Sendable {
        private let lock = NSLock()
        private var passes: [PassPrediction] = []
        func replace(_ p: [PassPrediction], atMs: Int64) {
            lock.lock()
            passes = p
            lock.unlock()
        }
        func current(nowMs: Int64) -> [PassPrediction] {
            lock.lock()
            defer { lock.unlock() }
            let nowSec = Double(nowMs) / 1000
            return passes.filter { $0.los.value >= nowSec }
        }
    }

    // MARK: Signal history (GatewayService.startSignalPolling)

    private func startSignalPolling() {
        keep(
            Task { [self] in
                while !Task.isCancelled {
                    await clock.sleep(ms: Self.signalPollMs)
                    if Task.isCancelled { break }
                    if await driver.state == .connected {
                        let sig = await driver.pollSignal()
                        if sig >= 0 { try? await db.signals.insert(SignalRecord(timestamp: clock.nowMs(), source: "iridium", value: sig)) }
                    }
                    if central.state.value == .connected {
                        central.readRssi()
                        await clock.sleep(ms: 500)
                        let rssi = central.rssi.value
                        if rssi != 0 { try? await db.signals.insert(SignalRecord(timestamp: clock.nowMs(), source: "mesh", value: rssi)) }
                    }
                    // iOS has no public API for the cellular signal in dBm; the "cellular" series stays empty.
                    try? await db.signals.deleteBefore(clock.nowMs() - 24 * 60 * 60 * 1000)
                }
            })
    }
}
