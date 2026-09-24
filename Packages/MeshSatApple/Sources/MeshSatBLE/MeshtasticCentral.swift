// Mirrors ble/MeshtasticBle.kt (MESHSAT-1322): the GATT client for the MeshSat node over
// CoreBluetooth. Connects to a Meshtastic radio, subscribes to fromNum, asks for the config
// stream and drains fromRadio, writes ToRadio protobufs bare (the 0x94 0xC3 header belongs to
// the serial API, MESHSAT-1236), and publishes the node's Iridium pipe when the radio is a
// MeshSat node. The mesh state (my node, node list, config, channels, links) is the platform-
// free MeshtasticRadioState; every GATT operation goes through one GattOpQueue per connection.
//
// Android addresses a node by its Bluetooth MAC; iOS never sees one, so a node's "address" here
// is CoreBluetooth's per-app peripheral identifier (a UUID string), stable for this app on this
// phone and retrievable after a restart.
import CoreBluetooth
import Foundation
import Logging
import MeshSatMeshtastic
import MeshSatNet

public final class MeshtasticCentral: NSObject, @unchecked Sendable {
    private static let log = Logger(label: "MeshtasticCentral")
    // Android waits a moment between closing a client and opening the next; so does CoreBluetooth.
    public static let forceReconnectPauseMs: Int64 = 1_000
    /// The MTU CoreBluetooth reports before negotiation; the pipe never writes below 20 bytes.
    private static let attHeaderBytes = 3

    public enum State: Sendable, Equatable { case disconnected, scanning, connecting, connected }

    /// A radio seen while scanning.
    public struct DiscoveredNode: Sendable, Equatable {
        public let id: UUID
        public let name: String?
        public let rssi: Int
        public var address: String { id.uuidString }
    }

    public let state = StateBroadcast<State>(.disconnected)
    public let scanResults = Broadcast<DiscoveredNode>(bufferSize: 16)
    public let receivedData = Broadcast<[UInt8]>(bufferSize: 64)
    public let errors = Broadcast<String>(bufferSize: 8)
    public let rssi = StateBroadcast<Int>(0)
    /// Whether the phone's Bluetooth is switched on and this app may use it. When it is off,
    /// that is the whole reason the node cannot be reached, and the one thing worth telling the
    /// person (MESHSAT-615).
    public let bluetoothOn = StateBroadcast<Bool>(false)
    /// The node's Iridium serial pipe, when the connected radio is a MeshSat node.
    public let iridiumPipe = StateBroadcast<IridiumBlePipe?>(nil)
    /// Everything the radio told us.
    public let radio = MeshtasticRadioState()

