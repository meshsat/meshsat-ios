// Mirrors the state half of ble/MeshtasticBle.kt: everything the phone knows about the
// connected radio and its mesh (my node, the node list, the config sections, the channels,
// the metadata, the link signals and neighbour reports), kept free of CoreBluetooth so the
// merge rules run in the Linux tests. MeshtasticCentral (Packages/MeshSatApple) owns one.
import Foundation
import MeshSatNet
import MeshSatProto

/// One question per node per `everyMs`; pure, so the pacing has a test.
public final class WhoIsLimiter: @unchecked Sendable {
    public static let everyMs: Int64 = 10 * 60_000
    private let lock = NSLock()
    private var lastAskedMs: [UInt32: Int64] = [:]

    public init() {}

    public func mayAsk(_ nodeNum: UInt32, nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastAskedMs[nodeNum], nowMs - last < Self.everyMs { return false }
        lastAskedMs[nodeNum] = nowMs
        return true
    }
}

public final class MeshtasticRadioState: @unchecked Sendable {
    public let myInfo = StateBroadcast<MeshtasticProtocol.MyNodeInfo?>(nil)
    public let nodes = StateBroadcast<[MeshtasticProtocol.MeshNodeInfo]>([])
    public let ownerName = StateBroadcast<String>("")
    public let ownerShortName = StateBroadcast<String>("")
    public let loraConfig = StateBroadcast<Meshtastic_Config.LoRaConfig?>(nil)
    public let deviceConfig = StateBroadcast<Meshtastic_Config.DeviceConfig?>(nil)
    public let positionConfig = StateBroadcast<Meshtastic_Config.PositionConfig?>(nil)
    public let bluetoothConfig = StateBroadcast<Meshtastic_Config.BluetoothConfig?>(nil)
    public let networkConfig = StateBroadcast<Meshtastic_Config.NetworkConfig?>(nil)
    public let powerConfig = StateBroadcast<Meshtastic_Config.PowerConfig?>(nil)
    public let displayConfig = StateBroadcast<Meshtastic_Config.DisplayConfig?>(nil)
    public let channels = StateBroadcast<[MeshtasticProtocol.MeshChannel]>([])
    public let deviceMetadata = StateBroadcast<MeshtasticProtocol.MeshDeviceMetadata?>(nil)
    /// The latest NeighborInfo each node has sent, by reporting node number (MESHSAT-1249).
    public let neighborReports = StateBroadcast<[UInt32: MeshtasticProtocol.NeighborReport]>([:])
    /// How our radio heard the last over-the-air packet from each node, by node number.
    public let linkSignals = StateBroadcast<[UInt32: MeshtasticProtocol.MeshLinkSignal]>([:])

    private let now: @Sendable () -> Int64

    public init(now: @escaping @Sendable () -> Int64 = { MeshtasticProtoAdapter.nowMs() }) {
        self.now = now
    }

    /// A second, read-only look at every frame, for link data the service's dispatch does not
    /// keep. It never writes `nodes`, so it cannot race the service's node updates.
    public func observeLinks(_ frame: [UInt8]) {
        guard let obs = MeshtasticProtocol.parseLinkObservation(frame, nowMs: now()) else { return }
        let me = myInfo.value?.myNodeNum ?? 0
        if let sig = obs.signal, sig.from != me {
            linkSignals.update {
                var m = $0
                m[sig.from] = sig
                return m
            }
        }
        if let ni = obs.neighborInfo {
            let report = MeshtasticProtocol.NeighborReport(
                nodeId: ni.nodeId, neighbors: ni.neighbors, broadcastIntervalSecs: ni.broadcastIntervalSecs, receivedAt: now())
            neighborReports.update {
                var m = $0
                m[ni.nodeId] = report
                return m
            }
        }
    }

    public func setOwner(longName: String, shortName: String) {
        ownerName.send(longName)
        ownerShortName.send(shortName)
    }

    public func setConfig(_ config: Meshtastic_Config) {
        switch config.payloadVariant {
        case .lora(let c)?: loraConfig.send(c)
        case .device(let c)?: deviceConfig.send(c)
        case .position(let c)?: positionConfig.send(c)
        case .bluetooth(let c)?: bluetoothConfig.send(c)
        case .network(let c)?: networkConfig.send(c)
        case .power(let c)?: powerConfig.send(c)
        case .display(let c)?: displayConfig.send(c)
        default: break
        }
    }

    public func addChannel(_ channel: MeshtasticProtocol.MeshChannel) {
        channels.update { current in
            var list = current.filter { $0.index != channel.index }
            list.append(channel)
            list.sort { $0.index < $1.index }
            return list
        }
    }

    public func setDeviceMetadata(_ metadata: MeshtasticProtocol.MeshDeviceMetadata) {
        deviceMetadata.send(metadata)
    }

    public func setMyInfo(_ info: MeshtasticProtocol.MyNodeInfo) {
        // Signals are what OUR radio heard: another radio's measurements would draw false direct links.
        if let previous = myInfo.value?.myNodeNum, previous != 0, previous != info.myNodeNum {
            linkSignals.send([:])
        }
        myInfo.send(info)
    }

    /// Merge: identity fields the update leaves empty are kept from what was known. Config
    /// downloads often send partial NodeInfo, so only non-empty data overwrites.
    public func addNodeInfo(_ info: MeshtasticProtocol.MeshNodeInfo) {
        let nowMs = now()
        nodes.update { current in
            let existing = current.first { $0.nodeNum == info.nodeNum }
            var list = current.filter { $0.nodeNum != info.nodeNum }
            list.append(info.merged(over: existing, nowMs: nowMs))
            return list
        }
    }

    /// Update lastHeard for a node (called on any RX packet). Returns the node number to ask
    /// who it is when the node is unknown or nameless, so the caller can send the question.
    @discardableResult
    public func touchNode(_ nodeNum: UInt32) -> Bool {
        let nowMs = now()
        var known = false
        var named = false
        nodes.update { current in
            var list = current
            if let idx = list.firstIndex(where: { $0.nodeNum == nodeNum }) {
                list[idx].lastHeard = nowMs
                known = true
                named = !list[idx].longName.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return list
        }
        return !known || !named
    }

    public func updateNodeBattery(_ nodeNum: UInt32, batteryLevel: Int) {
        let nowMs = now()
        nodes.update { current in
            var list = current
            if let idx = list.firstIndex(where: { $0.nodeNum == nodeNum }) {
                list[idx].batteryLevel = batteryLevel
                list[idx].lastHeard = nowMs
            }
            return list
        }
    }

    /// True when a node with that number is known by name.
    public func hasName(_ nodeNum: UInt32) -> Bool {
        nodes.value.contains { $0.nodeNum == nodeNum && !$0.longName.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Forget everything the radio told us; used when another radio is connected.
    public func reset() {
        myInfo.send(nil)
        nodes.send([])
        channels.send([])
        deviceMetadata.send(nil)
        neighborReports.send([:])
        linkSignals.send([:])
    }
}
