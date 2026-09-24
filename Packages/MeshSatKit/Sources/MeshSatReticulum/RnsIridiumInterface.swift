// Mirrors reticulum/RnsIridiumInterface.kt: a Reticulum interface over Iridium SBD through the
// 9603 driver on the node's BLE pipe (MESHSAT-216). Packets go in Mobile-Originated messages
// behind a magic byte; most fit one 340-byte frame, larger ones are refused (fragmentation is
// the Resource layer's job). Cost about USD 0.05 a message, latency 30 to 90 s.
import Foundation
import MeshSatMeshtastic

public final class RnsIridiumInterface: RnsInterface, @unchecked Sendable {
    public static let iridiumMoMtu = 340
    public static let iridiumMtMtu = 270
    /// 0x52 'R' before every RNS packet in an SBD payload, so legacy MeshSat SBD traffic is told apart.
    public static let sbdRnsMagic: UInt8 = 0x52

    public let interfaceId: String
    public let name = "Iridium SBD"
    public let mtu = RnsIridiumInterface.iridiumMoMtu
    public let costCents = 5
    public let latencyMs = 60_000
    public let isBidirectional = true
    private let driver: IridiumATDriver
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var receiveCallback: RnsReceiveCallback?
    private var online = false
    private var watch: Task<Void, Never>?

    public init(driver: IridiumATDriver, interfaceId: String = "iridium_rns_0", log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.driver = driver
        self.interfaceId = interfaceId
        self.log = log
    }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    /// Follows the driver's state; the driver's own lifetime belongs to the gateway.
    public func start() async {
        let stream = driver.stateChanges.subscribe()  // subscribed before the task runs, nothing missed
        let task = Task { [weak self] in
            for await s in stream { self?.setOnline(s == .connected) }
        }
        replaceWatch(task)
    }

    public func stop() async { replaceWatch(nil) }

    private func replaceWatch(_ task: Task<Void, Never>?) {
        lock.lock()
        let old = watch
        watch = task
        lock.unlock()
        old?.cancel()
    }

    private func callback() -> RnsReceiveCallback? {
        lock.lock()
        defer { lock.unlock() }
        return receiveCallback
    }

    private func setOnline(_ v: Bool) {
        lock.lock()
        online = v
        lock.unlock()
    }

    /// Write the packet to the MO buffer and run a session; the modem finds the satellite by
    /// itself. The gateway's TokenBucket still gates Iridium sends against cost overrun.
    public func send(_ packet: [UInt8]) async -> String? {
        guard isOnline else { return "iridium interface offline" }
        guard packet.count <= mtu else { return "packet exceeds Iridium MO MTU (\(mtu) bytes)" }
        guard await driver.writeMoBuffer([Self.sbdRnsMagic] + packet) else { return "failed to write MO buffer" }
        guard let result = await driver.sbdix(deliverMt: false) else { return "SBDIX session failed" }
        guard result.moStatus <= 4 else { return "MO send failed: status=\(result.moStatus)" }
        log("RNS packet sent via Iridium SBD: \(packet.count)B, MO status=\(result.moStatus)")
        if result.mtStatus == 1, result.mtLength > 0 { await handleMtMessage() }
        return nil
    }

    /// The modem's MT flag means a message is already in its buffer: reading it is free, while
    /// an SBDIX here would be billed for nothing (MESHSAT-1236).
    @discardableResult
    public func pollMt() async -> Bool {
        guard isOnline, let status = await driver.sbdStatus(), status.mtFlag else { return false }
        await handleMtMessage()
        return true
    }

    private func handleMtMessage() async {
        // Binary read: a Reticulum packet is not text and does not survive AT+SBDRT.
        guard let bytes = await driver.readMtBinary() else { return }
        guard let first = bytes.first, first == Self.sbdRnsMagic else {
            log("MT message is not an RNS packet (no magic byte)")
            return
        }
        let packet = Array(bytes.dropFirst())
        callback()?(interfaceId, packet)
        log("RNS packet received via Iridium MT: \(packet.count)B")
    }
}
