// Mirrors reticulum/RnsRnodeInterface.kt and GatewayService.buildRnode/restartRnode (MESHSAT-1553
// P4, here MESHSAT-1735): an RNode as a Reticulum interface, the phone on Sideband's and Tim's LoRa
// meshes through a radio on Bluetooth LE ("ble:<peripheral uuid>"; USB OTG does not exist on an
// iPhone). Keeps the radio up: a drop or a device error closes and reopens it after 5 s, doubling
// to a minute.
import Foundation
import MeshSatBLE
import MeshSatEngine
import MeshSatNet
import MeshSatReticulum
import MeshSatRns

public final class RnsRnodeInterface: RnsInterface, @unchecked Sendable {
    public static let interfaceIdDefault = "rnode_rns_0"

    public struct Config: Sendable, Equatable {
        public let port: String
        public let params: RnodeProtocol.Params
        public var flowControl = true
    }

    public let interfaceId: String
    public let config: Config
    public let name = "RNode (LoRa)"
    public let mtu = RnodeProtocol.hwMtu
    public let costCents = 0
    public let latencyMs = 500
    public let isBidirectional = true

    private let lock = NSLock()
    private var receive: RnsReceiveCallback?
    private var driver: RnodeDriver?
    private var link: RnodeBleLink?
    private var supervisor: Task<Void, Never>?
    private var stopped = false
    private var statusText = "not started"
    private var lastErrorText = ""

    public init(config: Config, interfaceId: String = RnsRnodeInterface.interfaceIdDefault) {
        self.config = config
        self.interfaceId = interfaceId
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var isOnline: Bool { locked { driver?.online ?? false } }
    /// One line for the card: what the radio is doing.
    public var status: String { locked { statusText } }
    public var lastError: String { locked { lastErrorText } }
    public func stats() -> RnodeProtocol.Stats? { locked { driver?.currentStats() } }
    public var peripheralId: UUID? { UUID(uuidString: String(config.port.dropFirst(4))) }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) { locked { receive = callback } }

    public func send(_ packet: [UInt8]) async -> String? {
        guard let d = locked({ driver }), d.online else { return "rnode not online" }
        return d.send(packet)
    }

    public func start() async {
        let running = locked {
            if supervisor != nil { return true }
            stopped = false
            return false
        }
        if running { return }
        let task = Task { [weak self] in
            var pause: UInt64 = 5_000
            while !Task.isCancelled {
                guard let self, !self.locked({ self.stopped }) else { return }
                let lost = Promise<String>()
                if let err = await self.openOnce(lost) {
                    self.locked {
                        self.lastErrorText = err
                        self.statusText = "not up: \(err)"
                    }
                } else {
                    pause = 5_000
                    let why = (try? await lost.wait()) ?? "closed"
                    self.locked { self.statusText = "lost: \(why)" }
                }
                self.closeDriver()
                if self.locked({ self.stopped }) { return }
                try? await Task.sleep(nanoseconds: pause * 1_000_000)
                pause = min(pause * 2, 60_000)
            }
        }
        locked { supervisor = task }
    }

    /// Opens the link and configures the radio; nil when up, else why not. `lost` completes when it drops.
    private func openOnce(_ lost: Promise<String>) async -> String? {
        guard config.port.hasPrefix("ble:"), let id = peripheralId else { return "no RNode chosen; scan for one" }
        locked { statusText = "connecting to the RNode" }
        let ble = RnodeBleLink(peripheralId: id)
        let box = DriverBox()
        ble.onBytes = { b in box.driver?.feed(b) }
        ble.onDisconnected = { why in
            box.driver?.linkLost(why)
            lost.complete(why)
        }
        if let err = await ble.connect() { return err }
        locked {
            link = ble
            statusText = "configuring the radio"
        }
        let ifaceId = interfaceId
        let d = RnodeDriver(
            link: ble,
            options: RnodeDriver.Options(
                name: ifaceId, transport: .ble, params: config.params, flowControl: config.flowControl,
                onPacket: { [weak self] raw in self?.locked({ self?.receive })?(ifaceId, raw) },
                onError: { why in lost.complete(why) }))
        box.driver = d
        locked { driver = d }
        if let err = await d.open() { return err }
        locked {
            lastErrorText = ""
            statusText = "online"
        }
        return nil
    }

    private func closeDriver() {
        let (d, l) = locked {
            let pair = (driver, link)
            driver = nil
            link = nil
            return pair
        }
        d?.close()
        l?.close()
    }

    public func stop() async {
        let task = locked {
            stopped = true
            let t = supervisor
            supervisor = nil
            statusText = "stopped"
            return t
        }
        task?.cancel()
        closeDriver()
    }
}

/// The driver the link's callbacks reach, set once it exists.
private final class DriverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RnodeDriver?
    var driver: RnodeDriver? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

extension RnsRnodeInterface {
    /// SettingsRepository.rnodeParams: the preset's parameters (or the custom five), with the airtime limits.
    public static func params(preset: String, custom: String, airtime: String) -> RnodeProtocol.Params? {
        var base: RnodeProtocol.Params?
        if preset == "custom" {
            let f = custom.split(separator: ",").map { Int64($0.trimmingCharacters(in: .whitespaces)) }
            if f.count == 5, let fr = f[0], let bw = f[1], let tx = f[2], let sf = f[3], let cr = f[4] {
                base = RnodeProtocol.Params(frequency: fr, bandwidth: bw, txPower: Int(tx), sf: Int(sf), cr: Int(cr))
            }
        } else {
            base = RnodeProtocol.preset(preset)?.params
        }
        guard var p = base else { return nil }
        let air = airtime.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        p.staLock = air.first ?? 0
        p.ltaLock = air.count > 1 ? air[1] : 0
        return p
    }
}
