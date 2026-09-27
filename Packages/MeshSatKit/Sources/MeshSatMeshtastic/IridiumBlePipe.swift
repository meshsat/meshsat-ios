// Mirrors ble/IridiumBlePipe.kt: the MeshSat node's BLE Iridium pipe (MESHSAT-1236), a
// binary-safe serial line to the node's RockBLOCK 9603, on the same connection as its
// Meshtastic service. It replaces the HC-05 SPP bridge; the 9603 AT driver runs on top of it
// as a ModemLink.
//
// Subscribing to TX is what takes the modem, and STATUS says who holds it: write only while
// `owner` is `.phone`, because the node discards bytes from anyone else. While the node's own
// logic holds the modem, `owner` is `.node` and the app waits.
//
// The GATT operations themselves come through `IridiumPipeLink`, which MeshtasticCentral
// (Packages/MeshSatApple) implements over CoreBluetooth, so this class runs in the Linux tests.
import Foundation
import Logging
import MeshSatNet

/// What the pipe needs from the connection: the three characteristics by UUID string, the
/// write size the link allows, and the GATT operations, each answering a GattOpQueue status.
public protocol IridiumPipeLink: AnyObject, Sendable {
    var hasRx: Bool { get }
    var hasTx: Bool { get }
    var hasStatus: Bool { get }
    /// The version 2 additions (MESHSAT-1378); a version 1 node has neither.
    var hasStats: Bool { get }
    var hasPass: Bool { get }
    /// The largest write the link takes now (the MTU minus the ATT header).
    func chunkSize() -> Int
    /// Write `chunk` to the characteristic, acknowledged; the GattOpQueue status.
    func write(uuid: String, _ chunk: [UInt8]) async -> Int
    /// Turn notifications on or off; the GattOpQueue status of the descriptor write.
    func setNotify(uuid: String, on: Bool) async -> Int
    /// Read the characteristic; its value arrives through `IridiumBlePipe.onValue`.
    func read(uuid: String)
}

public final class IridiumBlePipe: ModemLink, @unchecked Sendable {
    public typealias Owner = IridiumPipeContract.Owner

    private static let log = Logger(label: "IridiumBlePipe")

    private let link: any IridiumPipeLink
    private let lock = NSLock()
    private var receiver: (@Sendable ([UInt8]) -> Void)?
    private let refuseFlag: LockedFlag

    /// Who holds the modem; nil until STATUS has answered (Android's Owner.Unknown).
    public let owner: StateBroadcast<Owner?>
    /// The whole of STATUS, flags and signal included from version 2; nil until it answered.
    public let status = StateBroadcast<IridiumPipeContract.Status?>(nil)
    /// The node's satellite health (STATS), nil until read or on a version 1 node.
    public let stats = StateBroadcast<IridiumPipeContract.Stats?>(nil)
    /// Bytes the modem sent, for the AT driver.
    public let input = PipeInputBuffer()
    private let output: PipeOutputChunker

