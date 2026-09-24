// The gateway as the screens see it: Android's screens collect the service's StateFlows; here
// one @Observable object on the main actor mirrors the GatewayController's broadcasts into
// properties SwiftUI can read. Created once by RootView from the controller the app delegate
// started, so the screens never touch the controller's actors directly.
import Foundation
import MeshSatBLE
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatNet
import MeshSatPlatform
import MeshSatSatellite
import Observation

@Observable
@MainActor
public final class GatewayModel {
    public let gateway: GatewayController

    public private(set) var meshState: MeshtasticCentral.State = .disconnected
    public private(set) var bluetoothOn = false
    public private(set) var scanResults: [MeshtasticCentral.DiscoveredNode] = []
    public private(set) var myInfo: MeshtasticProtocol.MyNodeInfo?
    public private(set) var nodes: [MeshtasticProtocol.MeshNodeInfo] = []
    public private(set) var nodeBattery: GatewayController.NodeBatteryNow?
    public private(set) var modemState: IridiumATDriver.State = .disconnected
    public private(set) var modemSignal = 0
    public private(set) var interfaces: [String: InterfaceStatus] = [:]
    public private(set) var lastError = ""
    public private(set) var passes: [PassPrediction] = []
    public private(set) var passMode: PassScheduler.PassMode = .idle
    public private(set) var phoneFix: PhoneFix?

    private var tasks: [Task<Void, Never>] = []

    public init(gateway: GatewayController) {
        self.gateway = gateway
        observe()
    }

    private func observe() {
        let gateway = self.gateway
        let central = gateway.central
        let driver = gateway.driver
        tasks.append(
            Task { [weak self] in
                for await s in central.state.subscribe() { self?.meshState = s }
            })
        tasks.append(
            Task { [weak self] in
                for await on in central.bluetoothOn.subscribe() { self?.bluetoothOn = on }
            })
        tasks.append(
            Task { [weak self] in
                for await node in central.scanResults.subscribe() {
                    guard let self else { return }
                    if let i = scanResults.firstIndex(where: { $0.id == node.id }) {
                        scanResults[i] = node
                    } else {
                        scanResults.append(node)
                    }
                }
            })
        tasks.append(
            Task { [weak self] in
                for await info in central.radio.myInfo.subscribe() { self?.myInfo = info }
            })
        tasks.append(
            Task { [weak self] in
                for await list in central.radio.nodes.subscribe() { self?.nodes = list.sorted { $0.lastHeard > $1.lastHeard } }
            })
        tasks.append(
            Task { [weak self] in
                for await b in gateway.nodeBattery.subscribe() { self?.nodeBattery = b }
            })
        tasks.append(
            Task { [weak self] in
                for await s in driver.stateChanges.subscribe() { self?.modemState = s }
            })
        tasks.append(
            Task { [weak self] in
                for await bars in driver.signalReadings.subscribe() { self?.modemSignal = bars }
            })
        tasks.append(
            Task { [weak self] in
                for await states in gateway.interfaceManager.states.subscribe() { self?.interfaces = states }
            })
        tasks.append(
            Task { [weak self] in
                for await err in central.errors.subscribe() { self?.lastError = err }
            })
        tasks.append(
            Task { [weak self] in
                for await p in gateway.passes.subscribe() { self?.passes = p }
            })
        tasks.append(
            Task { [weak self] in
                for await fix in gateway.location.phoneLocation.subscribe() { self?.phoneFix = fix }
            })
        if let scheduler = gateway.passScheduler {
            tasks.append(
                Task { [weak self] in
                    for await m in scheduler.mode.subscribe() { self?.passMode = m }
                })
        }
    }

    // MARK: Actions (the intents Android's screens send the service)

    public func startScan() {
        scanResults.removeAll()
        gateway.central.startScan()
    }

    public func stopScan() { gateway.central.stopScan() }

    public func connect(_ node: MeshtasticCentral.DiscoveredNode) {
        gateway.central.stopScan()
        gateway.connectMesh(address: node.address)
    }

    public func disconnect() { gateway.disconnectMesh() }

    public var meshStatusText: String {
        switch meshState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .scanning: "Scanning..."
        case .disconnected: bluetoothOn ? "Disconnected" : "Bluetooth is off"
        }
    }

    public var modemStatusText: String {
        switch modemState {
        case .connected: "Connected, \(modemSignal)/5"
        case .connecting: "Connecting..."
        case .disconnected: meshState == .connected ? "No modem on this node" : "No modem"
        }
    }
}
