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
    /// Bytes the modem sent, for the AT driver.
    public let input = PipeInputBuffer()
    private let output: PipeOutputChunker

    /// False when the service lacks RX or TX: nothing here can be used.
    public var usable: Bool { link.hasRx && link.hasTx }

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
    /// it. False if the node's own logic holds it or nothing answered in time. A node without
    /// STATUS (firmware before a5038c8) counts as owned once TX is subscribed.
    public func claim(timeoutMs: Int64 = 8_000) async -> Bool {
        guard link.hasTx else { return false }
        // One retry each: the first write can fail while the link is still being encrypted,
        // and without STATUS notifications the handover is never heard.
        if link.hasStatus {
            let watching = await twice { await link.setNotify(uuid: IridiumPipeContract.statusUUID, on: true) }
            if !watching { Self.log.warning("Iridium pipe: STATUS notifications could not be enabled; reading it instead") }
        }
        let subscribed = await twice { await link.setNotify(uuid: IridiumPipeContract.txUUID, on: true) }
        if !subscribed {
            Self.log.warning("Iridium pipe: TX subscription failed")
            return false
        }
        // Subscribing to TX is what hands the modem over: read STATUS after it, so the answer
        // arrives even when its notification does not.
        if link.hasStatus { refreshStatus() } else { owner.send(.phone) }
        let answer = await awaitOwner(timeoutMs: timeoutMs)
        // On a timeout, say what STATUS last read: "none" means the node never registered the
        // TX subscription (another central may hold the pipe), a stale "phone" means the
        // notification was lost (25 Sep 2026, twelve claims in a row answered nothing).
        let said = answer.map { "\($0)" } ?? "nothing within \(timeoutMs / 1000) s, STATUS last read \(String(describing: owner.value))"
        Self.log.info("Iridium pipe: claim answered \(said)")
        return answer == .phone
    }

    private func twice(_ op: () async -> Int) async -> Bool {
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            if await op() == GattOpQueue.statusSuccess { return true }
        }
        return false
    }

    /// The first `.phone` or `.node` on the owner state, or nil after `timeoutMs`.
    private func awaitOwner(timeoutMs: Int64) async -> Owner? {
        let stream = owner.subscribe()
        return await withTaskGroup(of: Owner?.self) { group in
            group.addTask {
                for await o in stream where o == .phone || o == .node { return o }
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
            let next = IridiumPipeContract.parseStatus(value)?.owner
            if next != .phone && owner.value == .phone { input.clear() }
            owner.send(next)
        default:
            break
        }
    }

    /// The connection is gone: wake any reader and forget the owner.
    public func close() {
        owner.send(nil)
        input.close()
    }

    public static func isPipeCharacteristic(_ uuid: String) -> Bool {
        let u = uuid.lowercased()
        return u == IridiumPipeContract.txUUID || u == IridiumPipeContract.statusUUID
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
