// Mirrors reticulum/RnsBlePeripheralInterface.kt (MESHSAT-269): a Reticulum interface as a
// BLE peripheral. The phone advertises the Reticulum service so another phone, a laptop or a
// board can connect and exchange raw Reticulum packets with no Meshtastic hardware between.
//
//   Service a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5d
//   TX      ...4c5e  NOTIFY, peripheral to central
//   RX      ...4c5f  WRITE and WRITE WITHOUT RESPONSE, central to peripheral
//   Packets are the RNS wire format, one per write or notification, up to the negotiated MTU.
// Android never builds one in its gateway; this one is built on request (startReticulumBlePeripheral).
import CoreBluetooth
import Foundation
import Logging
import MeshSatReticulum

public final class RnsBlePeripheralInterface: NSObject, RnsInterface, @unchecked Sendable {
    private static let log = Logger(label: "RnsBlePeripheral")
    public static var serviceUUID: CBUUID { CBUUID(string: "a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5d") }
    public static var txUUID: CBUUID { CBUUID(string: "a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5e") }
    public static var rxUUID: CBUUID { CBUUID(string: "a4c1b2d3-e5f6-4a7b-8c9d-0e1f2a3b4c5f") }
    public static let defaultMTU = 20
    public static let maxMTU = 512

    public let interfaceId: String
    public let name = "BLE Peripheral"
    public let mtu = RnsConstants.mtu
    public let costCents = 0
    public let latencyMs = 50
    public let isBidirectional = true

    private let lock = NSLock()
    private var manager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var receiveCallback: RnsReceiveCallback?
    private var advertising = false
    private var wantAdvertising = false
    /// Centrals subscribed to TX, by identifier.
    private var subscribers: [UUID: CBCentral] = [:]
    private var pendingNotifications: [Data] = []

    public init(interfaceId: String = "ble_peripheral_rns_0") {
        self.interfaceId = interfaceId
        super.init()
    }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return advertising && !subscribers.isEmpty
    }

    public var connectedPeerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    /// Creating the manager shows the Bluetooth prompt, so it happens here, not in init.
    public func start() async {
        let m = prepareManager()
        if m?.state == .poweredOn { setupService(m) }
    }

    public func stop() async {
        let m = tearDown()
        m?.stopAdvertising()
        m?.removeAllServices()
    }

    /// One packet to every subscribed central; nil on success, else why not.
    public func send(_ packet: [UInt8]) async -> String? {
        let parts = sendParts()
        guard parts.subscribers > 0 else { return "no connected peers" }
        guard let tx = parts.tx else { return "GATT server not ready" }
        guard let m = parts.manager else { return "GATT server not started" }
        let data = Data(packet)
        if !m.updateValue(data, for: tx, onSubscribedCentrals: nil) {
            // The transmit queue is full: it goes when the manager says it is ready.
            enqueue(data)
        }
        return nil
    }

    // The lock is taken in synchronous helpers: Swift 6 rejects it inside an async function.
    private func prepareManager() -> CBPeripheralManager? {
        lock.lock()
        defer { lock.unlock() }
        wantAdvertising = true
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: DispatchQueue(label: "net.meshsat.ios.rns-ble-peripheral"))
        }
        return manager
    }

    private func tearDown() -> CBPeripheralManager? {
        lock.lock()
        defer { lock.unlock() }
        wantAdvertising = false
        advertising = false
        let m = manager
        manager = nil
        txCharacteristic = nil
        subscribers.removeAll()
        pendingNotifications.removeAll()
        return m
    }

    private struct SendParts {
        let manager: CBPeripheralManager?
        let tx: CBMutableCharacteristic?
        let subscribers: Int
    }

    private func sendParts() -> SendParts {
        lock.lock()
        defer { lock.unlock() }
        return SendParts(manager: manager, tx: txCharacteristic, subscribers: subscribers.count)
    }

    private func enqueue(_ data: Data) {
        lock.lock()
        pendingNotifications.append(data)
        lock.unlock()
    }

    private func setupService(_ m: CBPeripheralManager?) {
        guard let m else { return }
        let tx = CBMutableCharacteristic(type: Self.txUUID, properties: [.notify], value: nil, permissions: [])
        let rx = CBMutableCharacteristic(
            type: Self.rxUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [tx, rx]
        lock.lock()
        txCharacteristic = tx
        lock.unlock()
        m.removeAllServices()
        m.add(service)
        Self.log.info("GATT server configured with Reticulum service")
    }

    private func startAdvertising(_ m: CBPeripheralManager) {
        lock.lock()
        let wanted = wantAdvertising
        lock.unlock()
        guard wanted else { return }
        // No local name: the service UUID identifies us, as Android advertises.
        m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }
}

extension RnsBlePeripheralInterface: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            setupService(peripheral)
        default:
            lock.lock()
            advertising = false
            subscribers.removeAll()
            lock.unlock()
            Self.log.warning("Bluetooth not available for the peripheral (state \(peripheral.state.rawValue))")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            Self.log.error("Failed to add the Reticulum service: \(error)")
            return
        }
        startAdvertising(peripheral)
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        lock.lock()
        advertising = error == nil
        lock.unlock()
        if let error {
            Self.log.error("BLE advertising failed: \(error)")
        } else {
            Self.log.info("BLE advertising started")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.txUUID else { return }
        lock.lock()
        subscribers[central.identifier] = central
        lock.unlock()
        Self.log.info("Peer subscribed: \(central.identifier.uuidString) (MTU \(central.maximumUpdateValueLength))")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        lock.lock()
        subscribers[central.identifier] = nil
        lock.unlock()
        Self.log.info("Peer unsubscribed: \(central.identifier.uuidString)")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == Self.rxUUID, let value = request.value, value.count >= RnsConstants.headerMinSize {
                lock.lock()
                let cb = receiveCallback
                lock.unlock()
                cb?(interfaceId, [UInt8](value))
            }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        lock.lock()
        let tx = txCharacteristic
        var queue = pendingNotifications
        pendingNotifications.removeAll()
        lock.unlock()
        guard let tx else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if !peripheral.updateValue(next, for: tx, onSubscribedCentrals: nil) {
                lock.lock()
                pendingNotifications = [next] + queue + pendingNotifications
                lock.unlock()
                return
            }
        }
    }
}