    /// False when the service lacks RX or TX: nothing here can be used.
    public var usable: Bool { link.hasRx && link.hasTx }
    /// The node serves the version 2 additions.
    public var hasStats: Bool { link.hasStats }
    public var hasPass: Bool { link.hasPass }
    /// The pass list this link last gave the node, so an unchanged prediction is not rewritten.
    public var passesWritten: [IridiumPipeContract.PassWindow]? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return passesWrittenValue
        }
        set {
            lock.lock()
            passesWrittenValue = newValue
            lock.unlock()
        }
    }
    private var passesWrittenValue: [IridiumPipeContract.PassWindow]?

    public init(link: any IridiumPipeLink) {
        self.link = link
        let ownerState = StateBroadcast<Owner?>(nil)
        let refuseCheck = LockedFlag()
        owner = ownerState
        refuseFlag = refuseCheck
        output = PipeOutputChunker(
            chunkSize: { link.chunkSize() },
            canWrite: { ownerState.value == .phone },
            sendChunk: { chunk in
                if refuseCheck.value {
                    IridiumBlePipe.log.warning("drill: write refused (\(chunk.count) bytes)")
                    return false
                }
                guard link.hasRx else { return false }
                return await link.write(uuid: IridiumPipeContract.rxUUID, chunk) == GattOpQueue.statusSuccess
            })
    }

    /// A drill for MESHSAT-1270: this pipe stops taking writes while the link stays attached,
    /// which is the wedge of 20 September and cannot be produced on a sealed node. Everything
    /// above this line is the real thing: the driver's counter, the interface going offline,
    /// the reconnect. The flag lives on the pipe, and a reconnect makes a new pipe, so recovery
    /// ends the drill exactly as it ended the real fault.
    public var refuseWrites: Bool {
        get { refuseFlag.value }
        set { refuseFlag.value = newValue }
    }

    /// Take the modem: subscribe to STATUS and TX and wait until STATUS says the phone owns
    /// it. False if nothing answered "phone" in time. A node without STATUS (firmware before
    /// a5038c8) counts as owned once TX is subscribed. STATUS saying "node" is a wait, never a
    /// failure: a node that owns its modem while no phone is subscribed hands it over about a
    /// second after the TX subscription, or after the session it has in flight (MESHSAT-1372);
    /// the owner observer attaches the driver on that notification whenever it comes.
    public func claim(timeoutMs: Int64 = 8_000) async -> Bool {
        guard link.hasTx else { return false }
        // One retry each: the first write can fail while the link is still being encrypted,
        // and without STATUS notifications the handover is never heard.
        if link.hasStatus {
            let watching = await twice("STATUS") { await link.setNotify(uuid: IridiumPipeContract.statusUUID, on: true) }
            if !watching { Self.log.warning("Iridium pipe: STATUS notifications could not be enabled; reading it instead") }
        }
        let subscribed = await twice("TX") { await link.setNotify(uuid: IridiumPipeContract.txUUID, on: true) }
        if !subscribed {
            Self.log.warning("Iridium pipe: TX subscription failed")
            return false
        }
        // Subscribing to TX is what hands the modem over: read STATUS after it, so the answer
        // arrives even when its notification does not.
        if link.hasStatus { refreshStatus() } else { owner.send(.phone) }
        if await awaitOwner(timeoutMs: timeoutMs) == .phone {
            Self.log.info("Iridium pipe: the phone owns the modem")
            return true
        }
        // Say what STATUS last read: "none" means the node never registered the TX
        // subscription (another central may hold the pipe), "node" that it is using the modem,
        // a stale "phone" that the notification was lost (25 Sep 2026, twelve claims in a row
        // answered nothing).
        let seen = owner.value
        let why = seen == .node ? ", the node is using the modem, waiting for its release)" : ")"
        Self.log.info("Iridium pipe: no handover within \(timeoutMs / 1000) s (STATUS says \(Self.describe(seen))\(why)")
        return false
    }

    static func describe(_ owner: Owner?) -> String {
        owner.map { "\($0)" } ?? "nothing"
    }

    /// Up to two attempts; a failure logs the ATT status, because 5 (insufficient
    /// authentication) and 15 (insufficient encryption) say the reconnect landed without the
    /// bond, the picture of the failed claims of 25 Sep 2026 (MESHSAT-1356).
    private func twice(_ what: String, _ op: () async -> Int) async -> Bool {
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            let status = await op()
            if status == GattOpQueue.statusSuccess { return true }
            Self.log.warning("Iridium pipe: \(what) subscribe attempt \(attempts) failed, \(Self.attStatusText(status))")
        }
        return false
    }

    /// An ATT error code in words, for the log.
    public static func attStatusText(_ status: Int) -> String {
        switch status {
        case GattOpQueue.statusRefused: "the stack refused the operation"
        case GattOpQueue.statusTimeout: "no answer from the node"
        case GattOpQueue.statusClosed: "the connection is gone"
        case 5: "ATT 5 insufficient authentication (the link is not bonded)"
        case 15: "ATT 15 insufficient encryption (the link is not encrypted)"
        default: "ATT status \(status)"
        }
    }

    /// The first `.phone` on the owner state, or nil after `timeoutMs`.
    private func awaitOwner(timeoutMs: Int64) async -> Owner? {
        let stream = owner.subscribe()
        return await withTaskGroup(of: Owner?.self) { group in
            group.addTask {
                for await o in stream where o == .phone { return o }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
    }

    /// Ask STATUS again, for a notification that may have been lost.
    public func refreshStatus() {
        if link.hasStatus { link.read(uuid: IridiumPipeContract.statusUUID) }
    }

    /// Follow STATS: subscribe and read it once. Independent of the claim, so the health card
    /// works while the node holds its modem. False on a node without it.
    @discardableResult
    public func watchStats() async -> Bool {
        guard link.hasStats else { return false }
        let watching = await twice("STATS") { await link.setNotify(uuid: IridiumPipeContract.statsUUID, on: true) }
        link.read(uuid: IridiumPipeContract.statsUUID)
        return watching
    }

    /// Read STATS again. The node notifies it only when something other than its three moving
    /// fields (the ages and the uptime) changes, so an idle node is silent and a card would
    /// freeze; a read always answers the live value. The health card asks every 10 s while it
    /// is on screen, nothing more.
    public func refreshStats() {
        if link.hasStats { link.read(uuid: IridiumPipeContract.statsUUID) }
    }

    /// Hand the node the next pass windows, soonest first, at most eight; a write replaces its
    /// list. Accepted whoever owns the modem. False on a node without PASS or a failed write.
    public func writePasses(_ windows: [IridiumPipeContract.PassWindow]) async -> Bool {
        guard link.hasPass else { return false }
        let status = await link.write(uuid: IridiumPipeContract.passUUID, IridiumPipeContract.encodePassList(windows))
        if status != GattOpQueue.statusSuccess {
            let count = min(windows.count, IridiumPipeContract.passListMax)
            Self.log.warning("Iridium pipe: PASS write of \(count) windows failed, \(Self.attStatusText(status))")
        }
        return status == GattOpQueue.statusSuccess
    }

    /// Hand the modem back to the node.
    public func release() async {
        if link.hasTx { _ = await link.setNotify(uuid: IridiumPipeContract.txUUID, on: false) }
        if !link.hasStatus { owner.send(IridiumPipeContract.Owner.none) }
        input.clear()
    }

    /// A value read or notified on one of the pipe's characteristics.
    public func onValue(uuid: String, _ value: [UInt8]) {
        switch uuid.lowercased() {
        case IridiumPipeContract.txUUID:
            input.offer(value)
            currentReceiver()?(value)
        case IridiumPipeContract.statusUUID:
            let parsed = IridiumPipeContract.parseStatus(value)
            let next = parsed?.owner
            if next != .phone && owner.value == .phone { input.clear() }
            status.send(parsed)
            owner.send(next)
        case IridiumPipeContract.statsUUID:
            if let parsed = IridiumPipeContract.parseStats(value) { stats.send(parsed) }
        default:
            break
        }
    }

    /// The connection is gone: wake any reader and forget the owner.
    public func close() {
        owner.send(nil)
        status.send(nil)
        input.close()
    }

    /// The characteristics whose values this pipe consumes (RX and PASS are write-only).
    public static func isPipeCharacteristic(_ uuid: String) -> Bool {
        let u = uuid.lowercased()
        return u == IridiumPipeContract.txUUID || u == IridiumPipeContract.statusUUID || u == IridiumPipeContract.statsUUID
    }

    // MARK: ModemLink

    public func write(_ bytes: [UInt8]) async throws {
        try await output.write(bytes)
    }

    public func setReceiver(_ receiver: (@Sendable ([UInt8]) -> Void)?) {
        lock.lock()
        self.receiver = receiver
        lock.unlock()
    }

    private func currentReceiver() -> (@Sendable ([UInt8]) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return receiver
    }
}

/// A Bool behind a lock, for a flag read from a Sendable closure.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock()
            flag = newValue
            lock.unlock()
        }
    }
}
