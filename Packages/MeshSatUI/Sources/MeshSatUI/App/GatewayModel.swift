// The gateway as the screens see it: Android's screens collect the service's StateFlows; here
// one @Observable object on the main actor mirrors the GatewayController's broadcasts into
// properties SwiftUI can read. Created once by RootView from the controller the app delegate
// started, so the screens never touch the controller's actors directly.
import Foundation
import MeshSatBLE
import MeshSatEngine
import MeshSatHub
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
    /// The IMEI of the modem connected now, else the last one this phone talked to.
    public private(set) var modemImei = ""
    public private(set) var interfaces: [String: InterfaceStatus] = [:]
    public private(set) var lastError = ""
    public private(set) var passes: [PassPrediction] = []
    public private(set) var passMode: PassScheduler.PassMode = .idle
    public private(set) var phoneFix: PhoneFix?
    /// The Hub provisioning claim (MESHSAT-1306) and a deep link waiting for confirmation.
    public private(set) var provisionState: ProvisionClaim.State = .idle
    public private(set) var provisionLink: String?
    /// Android's Toast: the text shown at the bottom, nil when none.
    public private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

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
        modemImei = gateway.settings.get(SettingsKey.lastModemImei)
        tasks.append(
            Task { [weak self] in
                for await s in driver.stateChanges.subscribe() {
                    self?.modemState = s
                    if s == .connected {
                        let imei = await driver.modemInfo.imei
                        if !imei.isEmpty { self?.modemImei = imei }
                    }
                }
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
        observeApp()
    }

    /// The app-level broadcasts: the provisioning claim and the pending deep link.
    private func observeApp() {
        let gateway = self.gateway
        tasks.append(
            Task { [weak self] in
                for await s in gateway.provisionClaim.state.subscribe() { self?.provisionState = s }
            })
        tasks.append(
            Task { [weak self] in
                for await link in gateway.pendingProvisionLink.subscribe() {
                    if let link { self?.provisionLink = link }
                }
            })
        if let scheduler = gateway.passScheduler {
            tasks.append(
                Task { [weak self] in
                    for await m in scheduler.mode.subscribe() { self?.passMode = m }
                })
        }
    }

    // MARK: Actions (the intents Android's screens send the service)

    public func provisionFromLink(_ request: ProvisionImporter.ProvisionRequest) { gateway.provisionClaim.fromLink(request) }
    public func provisionFromQr(_ url: String) { gateway.provisionClaim.fromQr(url) }
    public func applyProvision() { gateway.provisionClaim.apply() }
    public func dismissProvision() { gateway.provisionClaim.dismiss() }
    /// The link dialog took the pending link, or is done with it.
    public func provisionLinkHandled() {
        provisionLink = nil
        gateway.pendingProvisionLink.send(nil)
    }

    public func showToast(_ text: String, seconds: Double = 3.5) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Messages (GatewayService.ACTION_SEND_MESH / ACTION_SEND_IRIDIUM / ACTION_SEND_SMS)

    public func sendMesh(_ text: String, to peer: String) {
        if let num = Peers.nodeNum(peer) { gateway.sendMeshMessage(text, to: num) } else { gateway.sendMeshMessage(text) }
    }

    public func queueIridium(_ text: String, recipient: String) { gateway.queueIridiumMessage(text, recipient: recipient) }
    public func queueSms(_ text: String, to phone: String) { gateway.queueSmsMessage(text, recipient: phone) }

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
