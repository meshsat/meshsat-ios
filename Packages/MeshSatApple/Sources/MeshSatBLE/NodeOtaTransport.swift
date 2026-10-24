// Mirrors the Bluetooth half of ble/NodeOtaTransport.kt (MESHSAT-1672): finds the node's OTA
// loader, connects and subscribes, then runs the loader's protocol (MeshSatMeshtastic's
// NodeOtaProtocol) over it. Its own CBCentralManager, alive for one update only; the node's own
// central holds every connect while it runs (MeshtasticCentral.heldForFirmwareUpdate), since the
// loader takes one connection.
//
// The loader is found by scanning for its service, never by the node's identifier: on MSC-2 unit
// 0001 (24 Oct 2026) the loader did not answer on the node's own address, and CoreBluetooth has
// no address anyway. iOS cannot tell which node a loader belongs to, so the first one seen is
// taken; two nodes updating side by side are rare.
import CoreBluetooth
import Foundation
import Logging
import MeshSatMeshtastic
import MeshSatNet

public final class NodeOtaTransport: NSObject, NodeOtaLink, @unchecked Sendable {
    private static let log = Logger(label: "NodeOta")

    static let scanTimeoutMs: Int64 = 45_000
    static let secondScanTimeoutMs: Int64 = 30_000
    static let retryPauseMs: Int64 = 3_000
    static let connectTimeoutMs: Int64 = 15_000
    static let discoverTimeoutMs: Int64 = 10_000
    static let opTimeoutMs: Int64 = 5_000
    static let poweredOnTimeoutMs: Int64 = 5_000
    /// How long a chunk waits for room in CoreBluetooth's write-without-response queue; the
    /// loader's ACK is the flow control, so this is only the stack's own back-pressure.
    static let writeRoomTimeoutMs: Int64 = 1_000

    private static var serviceUUID: CBUUID { CBUUID(string: NodeOtaProtocol.serviceUUID) }
    private static var writeUUID: CBUUID { CBUUID(string: NodeOtaProtocol.writeUUID) }
    private static var notifyUUID: CBUUID { CBUUID(string: NodeOtaProtocol.notifyUUID) }

    private let queue = DispatchQueue(label: "net.meshsat.ios.ble.ota")
    private let lock = NSLock()
    private let clock: any DriverClock
    private let lines = NodeOtaLines()
    private var central: CBCentralManager?
    private var poweredOn = false
    private var found: CBPeripheral?
    private var peripheral: CBPeripheral?
    private var connected = false
    private var dropped = false
    private var servicesDone: Error??
    private var characteristicsDone: Error??
    private var notifyDone: Error??
    private var writeDone: Error??
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    public init(clock: any DriverClock = SystemDriverClock()) {
        self.clock = clock
        super.init()
    }

    /// Update the node, already rebooting into its loader with this image's hash, with `image`.
    public func update(_ image: NodeFirmwareImage, onStep: @escaping @Sendable (NodeOtaProtocol.Step) -> Void) async
        -> NodeOtaProtocol.Outcome
    {
        onStep(.connecting)
        let c = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        locked { central = c }
        defer { finish() }
        guard await wait(Self.poweredOnTimeoutMs, { $0.poweredOn }) else {
            return .failed("Bluetooth is off.", loaderHasImage: false)
        }
        guard await connectToLoader() else {
            return .failed(
                "The node's updater did not answer over Bluetooth. Keep the phone close to the node and try again.", loaderHasImage: false)
        }
        guard let p = locked({ peripheral }) else {
            return .failed("The node's updater did not answer over Bluetooth.", loaderHasImage: false)
        }
        p.discoverServices([Self.serviceUUID])
        guard let servicesError = await waitResult(Self.discoverTimeoutMs, { $0.servicesDone }), servicesError == nil,
            let service = p.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { return .failed("The node's updater was not found on the node.", loaderHasImage: false) }
        p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
        _ = await waitResult(Self.discoverTimeoutMs, { $0.characteristicsDone })
        let chars = service.characteristics ?? []
        guard let write = chars.first(where: { $0.uuid == Self.writeUUID }) else {
            return .failed("The node's updater has no data characteristic.", loaderHasImage: false)
        }
        guard let notify = chars.first(where: { $0.uuid == Self.notifyUUID }) else {
            return .failed("The node's updater has no answer characteristic.", loaderHasImage: false)
        }
        locked {
            writeChar = write
            notifyChar = notify
        }
        p.setNotifyValue(true, for: notify)
        guard let notifyError = await waitResult(Self.opTimeoutMs, { $0.notifyDone }), notifyError == nil else {
            return .failed("Could not subscribe to the node's updater.", loaderHasImage: false)
        }
        Self.log.info("OTA: writes of up to \(p.maximumWriteValueLength(for: .withoutResponse)) bytes")
        return await NodeOtaProtocol.run(image: image, link: self, lines: lines, clock: clock, onStep: onStep)
    }