    private let queue = DispatchQueue(label: "net.meshsat.ios.ble.central")
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// Peripherals seen by a scan or handed back by state restoration; CoreBluetooth needs a
    /// strong reference to connect to one.
    private var known: [UUID: CBPeripheral] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]
    private var ops: GattOpQueue?
    private var servicesToDiscover = 0
    private var scanTimeout: DispatchWorkItem?
    private var lastAddressValue: String?
    private let whoIsAsked = WhoIsLimiter()

    /// Last connected node identifier, used for `reconnect`.
    public var lastAddress: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastAddressValue
    }

    override public init() {
        super.init()
    }

    /// Create the CoreBluetooth central. This is what shows the Bluetooth permission prompt
    /// the first time, so it is not done in `init` but when a screen or the gateway wants the
    /// node. Calling it again is a no-op.
    public func start() {
        lock.lock()
        let exists = central != nil
        lock.unlock()
        if exists { return }
        let c = CBCentralManager(
            delegate: self, queue: queue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: MeshSatBLE.centralRestoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
        lock.lock()
        central = c
        lock.unlock()
    }

    private func manager() -> CBCentralManager? {
        lock.lock()
        defer { lock.unlock() }
        return central
    }

    // MARK: Scan

    public func startScan(timeoutMs: Int64 = 10_000) {
        start()
        guard let c = manager(), c.state == .poweredOn else {
            errors.send("Bluetooth not available")
            return
        }
        state.send(.scanning)
        c.scanForPeripherals(
            withServices: [MeshSatBLE.meshtasticService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let stop = DispatchWorkItem { [weak self] in self?.stopScan() }
        lock.lock()
        scanTimeout?.cancel()
        scanTimeout = stop
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs)), execute: stop)
    }

    public func stopScan() {
        lock.lock()
        scanTimeout?.cancel()
        scanTimeout = nil
        lock.unlock()
        if let c = manager(), c.isScanning { c.stopScan() }
        if state.value == .scanning { state.send(.disconnected) }
    }

    // MARK: Connect

    /// Connect to `address`, at most one GATT client at a time. A reconnect timer firing next
    /// to the user's Connect opened two clients to the node 20 ms apart; the session followed
    /// one and the modem handover went unheard (MESHSAT-1239). Already connecting or connected
    /// to `address` is a no-op; another node is disconnected first.
    public func connect(address: String) {
        start()
        guard let id = UUID(uuidString: address) else {
            errors.send("Invalid BLE address: \(address)")
            return
        }
        lock.lock()
        if peripheral != nil && address == lastAddressValue {
            lock.unlock()
            return
        }
        let other = peripheral != nil
        lock.unlock()
        if other { disconnect() }
        lock.lock()
        lastAddressValue = address
        lock.unlock()
        connect(id: id)
    }

    private func connect(id: UUID) {
        guard let c = manager() else { return }
        // With Bluetooth switched off there is nothing to connect with, and saying "Connecting"
        // would stay on the screen for ever (MESHSAT-615). Off is a state, not an error.
        guard c.state == .poweredOn else {
            state.send(.disconnected)
            return
        }
        stopScan()
        lock.lock()
        var p = known[id]
        lock.unlock()
        if p == nil, let found = c.retrievePeripherals(withIdentifiers: [id]).first {
            p = found
            lock.lock()
            known[id] = found
            lock.unlock()
        }
        guard let target = p else {
            errors.send("Node \(id.uuidString) is not known to this phone yet; scan for it")
            state.send(.disconnected)
            return
        }
        lock.lock()
        peripheral = target
        lock.unlock()
        target.delegate = self
        state.send(.connecting)
        c.connect(target, options: nil)
    }

    /// Use `address` for `reconnect` when none is known yet, e.g. the node saved before a restart.
    public func rememberNode(address: String) {
        lock.lock()
        if lastAddressValue == nil { lastAddressValue = address }
        lock.unlock()
    }

    /// Reconnect to the last-known node. No-op with an error if no node was ever used.
    public func reconnect() {
        if let addr = lastAddress {
            connect(address: addr)
        } else {
            errors.send("No previous BLE address for reconnect")
        }
    }

    /// Drop the link and build it again, even though the phone still calls it connected
    /// (MESHSAT-1270). `reconnect` is a no-op while a client to the same node exists, which is
    /// exactly the wedge this is for: attached, and taking no writes.
    public func forceReconnect() {
        guard let addr = lastAddress else { return }
        disconnect()
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(Self.forceReconnectPauseMs))) { [weak self] in
            self?.connect(address: addr)
        }
    }

    /// Bluetooth was switched off. CoreBluetooth invalidates the peripheral without a disconnect
    /// callback, so the client would stay, dead, and every later connect to the node would be
    /// refused as a duplicate (Android found this on 21 Sep 2026, MESHSAT-615).
    private func onBluetoothOff() {
        bluetoothOn.send(false)
        lock.lock()
        let idle = peripheral == nil
        lock.unlock()
        if idle && state.value == .disconnected { return }
        Self.log.info("Bluetooth went off; dropping the node link")
        lock.lock()
        peripheral = nil
        lock.unlock()
        teardown()
    }

    /// Bluetooth is back: go and get the node again.
    private func onBluetoothOn() {
        bluetoothOn.send(true)
        guard lastAddress != nil else { return }
        Self.log.info("Bluetooth is back; reconnecting to the node")
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(Self.forceReconnectPauseMs))) { [weak self] in
            self?.reconnect()
        }
    }

    public func disconnect() {
        lock.lock()
        let p = peripheral
        peripheral = nil
        lock.unlock()
        if let p, let c = manager() { c.cancelPeripheralConnection(p) }
        teardown()
    }

    /// Forget everything tied to the connection that just ended.
    private func teardown() {
        lock.lock()
        let q = ops
        ops = nil
        characteristics.removeAll()
        servicesToDiscover = 0
        lock.unlock()
        q?.close()
        iridiumPipe.value?.close()
        iridiumPipe.send(nil)
        state.send(.disconnected)
    }

    // MARK: Send to radio

    /// Send one ToRadio protobuf, bare: the firmware decodes each BLE write as the protobuf
    /// itself (MESHSAT-1236). A silent drop while not connected is state, not an error (MESHSAT-499).
    public func sendToRadio(_ data: [UInt8]) {
        guard state.value == .connected else { return }
        guard let q = currentOps() else { return }
        let uuid = MeshtasticBleContract.toRadioUUID
        q.enqueue("w:\(uuid)") { [self] in write(uuid: uuid, data) }
    }

    /// One read of fromRadio; a non-empty answer queues the next, until it runs dry.
    private func readFromRadio() {
        guard let q = currentOps() else { return }
        let uuid = MeshtasticBleContract.fromRadioUUID
        q.enqueue("r:\(uuid)") { [self] in read(uuid: uuid) }
    }

    /// Read the link's RSSI; the value arrives on `rssi`.
    public func readRssi() {
        guard state.value == .connected else { return }
        guard let q = currentOps() else { return }
        q.enqueue("rssi") { [self] in
            guard let p = currentPeripheral() else { return false }
            p.readRSSI()
            return true
        }
    }

    /// Update lastHeard for a node (called on any RX packet) and, when the node is unknown or
    /// nameless, ask it who it is.
    public func touchNode(_ nodeNum: UInt32) {
        if radio.touchNode(nodeNum) { askWhoIs(nodeNum) }
    }

    /// Ask a node we have no name for who it is (MESHSAT-1287), at most once every ten minutes
    /// per node: a name is worth one small packet, not a stream of them.
    public func askWhoIs(_ nodeNum: UInt32) {
        guard let me = radio.myInfo.value?.myNodeNum else { return }
        if state.value != .connected || nodeNum == me || nodeNum == MeshtasticProtocol.broadcastNodeNum { return }
        if radio.hasName(nodeNum) { return }
        if !whoIsAsked.mayAsk(nodeNum, nowMs: MeshtasticProtoAdapter.nowMs()) { return }
        Self.log.info("Asking \(MeshtasticProtocol.formatNodeId(nodeNum)) who it is")
        sendToRadio(
            MeshtasticProtoAdapter.encodeNodeInfoRequest(
                myNodeNum: me, destNode: nodeNum, longName: radio.ownerName.value, shortName: radio.ownerShortName.value))
    }

    // MARK: GATT primitives (each answers whether the stack took the operation)

    private func currentOps() -> GattOpQueue? {
        lock.lock()
        defer { lock.unlock() }
        return ops
    }

    private func currentPeripheral() -> CBPeripheral? {
        lock.lock()
        defer { lock.unlock() }
        return peripheral
    }

    private func characteristic(_ uuid: String) -> (CBPeripheral, CBCharacteristic)? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = peripheral, let c = characteristics[uuid.lowercased()] else { return nil }
        return (p, c)
    }

    fileprivate func write(uuid: String, _ data: [UInt8]) -> Bool {
        guard let (p, c) = characteristic(uuid) else { return false }
        p.writeValue(Data(data), for: c, type: .withResponse)
        return true
    }

    fileprivate func read(uuid: String) -> Bool {
        guard let (p, c) = characteristic(uuid) else { return false }
        p.readValue(for: c)
        return true
    }

    fileprivate func setNotify(uuid: String, on: Bool) -> Bool {
        guard let (p, c) = characteristic(uuid) else { return false }
        p.setNotifyValue(on, for: c)
        return true
    }

    fileprivate func has(_ uuid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return characteristics[uuid.lowercased()] != nil
    }

    /// The largest acknowledged write the link takes now.
    fileprivate func writeChunkSize() -> Int {
        guard let p = currentPeripheral() else { return IridiumPipeContract.minChunkBytes }
        return p.maximumWriteValueLength(for: .withResponse)
    }

    /// After discovery: subscribe to fromNum, ask for the config stream (the firmware sends
    /// nothing to a client that never sent want_config_id), then drain fromRadio. A MeshSat
    /// node also offers its Iridium pipe; it is published here and taken by the 9603 driver.
    private func startSession() {
        let q = GattOpQueue()
        lock.lock()
        ops = q
        lock.unlock()
        let fromNum = MeshtasticBleContract.fromNumUUID
        q.enqueue("d:\(fromNum)") { [self] in setNotify(uuid: fromNum, on: true) }
        if has(IridiumPipeContract.rxUUID) || has(IridiumPipeContract.txUUID) {
            let pipe = IridiumBlePipe(link: PipeLink(central: self))
            if pipe.usable { iridiumPipe.send(pipe) }
        }
        state.send(.connected)
        sendToRadio(MeshtasticProtocol.encodeWantConfig(UInt32.random(in: 1...UInt32(Int32.max))))
        readFromRadio()
    }

    private func emit(_ value: [UInt8]) {
        radio.observeLinks(value)
        receivedData.send(value)
    }

    private static func status(_ error: Error?) -> Int {
        guard let error else { return GattOpQueue.statusSuccess }
        let code = (error as NSError).code
        return code > 0 ? code : 1
    }

    /// The pipe's view of this connection.
    private final class PipeLink: IridiumPipeLink, @unchecked Sendable {
        private let central: MeshtasticCentral
        init(central: MeshtasticCentral) { self.central = central }
        var hasRx: Bool { central.has(IridiumPipeContract.rxUUID) }
        var hasTx: Bool { central.has(IridiumPipeContract.txUUID) }
        var hasStatus: Bool { central.has(IridiumPipeContract.statusUUID) }
        func chunkSize() -> Int { central.writeChunkSize() }
        func write(uuid: String, _ chunk: [UInt8]) async -> Int {
            guard let q = central.currentOps() else { return GattOpQueue.statusClosed }
            let central = central
            return await q.enqueue("w:\(uuid)") { central.write(uuid: uuid, chunk) }.await()
        }
        func setNotify(uuid: String, on: Bool) async -> Int {
            guard let q = central.currentOps() else { return GattOpQueue.statusClosed }
            let central = central
            return await q.enqueue("d:\(uuid)") { central.setNotify(uuid: uuid, on: on) }.await()
        }
        func read(uuid: String) {
            guard let q = central.currentOps() else { return }
            let central = central
            q.enqueue("r:\(uuid)") { central.read(uuid: uuid) }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MeshtasticCentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onBluetoothOn()
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            onBluetoothOff()
        default:
            break
        }
    }

    /// iOS relaunched the app for this central: adopt the peripheral it kept for us.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = restored.first else {
            return
        }
        Self.log.info("Restored the node link \(p.identifier.uuidString) (\(p.state.rawValue))")
        lock.lock()
        known[p.identifier] = p
        lastAddressValue = p.identifier.uuidString
        peripheral = p
        lock.unlock()
        p.delegate = self
        if p.state == .connected {
            state.send(.connecting)
            p.discoverServices([MeshSatBLE.meshtasticService, MeshSatBLE.iridiumPipeService])
        } else {
            state.send(.connecting)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi value: NSNumber
    ) {
        lock.lock()
        known[peripheral.identifier] = peripheral
        lock.unlock()
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        scanResults.send(DiscoveredNode(id: peripheral.identifier, name: name, rssi: value.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Android requests the MTU here; CoreBluetooth negotiates it by itself.
        peripheral.discoverServices([MeshSatBLE.meshtasticService, MeshSatBLE.iridiumPipeService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        if self.peripheral === peripheral { self.peripheral = nil }
        lock.unlock()
        teardown()
        errors.send("BLE connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        if self.peripheral === peripheral { self.peripheral = nil }
        lock.unlock()
        teardown()
        errors.send("BLE disconnected (\(error.map { String(describing: ($0 as NSError).code) } ?? "0"))")
    }
}

// MARK: - CBPeripheralDelegate

extension MeshtasticCentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            errors.send("Service discovery failed: \(error.localizedDescription)")
            disconnect()
            return
        }
        let services = peripheral.services ?? []
        guard let mesh = services.first(where: { $0.uuid == MeshSatBLE.meshtasticService }) else {
            errors.send("Meshtastic BLE service not found")
            disconnect()
            return
        }
        var wanted = [mesh]
        if let pipe = services.first(where: { $0.uuid == MeshSatBLE.iridiumPipeService }) { wanted.append(pipe) }
        lock.lock()
        servicesToDiscover = wanted.count
        lock.unlock()
        for s in wanted { peripheral.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        lock.lock()
        for c in service.characteristics ?? [] { characteristics[c.uuid.uuidString.lowercased()] = c }
        servicesToDiscover -= 1
        let done = servicesToDiscover <= 0
        lock.unlock()
        guard done else { return }
        if !has(MeshtasticBleContract.toRadioUUID) || !has(MeshtasticBleContract.fromRadioUUID) {
            errors.send("Meshtastic characteristics not found")
            disconnect()
            return
        }
        startSession()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        currentOps()?.complete("d:\(characteristic.uuid.uuidString.lowercased())", status: Self.status(error))
    }

    /// Both a read answer and a notification land here; the queue only takes it as the answer
    /// to a read when a read of that characteristic is in flight.
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString.lowercased()
        currentOps()?.complete("r:\(uuid)", status: Self.status(error))
        if error != nil { return }
        let value = [UInt8](characteristic.value ?? Data())
        switch uuid {
        case MeshtasticBleContract.fromRadioUUID:
            if !value.isEmpty {
                emit(value)
                readFromRadio()
            }
        case MeshtasticBleContract.fromNumUUID:
            readFromRadio()
        case _ where IridiumBlePipe.isPipeCharacteristic(uuid):
            iridiumPipe.value?.onValue(uuid: uuid, value)
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        currentOps()?.complete("w:\(characteristic.uuid.uuidString.lowercased())", status: Self.status(error))
        if let error { errors.send("BLE write failed: \(error.localizedDescription)") }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI value: NSNumber, error: Error?) {
        currentOps()?.complete("rssi", status: Self.status(error))
        if error == nil { rssi.send(value.intValue) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The node's GATT table changed (a firmware update); the link is not what it was.
        Self.log.info("Node services changed; reconnecting")
        forceReconnect()
    }
}
