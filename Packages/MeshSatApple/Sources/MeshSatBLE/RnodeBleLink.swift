// Mirrors rnode/RnodeBleLink.kt and RnodeBleScanner.kt (MESHSAT-1553 P4, here MESHSAT-1735): an
// RNode over Bluetooth LE, the Nordic UART service the RNode firmware exposes (RNodeInterface's
// BLEConnection). Bytes to the radio go to the RX characteristic in chunks of the negotiated
// length, bytes from it arrive as notifications on TX. The first protected operation on an
// unbonded RNode brings up iOS's pairing prompt, with the passkey on the radio's display. iOS names
// a peripheral by a UUID of its own, not the radio's address, so the setting is "ble:<uuid>". The
// link has its own CBCentralManager beside the node's, as Android's has its own BluetoothGatt.
import CoreBluetooth
import Foundation
import MeshSatRns

public enum RnodeBle {
    public static var nusService: CBUUID { CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") }
    /// The host writes here.
    public static var nusRx: CBUUID { CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") }
    /// The radio notifies here.
    public static var nusTx: CBUUID { CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") }
}

public final class RnodeBleLink: NSObject, RnodeLink, @unchecked Sendable {
    public let peripheralId: UUID
    /// Bytes from the radio (on the link's queue).
    public var onBytes: (@Sendable ([UInt8]) -> Void)?
    /// The link dropped after it was up.
    public var onDisconnected: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "net.meshsat.ios.rnode.ble")
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var ready: CheckedContinuation<String?, Never>?
    private var up = false
    private var closed = false
    private let log: @Sendable (String) -> Void

    public init(peripheralId: UUID, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.peripheralId = peripheralId
        self.log = log
    }

    /// Connects and brings the UART up; nil when ready, else why not. Gives up after `timeoutMs`.
    public func connect(timeoutMs: Int64 = 40_000) async -> String? {
        let result: String? = await withCheckedContinuation { c in
            lock.lock()
            ready = c
            lock.unlock()
            queue.async { [self] in
                central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) { [weak self] in
                self?.settle("BLE connection to the RNode timed out")
            }
        }
        if result != nil { close() }
        return result
    }

    private func settle(_ why: String?) {
        lock.lock()
        let c = ready
        ready = nil
        if why == nil { up = true }
        lock.unlock()
        c?.resume(returning: why)
    }

    public func write(_ b: [UInt8]) throws {
        lock.lock()
        let p = peripheral
        let c = rx
        let isUp = up && !closed
        lock.unlock()
        guard isUp, let p, let c else { throw RnodeBleError.notConnected }
        let chunk = max(20, p.maximumWriteValueLength(for: .withResponse))
        var i = 0
        while i < b.count {
            let end = min(i + chunk, b.count)
            p.writeValue(Data(b[i..<end]), for: c, type: .withResponse)
            i = end
        }
    }

    public func close() {
        lock.lock()
        closed = true
        let c = central
        let p = peripheral
        central = nil
        peripheral = nil
        lock.unlock()
        queue.async {
            if let p { c?.cancelPeripheralConnection(p) }
        }
    }
}

public enum RnodeBleError: Error, CustomStringConvertible {
    case notConnected
    public var description: String { "the RNode's Bluetooth link is not up" }
}

extension RnodeBleLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard let p = central.retrievePeripherals(withIdentifiers: [peripheralId]).first else {
                settle("this RNode is not known to the phone; scan for it again")
                return
            }
            lock.lock()
            peripheral = p
            lock.unlock()
            p.delegate = self
            log("rnode ble: connecting to \(p.name ?? peripheralId.uuidString)")
            central.connect(p, options: nil)
        case .poweredOff: settle("Bluetooth is off")
        case .unauthorized: settle("Bluetooth is not allowed for MeshSat")
        case .unsupported: settle("this phone has no Bluetooth LE")
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([RnodeBle.nusService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        settle("BLE connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        let wasUp = up
        let wasClosed = closed
        up = false
        lock.unlock()
        let why = "BLE disconnected" + (error.map { ": \($0.localizedDescription)" } ?? "")
        settle(why)
        if wasUp, !wasClosed { onDisconnected?(why) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == RnodeBle.nusService }) else {
            settle("no Nordic UART service: not an RNode?")
            return
        }
        peripheral.discoverCharacteristics([RnodeBle.nusRx, RnodeBle.nusTx], for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        guard let rxc = chars.first(where: { $0.uuid == RnodeBle.nusRx }), let txc = chars.first(where: { $0.uuid == RnodeBle.nusTx })
        else {
            settle("UART characteristics missing")
            return
        }
        lock.lock()
        rx = rxc
        lock.unlock()
        peripheral.setNotifyValue(true, for: txc)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            settle("could not enable UART notifications: \(error.localizedDescription)")
        } else if characteristic.isNotifying {
            log("rnode ble: UART up, write length \(peripheral.maximumWriteValueLength(for: .withResponse))")
            settle(nil)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == RnodeBle.nusTx, let v = characteristic.value else { return }
        onBytes?([UInt8](v))
    }
}

/// RnodeBleScanner.kt: the RNodes advertising the Nordic UART service nearby, for the card's list.
public final class RnodeBleScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public struct Found: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    public var onFound: (@Sendable (Found) -> Void)?
    private let queue = DispatchQueue(label: "net.meshsat.ios.rnode.scan")
    private var central: CBCentralManager?

    override public init() { super.init() }

    public func start() {
        queue.async { [self] in
            central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    public func stop() {
        queue.async { [self] in
            central?.stopScan()
            central = nil
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [RnodeBle.nusService], options: nil) }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "RNode"
        onFound?(Found(id: peripheral.identifier, name: name, rssi: rssi.intValue))
    }
}