    /// The loader by its service; one more scan after a pause, as it may still be starting.
    private func connectToLoader() async -> Bool {
        for (round, timeoutMs) in [Self.scanTimeoutMs, Self.secondScanTimeoutMs].enumerated() {
            if round > 0 {
                Self.log.warning("OTA: no loader in the scan; scanning again")
                await clock.sleep(ms: Self.retryPauseMs)
            }
            guard let target = await scan(timeoutMs) else { continue }
            if await connect(target) { return true }
            Self.log.warning("OTA: the loader found by scan did not take the connection")
        }
        return false
    }

    private func scan(_ timeoutMs: Int64) async -> CBPeripheral? {
        guard let c = locked({ central }) else { return nil }
        // A connect that failed in the round before must not end this scan's wait.
        locked {
            found = nil
            dropped = false
        }
        c.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        defer { c.stopScan() }
        guard await wait(timeoutMs, { $0.found != nil }) else { return nil }
        return locked { found }
    }

    private func connect(_ target: CBPeripheral) async -> Bool {
        guard let c = locked({ central }) else { return false }
        locked {
            peripheral = target
            connected = false
            dropped = false
            servicesDone = nil
        }
        target.delegate = self
        c.connect(target, options: nil)
        guard await wait(Self.connectTimeoutMs, { $0.connected || $0.dropped }), locked({ connected }) else {
            c.cancelPeripheralConnection(target)
            return false
        }
        return true
    }

    // MARK: NodeOtaLink

    public func maxWriteWithoutResponse() -> Int {
        locked { peripheral }?.maximumWriteValueLength(for: .withoutResponse) ?? 20
    }

    public func writeCommand(_ bytes: [UInt8]) async -> Bool {
        guard let (p, c) = locked({ peripheral.flatMap { p in writeChar.map { (p, $0) } } }) else { return false }
        locked { writeDone = nil }
        p.writeValue(Data(bytes), for: c, type: .withResponse)
        guard let error = await waitResult(Self.opTimeoutMs, { $0.writeDone }) else { return false }
        return error == nil
    }

    public func writeChunk(_ bytes: [UInt8]) async -> Bool {
        guard let (p, c) = locked({ peripheral.flatMap { p in writeChar.map { (p, $0) } } }) else { return false }
        guard await wait(Self.writeRoomTimeoutMs, { _ in p.canSendWriteWithoutResponse }) else { return false }
        if locked({ dropped }) { return false }
        p.writeValue(Data(bytes), for: c, type: .withoutResponse)
        return true
    }

    // MARK: Waiting on the delegate

    /// Polls `ready` under the lock until it holds or `timeoutMs` passes; a dropped link ends it.
    private func wait(_ timeoutMs: Int64, _ ready: @escaping (NodeOtaTransport) -> Bool) async -> Bool {
        let deadline = clock.nowMs() + timeoutMs
        while true {
            let (ok, gone) = locked { (ready(self), dropped) }
            if ok { return true }
            if gone || clock.nowMs() >= deadline { return false }
            await clock.sleep(ms: 20)
        }
    }

    /// The outcome a delegate callback stored (nil error = success), or nil on a timeout.
    private func waitResult(_ timeoutMs: Int64, _ slot: @escaping (NodeOtaTransport) -> Error??) async -> Error?? {
        guard await wait(timeoutMs, { slot($0) != nil }) else { return nil }
        return locked { slot(self) }
    }

    private func finish() {
        let (c, p, n) = locked { (central, peripheral, notifyChar) }
        if let p, let n, p.state == .connected { p.setNotifyValue(false, for: n) }
        if let c, let p { c.cancelPeripheralConnection(p) }
        lines.close()
        locked {
            central = nil
            peripheral = nil
            found = nil
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension NodeOtaTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = central.state == .poweredOn
        locked { poweredOn = on }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi value: NSNumber
    ) {
        locked { if found == nil { found = peripheral } }
        Self.log.info("OTA: the loader advertises as \(peripheral.identifier.uuidString)")
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        locked { connected = true }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        locked { dropped = true }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        locked {
            connected = false
            dropped = true
        }
        lines.close()
    }
}

extension NodeOtaTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        locked { servicesDone = .some(error) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        locked { characteristicsDone = .some(error) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        locked { notifyDone = .some(error) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.notifyUUID, let value = characteristic.value else { return }
        lines.feed([UInt8](value))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        locked { writeDone = .some(error) }
    }
}
