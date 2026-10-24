// Mirrors ble/NodeFirmwareUpdater.kt (MESHSAT-1672): a MeshSat node's firmware update from the
// phone over Bluetooth.
// 1. ask the node, over its Meshtastic link, to reboot into its OTA loader for this image's SHA-256
//    (AdminMessage.ota_request); the node answers "Rebooting to BLE OTA" or says why it will not;
// 2. let go of the node (no reconnect while the update holds it), give it time to restart;
// 3. send the image to the loader (MeshSatBLE's NodeOtaTransport, found by scanning for its
//    service), which checks the SHA-256, installs it and restarts into it;
// 4. connect to the node again.
// Once the node has gone to its loader (step 1 answered, or the link dropped after the request) it
// boots only the loader until an update with this image's SHA-256 completes, and from the update
// command on its old firmware may be erased (MESHSAT-1684). So the image and the node's address are
// kept from then on, and every failure of steps 2 to 4 offers `retry` with the same image, without
// step 1. A node left in its loader when the kept image is gone (the app restarted) gets the same
// file again through `sendToUpdater`: the scan finds the loader by its service.
import Foundation
import Logging
import MeshSatBLE
import MeshSatMeshtastic
import MeshSatNet

public final class NodeFirmwareUpdater: @unchecked Sendable {
    private static let log = Logger(label: "NodeFirmwareUpdater")
    public static let shared = NodeFirmwareUpdater()

    static let handoverTimeoutMs: Int64 = 8_000
    /// The loader is found by scanning for its service, which simply waits while the node restarts.
    static let restartIntoLoaderMs: Int64 = 2_000
    static let restartIntoFirmwareMs: Int64 = 8_000

    public enum State: Sendable, Equatable {
        case idle
        case askingNode
        case working(String, fraction: Double?)
        case done(version: String)
        /// `inUpdater`: the node waits in its loader and needs this update finished.
        case failed(String, canRetry: Bool, inUpdater: Bool = false)
    }

    public let state = StateBroadcast<State>(.idle)

    private let lock = NSLock()
    private let clock: any DriverClock
    /// The update that runs, set before its task starts so a quick one cannot outrun it.
    private var active: UUID?
    private var pending: NodeFirmwareImage?
    private var pendingAddress: String?

    init(clock: any DriverClock = SystemDriverClock()) { self.clock = clock }

    public var running: Bool { locked { active != nil } }

    /// Start an update of the connected node with `image`, already checked against the node's env.
    public func start(central: MeshtasticCentral, image: NodeFirmwareImage) {
        guard !running else { return }
        let me = central.radio.myInfo.value?.myNodeNum ?? 0
        guard let address = central.lastAddress, me != 0, central.state.value == .connected else {
            state.send(.failed("Connect to the node first.", canRetry: false))
            return
        }
        // Subscribed before the request goes out, so the node's answer cannot slip past.
        let notes = central.radio.clientNotifications.subscribe()
        run { [self] in
            state.send(.askingNode)
            let answer = LockedAnswer()
            let reader = Task {
                for await text in notes where NodeOtaProtocol.isHandoverAnswer(text) {
                    answer.set(text)
                    break
                }
            }
            await clock.sleep(ms: 200)
            central.sendToRadio(MeshtasticProtoAdapter.buildAdminOtaRequest(myNodeNum: me, sha256: image.sha256))
            let deadline = clock.nowMs() + Self.handoverTimeoutMs
            while answer.value == nil && central.state.value == .connected && clock.nowMs() < deadline {
                await clock.sleep(ms: 50)
            }
            reader.cancel()
            let said = answer.value
            switch NodeOtaProtocol.handover(said: said, linkUp: central.state.value == .connected) {
            case .accepted: Self.log.info("Node: \(said ?? "")")
            case .refused:
                state.send(.failed("The node will not update: \(said ?? "")", canRetry: false))
                return
            case .noAnswer:
                state.send(
                    .failed("The node did not answer the update request. Its firmware may be too old to update this way.", canRetry: false))
                return
            case .linkDropped: Self.log.warning("No handover answer, but the node dropped the link: going on")
            }
            // The node is going to its loader: from here only a finished update brings it back.
            keep(image, address)
            await transfer(central: central, address: address, image: image)
        }
    }

    /// Send `image` to a node already waiting in its loader (an update that did not finish and whose
    /// image this app no longer holds): no handover, straight to the scan. The loader takes only the
    /// image whose SHA-256 the node was handed, so it must be the same file.
    public func sendToUpdater(central: MeshtasticCentral, image: NodeFirmwareImage) {
        guard !running else { return }
        let address = central.lastAddress ?? ""
        keep(image, address)
        run { [self] in await transfer(central: central, address: address, image: image) }
    }

    /// Send the kept image to a node that stayed in its loader after a failed transfer.
    public func retry(central: MeshtasticCentral) {
        guard !running else { return }
        let kept: (NodeFirmwareImage, String)? = locked {
            guard let image = pending else { return nil }
            return (image, pendingAddress ?? central.lastAddress ?? "")
        }
        guard let (image, address) = kept else { return }
        run { [self] in await transfer(central: central, address: address, image: image) }
    }

    /// True while an image is kept for a node in its loader.
    public var hasPending: Bool { locked { pending != nil } }

    public func reset() {
        if !running { state.send(.idle) }
    }

    private func run(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        locked { active = id }
        Task { [self] in
            await body()
            locked { if active == id { active = nil } }
        }
    }

    private func transfer(central: MeshtasticCentral, address: String, image: NodeFirmwareImage) async {
        central.heldForFirmwareUpdate = true
        defer {
            central.heldForFirmwareUpdate = false
            if !address.isEmpty { central.connect(address: address) }
        }
        central.disconnect()
        state.send(.working("The node is restarting into its updater...", fraction: nil))
        await clock.sleep(ms: Self.restartIntoLoaderMs)
        guard central.bluetoothOn.value else {
            state.send(
                .failed(
                    "Bluetooth is off. The node waits in its updater: switch Bluetooth on and retry with the same file.", canRetry: true,
                    inUpdater: true))
            return
        }
        let outcome = await NodeOtaTransport(clock: clock).update(image) { [self] step in
            switch step {
            case .connecting: state.send(.working("Connecting to the node's updater...", fraction: nil))
            case .erasing: state.send(.working("The node is making room for the new firmware...", fraction: nil))
            case .sending(let sent, let total):
                state.send(.working("Sending the firmware: \(Int64(sent) * 100 / Int64(total)) %", fraction: Double(sent) / Double(total)))
            case .verifying: state.send(.working("The node is checking and installing the firmware...", fraction: 1))
            }
        }
        switch outcome {
        case .done:
            locked {
                pending = nil
                pendingAddress = nil
            }
            state.send(.working("Installed. The node is restarting...", fraction: 1))
            await clock.sleep(ms: Self.restartIntoFirmwareMs)
            state.send(.done(version: image.version.isEmpty ? "the new firmware" : image.version))
        case .failed(let reason, let stage):
            // The node went to its loader before the transfer started: every failure leaves it there.
            state.send(.failed(NodeOtaProtocol.failedInUpdater(reason, stage), canRetry: true, inUpdater: true))
        }
    }

    private func keep(_ image: NodeFirmwareImage, _ address: String) {
        locked {
            pending = image
            pendingAddress = address
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The first handover answer, set from the reader task and read by the waiting one.
private final class LockedAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
    func set(_ t: String) {
        lock.lock()
        if text == nil { text = t }
        lock.unlock()
    }
}
