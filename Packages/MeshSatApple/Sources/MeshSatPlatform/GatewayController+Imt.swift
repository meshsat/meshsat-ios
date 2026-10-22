// The node's RockBLOCK 9704, GatewayService's 9704 half (MESHSAT-1507, MESHSAT-1623; here
// MESHSAT-1513 and MESHSAT-1624). The node says it carries a 9704 with STATUS flag bit 4, or the
// "Modem on the node" setting says so; the phone then runs Iridium9704Driver over the node's pipe
// instead of the 9603 driver, parks iridium_0 (its 9603 path), and sends iridium_0's messages over
// IMT, through the kits' encrypted satellite chain when the setting asks for it. What comes in is
// read with the chain and never shown as a guess.
//
// iOS has no iridium9704_0 interface (Android's is for a 9704 on an HC-05, which needs Bluetooth
// Classic): the 9704 behind the node is the satellite link iridium_0 already names.
import Foundation
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatNet
import MeshSatStore
import MeshSatWire

/// The 9704 driver and what the gateway keeps about it, readable without awaiting the driver:
/// the Hub's birth is built synchronously.
final class ImtParts: @unchecked Sendable {
    let driver: Iridium9704Driver
    private let lock = NSLock()
    private var parkedValue = false
    private var imeiValue = ""

    init(clock: any DriverClock) {
        driver = Iridium9704Driver(clock: clock)
    }

    /// True while iridium_0 is parked for the 9704: its messages go out over IMT.
    var parked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return parkedValue
    }

    /// Sets the flag; true when it changed.
    func setParked(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if parkedValue == value { return false }
        parkedValue = value
        return true
    }

    /// The 9704's IMEI as last read, kept after a detach as Android's modemInfo is.
    var imei: String {
        lock.lock()
        defer { lock.unlock() }
        return imeiValue
    }

    func setImei(_ value: String) {
        lock.lock()
        imeiValue = value
        lock.unlock()
    }

    /// The driver's state as last published: disconnected until it first changes.
    var state: Iridium9704Driver.State { driver.stateChanges.value ?? .disconnected }

    /// The last signal reading, 0 before the first.
    var signal: Int { driver.signalReadings.value ?? 0 }
}

extension GatewayController {
    /// After a failed 9704 init over the pipe: the first retry, and the longest wait between them.
    static let pipe9704RetryMinMs: Int64 = 15_000
    static let pipe9704RetryMaxMs: Int64 = 120_000

    /// The 9704 driver, for the screens.
    public var imtDriver: Iridium9704Driver { imt.driver }

    /// The pipe is transparent, so the node says what it carries with STATUS flag bit 4 (set: a
    /// 9704 speaking JSPR); the "Modem on the node" setting ("auto", "9603", "9704") can override
    /// it, and an older node without the bit is a 9603 (MESHSAT-1507).
    public static func nodeCarries9704(setting: String, status: IridiumPipeContract.Status?) -> Bool {
        switch setting {
        case "9704": true
        case "9603": false
        default: status?.flags?.contains(.modemIsJspr) == true
        }
    }

    func nodeCarries9704(_ pipe: IridiumBlePipe) -> Bool {
        Self.nodeCarries9704(setting: settings.get(SettingsKey.nodeModem), status: pipe.status.value)
    }

    // MARK: State, signal, errors and what comes in

    func initImt() {
        let imtDriver = imt.driver
        keep(
            Task { [self] in
                await imtDriver.setMtSink { [self] payload in await storeIridium9704Mt(payload) }
            })
        keep(
            Task { [self] in
                for await state in imtDriver.stateChanges.subscribe() where state == .ready {
                    let imei = await imtDriver.modemInfo.imei
                    imt.setImei(imei)
                    // Messages for the satellite wait on iridium_0; the node's 9704 carries them.
                    if imt.parked { await wakeSatelliteQueueFor9704("the node's 9704 is up") }
                }
            })
        // The node's 9704 sees a satellite: what waits for the satellite goes now, as the 9603
        // path drains on a bar (MESHSAT-1249). A wake-up, never a gate: a send at 0 bars runs.
        keep(
            Task { [self] in
                for await bars in imtDriver.signalReadings.subscribe() where bars >= Self.iridiumMinSignalBars {
                    if imt.parked, await imtDriver.state == .ready {
                        await wakeSatelliteQueueFor9704("the node's 9704 sees a satellite (\(bars)/5)")
                    }
                }
            })
        // A message the modem refused or cancelled is that message's failure, not the link's
        // (MESHSAT-1243): noted on iridium_0, whose messages the 9704 carries, never a state change.
        keep(
            Task { [self] in
                for await err in imtDriver.errors.subscribe() where !err.isEmpty {
                    Self.log.warning("9704: \(err)")
                    if imt.parked { interfaceManager.noteError("iridium_0", err) }
                }
            })
    }

    /// iridium_0 is parked (disabled) while the 9704 holds the pipe, so its worker is started here,
    /// and what waits is made due now (Android's wakeSatelliteQueueFor9704).
    func wakeSatelliteQueueFor9704(_ reason: String) async {
        guard let disp = dispatcher else { return }
        disp.startWorker("iridium_0")
        await disp.drainNow(channelId: "iridium_0", reason: reason)
    }

    /// A message the 9704 brought in (GatewayService's receivedMessages collector). A kit's
    /// encrypted chain opens with the "iridium:shared" key, asked for only when byte 0 is the
    /// version byte, on the chain this phone is set to first and then the other (r33 review
    /// R33-R2); one that does not open is kept as it came, marked encrypted, and never forwarded.
    func storeIridium9704Mt(_ payload: [UInt8]) async {
        var imei = await imt.driver.modemInfo.imei
        if imei.isEmpty { imei = "9704" }
        if deduplicator.isDuplicateKey("iridium9704:" + Deduplicator.stableKey(Hex.encode(payload))) { return }
        var key: String?
        if payload.first == SatelliteChain.protocolVersion { key = await satelliteChainKey() }
        let text: String
        let sealed: Bool
        var opened = true
        let preferred = SatelliteChain.chainOf(settings.get(SettingsKey.satelliteChain)) ?? .h
        switch SatelliteChain.readMt(payload, keyHex: key, preferred: preferred) {
        case .text(let t, sealed: let s, _):
            text = t
            sealed = s
        case .unopened(let reason):
            Self.log.warning("Iridium 9704: an encrypted message from \(imei) did not open: \(reason)")
            text = "[Encrypted satellite message, cannot open: \(reason)]"
            sealed = true
            opened = false
        }
        try? await db.messages.insert(
            MessageRecord(
                timestamp: clock.nowMs(), transport: "iridium9704", direction: "rx", sender: imei, text: text,
                rawText: sealed ? Base64Std.encode(payload) : "", encrypted: sealed))
        messageNotifications.send((title: "Iridium 9704: \(imei)", text: text))
        interfaceManager.recordActivity("iridium_0")
        guard opened else { return }
        await evaluateAndForward(sourceInterface: "iridium_0", text: text, sender: imei)
    }

    // MARK: The node's pipe

    /// The node's modem for this phone, or not (runPipeSession's owner observer, as Android's
    /// pipe observer): the 9704 driver when the node carries a 9704, else the 9603's, with
    /// iridium_0 parked or unparked to match.
    func takeModem(_ pipe: IridiumBlePipe, owner: IridiumPipeContract.Owner?) async {
        guard owner == .phone else {
            await driver.detach()
            await imt.driver.detach()
            return
        }
        let use9704 = nodeCarries9704(pipe)
        let modem = use9704 ? "9704" : "9603"
        let flag = pipe.status.value?.flags?.contains(.modemIsJspr) == true ? "9704" : "none"
        Self.log.info("Iridium: the node carries a \(modem) (setting \(settings.get(SettingsKey.nodeModem)), node's JSPR flag \(flag))")
        if use9704 {
            await driver.detach()
            parkIridium0ForImt()
            _ = await imt.driver.attachIfIdle(pipe)
        } else {
            await imt.driver.detach()
            unparkIridium0()
            if await driver.state == .disconnected { await driver.attach(pipe) }
        }
    }

    /// The modem setting changed: the right driver takes the pipe (Android restarts its pipe
    /// observer on the setting).
    func followNodeModemSetting(_ pipe: IridiumBlePipe) async {
        for await key in settings.changes.subscribe() where key == SettingsKey.nodeModem.key {
            await takeModem(pipe, owner: pipe.owner.value)
        }
    }

    /// The 9603 interface would otherwise wait on a modem that never answers AT: it is parked
    /// while the 9704 holds the pipe, and its messages go out over IMT (iridium0ParkedForImt).
    private func parkIridium0ForImt() {
        guard imt.setParked(true) else { return }
        // Offline first: disable() calls the disconnect callback for an online interface, which
        // would hand the node its modem back.
        interfaceManager.setOffline("iridium_0")
        interfaceManager.disable("iridium_0")
    }

    private func unparkIridium0() {
        guard imt.setParked(false) else { return }
        interfaceManager.enable("iridium_0")
    }

    /// The node discards the phone's bytes until its modem has started, 60 s after the node boots
    /// or switches the supply on, so the first 9704 init after a reconnect can fail with the modem
    /// healthy. Nothing else tries again over the pipe: 15 s after a failure, doubling to 2 min,
    /// while this phone holds the modem (MESHSAT-1507).
    func retry9704Init(_ pipe: IridiumBlePipe) async {
        var waitMs = Self.pipe9704RetryMinMs
        while !Task.isCancelled {
            await clock.sleep(ms: waitMs)
            if Task.isCancelled { break }
            guard pipe.owner.value == .phone, nodeCarries9704(pipe) else {
                waitMs = Self.pipe9704RetryMinMs
                continue
            }
            switch await imt.driver.state {
            case .ready:
                waitMs = Self.pipe9704RetryMinMs
            case .disconnected:
                if await imt.driver.attachIfIdle(pipe) {
                    Self.log.info("Iridium: the 9704 did not answer over the node's pipe; trying its init again")
                    waitMs = min(waitMs * 2, Self.pipe9704RetryMaxMs)
                }
            default:
                break
            }
        }
    }

    // MARK: Sending

    /// One message out through the node's 9704, nil when the satellite acknowledged it
    /// (GatewayService.sendVia9704). The driver cancels a send that sees no satellite before it
    /// answers, so a retry never leaves a second copy in the modem; a cancel the modem never
    /// settled is unconfirmed (MESHSAT-1507). Up to 100 KB in one message, nothing cut into parts:
    /// the 9603's 340-byte limit does not apply, and the chain refuses what would not fit.
    func sendVia9704(payload: [UInt8], textPreview: String, deliveryId: Int64) async -> String? {
        let imtDriver = imt.driver
        guard await imtDriver.state == .ready else { return "9704 not ready" }
        let text = payload.isEmpty ? Array(textPreview.utf8) : payload
        var data = text
        // The kits' encrypted chain when it is set (MESHSAT-1623), the H chain or the legacy one
        // they ran before it (the agreed rollback, r33 review R33-R2), read at send time. Android
        // holds the message when its setting cannot be read; a UserDefaults read cannot fail. A
        // message that cannot be sealed is never sent as plaintext instead.
        if let chain = SatelliteChain.chainOf(settings.get(SettingsKey.satelliteChain)) {
            // An SOS or a burst goes as it is, which only the delivery's msgRef tells: a delivery
            // that cannot be read waits rather than be guessed at.
            var msgRef = ""
            if deliveryId > 0 {
                do {
                    msgRef = try await db.deliveries.getById(deliveryId)?.msgRef ?? ""
                } catch {
                    return "the delivery could not be read: \(error)"
                }
            }
            if SatelliteChain.sealsDelivery(msgRef: msgRef, payload: text) {
                let key = await satelliteChainKey()
                do {
                    data = try SatelliteChain.seal(text, keyHex: key, chain: chain)
                } catch {
                    return "\(Dispatcher.never) Not sent: \(error). "
                        + "Enter the kit's iridium \"shared\" key in Setup > Satellite, or set the satellite chain to plain."
                }
            }
        }
        let status = await imtDriver.sendMessageBlocking(data)
        if status == Iridium9704Driver.moCancelUnanswered {
            return "\(Dispatcher.unconfirmed) the 9704 did not answer the cancel of a message it held"
        }
        if status != "mo_ack_received" { return "9704 MO failed: \(status ?? "timeout")" }
        return nil
    }

    /// The key the kits' satellite chains name, stored under exactly "iridium:shared" (the
    /// satellite settings' key field) and never read by the address alone, which another channel's
    /// "shared" can take: a Hub key_rotate stores its key under the address alone, and the chain
    /// never reads that (r33 review R33-R3). Nil when there is none or it cannot be read.
    func satelliteChainKey() async -> String? {
        let keys = db.conversationKeys
        return await SatelliteChain.key { name in
            do {
                return try await keys.getBySender(name)?.hexKey
            } catch {
                Self.log.warning("Satellite chain key could not be read: \(error)")
                return nil
            }
        }
    }
}
