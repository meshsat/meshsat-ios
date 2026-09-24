// The data types of ble/MeshtasticProtocol.kt (its data classes), split from the facade so
// each file stays readable. See MeshtasticProtocol.swift for the parsers and encoders.
import Foundation
import MeshSatProto

extension MeshtasticProtocol {
    // MARK: Data types

    /// A decoded mesh text message.
    public struct MeshTextMessage: Sendable, Equatable {
        public var from: UInt32
        public var to: UInt32
        public var channel: Int
        public var portnum: Int
        public var text: String
        public var id: UInt32
        public init(from: UInt32, to: UInt32, channel: Int, portnum: Int, text: String, id: UInt32 = 0) {
            self.from = from
            self.to = to
            self.channel = channel
            self.portnum = portnum
            self.text = text
            self.id = id
        }
    }

    /// A decoded mesh position update.
    public struct MeshPosition: Sendable, Equatable {
        public var from: UInt32
        public var latitude: Double
        public var longitude: Double
        public var altitude: Int
        /// Milliseconds since the epoch.
        public var time: Int64
        public init(from: UInt32, latitude: Double, longitude: Double, altitude: Int, time: Int64) {
            self.from = from
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.time = time
        }
    }

    /// Telemetry from mesh (device metrics: battery level).
    public struct MeshTelemetry: Sendable, Equatable {
        public var from: UInt32
        public var batteryLevel: Int
        public var voltage: Float
        public init(from: UInt32, batteryLevel: Int = -1, voltage: Float = 0) {
            self.from = from
            self.batteryLevel = batteryLevel
            self.voltage = voltage
        }
    }

    /// Environment telemetry from mesh (temperature, humidity, pressure).
    public struct MeshEnvironmentTelemetry: Sendable, Equatable {
        public var from: UInt32
        public var temperature: Float
        public var relativeHumidity: Float
        public var barometricPressure: Float
        public var gasResistance: Float
        public init(
            from: UInt32, temperature: Float = 0, relativeHumidity: Float = 0, barometricPressure: Float = 0, gasResistance: Float = 0
        ) {
            self.from = from
            self.temperature = temperature
            self.relativeHumidity = relativeHumidity
            self.barometricPressure = barometricPressure
            self.gasResistance = gasResistance
        }
    }

    /// Node info from mesh. `snr` and `hopsAway` are what the radio's own node list says about
    /// the last packet it heard from the node: `hopsAway` 0 means heard directly, -1 means the
    /// radio does not know (the proto has no presence for hops_away, see the adapter).
    public struct MeshNodeInfo: Sendable, Equatable {
        public var nodeNum: UInt32
        public var longName: String
        public var shortName: String
        public var macaddr: String
        public var hwModel: Int
        public var batteryLevel: Int
        /// Milliseconds since the epoch, 0 when unknown.
        public var lastHeard: Int64
        public var snr: Float
        public var hopsAway: Int
        public var viaMqtt: Bool
        public var isLicensed: Bool
        public init(
            nodeNum: UInt32, longName: String = "", shortName: String = "", macaddr: String = "", hwModel: Int = 0,
            batteryLevel: Int = -1, lastHeard: Int64 = 0, snr: Float = 0, hopsAway: Int = -1, viaMqtt: Bool = false,
            isLicensed: Bool = false
        ) {
            self.nodeNum = nodeNum
            self.longName = longName
            self.shortName = shortName
            self.macaddr = macaddr
            self.hwModel = hwModel
            self.batteryLevel = batteryLevel
            self.lastHeard = lastHeard
            self.snr = snr
            self.hopsAway = hopsAway
            self.viaMqtt = viaMqtt
            self.isLicensed = isLicensed
        }

        /// Mirrors MeshtasticBle.addNodeInfo's merge: identity fields the update leaves empty
        /// are kept from what was known. Config downloads often send partial NodeInfo.
        public func merged(over existing: MeshNodeInfo?, nowMs: Int64) -> MeshNodeInfo {
            var out = self
            if longName.isEmpty { out.longName = existing?.longName ?? "" }
            if shortName.isEmpty { out.shortName = existing?.shortName ?? "" }
            if macaddr.isEmpty { out.macaddr = existing?.macaddr ?? "" }
            if hwModel == 0 { out.hwModel = existing?.hwModel ?? 0 }
            if batteryLevel < 0 { out.batteryLevel = existing?.batteryLevel ?? -1 }
            if lastHeard <= 0 { out.lastHeard = nowMs }
            if snr == 0 { out.snr = existing?.snr ?? 0 }
            if hopsAway < 0 { out.hopsAway = existing?.hopsAway ?? -1 }
            if longName.isEmpty { out.isLicensed = existing?.isLicensed ?? false }
            return out
        }
    }

    /// My node info (this radio's device info).
    public struct MyNodeInfo: Sendable, Equatable {
        public var myNodeNum: UInt32
        public var firmwareVersion: String
        public var rebootCount: Int
        public var minAppVersion: Int
        public init(myNodeNum: UInt32 = 0, firmwareVersion: String = "", rebootCount: Int = 0, minAppVersion: Int = 0) {
            self.myNodeNum = myNodeNum
            self.firmwareVersion = firmwareVersion
            self.rebootCount = rebootCount
            self.minAppVersion = minAppVersion
        }
    }

    /// Device metadata (firmware version, capabilities).
    public struct MeshDeviceMetadata: Sendable, Equatable {
        public var firmwareVersion: String
        public var canShutdown: Bool
        public var hasWifi: Bool
        public var hasBluetooth: Bool
        public var hasEthernet: Bool
        public var hwModel: Int
        public init(
            firmwareVersion: String = "", canShutdown: Bool = false, hasWifi: Bool = false, hasBluetooth: Bool = false,
            hasEthernet: Bool = false, hwModel: Int = 0
        ) {
            self.firmwareVersion = firmwareVersion
            self.canShutdown = canShutdown
            self.hasWifi = hasWifi
            self.hasBluetooth = hasBluetooth
            self.hasEthernet = hasEthernet
            self.hwModel = hwModel
        }
    }

    /// Routing info: ACK/NAK status for sent messages.
    public struct MeshRouting: Sendable, Equatable {
        public var from: UInt32
        public var requestId: UInt32
        public var errorReason: Int
        public var errorName: String
        public var isAck: Bool { errorReason == 0 }
        public var isNak: Bool { errorReason != 0 }
        public init(from: UInt32, requestId: UInt32, errorReason: Int, errorName: String) {
            self.from = from
            self.requestId = requestId
            self.errorReason = errorReason
            self.errorName = errorName
        }
    }

    /// Waypoint shared on the mesh.
    public struct MeshWaypoint: Sendable, Equatable {
        public var id: UInt32
        public var from: UInt32
        public var name: String
        public var description: String
        public var latitude: Double
        public var longitude: Double
        public var expire: Int64
        public var icon: Int
        public init(
            id: UInt32, from: UInt32, name: String, description: String, latitude: Double, longitude: Double, expire: Int64 = 0,
            icon: Int = 0
        ) {
            self.id = id
            self.from = from
            self.name = name
            self.description = description
            self.latitude = latitude
            self.longitude = longitude
            self.expire = expire
            self.icon = icon
        }
    }

    /// One node a NeighborInfo sender hears, and the SNR (dB) it hears it at.
    public struct MeshNeighbor: Sendable, Equatable {
        public var nodeId: UInt32
        public var snr: Float
        public init(nodeId: UInt32, snr: Float) {
            self.nodeId = nodeId
            self.snr = snr
        }
    }

    /// Neighbor info, mesh topology data: `nodeId` reports the nodes it hears directly.
    public struct MeshNeighborInfo: Sendable, Equatable {
        public var nodeId: UInt32
        public var neighbors: [MeshNeighbor]
        public var broadcastIntervalSecs: Int
        public init(nodeId: UInt32, neighbors: [MeshNeighbor], broadcastIntervalSecs: Int = 0) {
            self.nodeId = nodeId
            self.neighbors = neighbors
            self.broadcastIntervalSecs = broadcastIntervalSecs
        }
    }

    /// A NeighborInfo packet as the phone keeps it: who reported, whom it hears, and when it arrived.
    public struct NeighborReport: Sendable, Equatable {
        public var nodeId: UInt32
        public var neighbors: [MeshNeighbor]
        public var broadcastIntervalSecs: Int
        public var receivedAt: Int64
        public init(nodeId: UInt32, neighbors: [MeshNeighbor], broadcastIntervalSecs: Int, receivedAt: Int64) {
            self.nodeId = nodeId
            self.neighbors = neighbors
            self.broadcastIntervalSecs = broadcastIntervalSecs
            self.receivedAt = receivedAt
        }
    }

    /// How our radio heard the last packet from `from`, over the air: the signal of the last hop
    /// (`snr` in dB, `rssi` in dBm) and how many hops the packet had taken (`hopsAway`, -1 when
    /// the packet does not say, e.g. older firmware that sends no hop_start).
    public struct MeshLinkSignal: Sendable, Equatable {
        public var from: UInt32
        public var snr: Float
        public var rssi: Int
        public var hopsAway: Int
        public var heardAt: Int64
        public init(from: UInt32, snr: Float, rssi: Int, hopsAway: Int, heardAt: Int64) {
            self.from = from
            self.snr = snr
            self.rssi = rssi
            self.hopsAway = hopsAway
            self.heardAt = heardAt
        }
    }

    /// What one FromRadio frame says about links: the packet's signal, and a NeighborInfo if it is one.
    public struct LinkObservation: Sendable, Equatable {
        public var signal: MeshLinkSignal?
        public var neighborInfo: MeshNeighborInfo?
        public init(signal: MeshLinkSignal?, neighborInfo: MeshNeighborInfo?) {
            self.signal = signal
            self.neighborInfo = neighborInfo
        }
    }

    /// Traceroute result.
    public struct MeshTraceroute: Sendable, Equatable {
        public var from: UInt32
        public var requestId: UInt32
        public var route: [UInt32]
        public var snrTowards: [Int]
        public var snrBack: [Int]
        public init(from: UInt32, requestId: UInt32, route: [UInt32], snrTowards: [Int], snrBack: [Int]) {
            self.from = from
            self.requestId = requestId
            self.route = route
            self.snrTowards = snrTowards
            self.snrBack = snrBack
        }
    }

    /// Store-and-forward message from a relay node.
    public struct MeshStoreForward: Sendable, Equatable {
        public var from: UInt32
        public var requestResponse: Int
        public var requestResponseName: String
        public var text: String?
        public var messagesTotal: Int
        public var messagesSaved: Int
        public init(
            from: UInt32, requestResponse: Int, requestResponseName: String, text: String? = nil, messagesTotal: Int = 0,
            messagesSaved: Int = 0
        ) {
            self.from = from
            self.requestResponse = requestResponse
            self.requestResponseName = requestResponseName
            self.text = text
            self.messagesTotal = messagesTotal
            self.messagesSaved = messagesSaved
        }
    }

    /// Range test data.
    public struct MeshRangeTest: Sendable, Equatable {
        public var from: UInt32
        public var payload: String
        public var rxSnr: Float
        public var rxRssi: Int
        public init(from: UInt32, payload: String, rxSnr: Float = 0, rxRssi: Int = 0) {
            self.from = from
            self.payload = payload
            self.rxSnr = rxSnr
            self.rxRssi = rxRssi
        }
    }

    /// Detection sensor alert.
    public struct MeshDetectionSensor: Sendable, Equatable {
        public var from: UInt32
        public var name: String
        public init(from: UInt32, name: String) {
            self.from = from
            self.name = name
        }
    }

    /// Paxcounter data.
    public struct MeshPaxcounter: Sendable, Equatable {
        public var from: UInt32
        public init(from: UInt32) { self.from = from }
    }

    /// Reply / emoji reaction.
    public struct MeshReply: Sendable, Equatable {
        public var from: UInt32
        public var to: UInt32
        public var payload: String
        public var emoji: Int
        public init(from: UInt32, to: UInt32, payload: String, emoji: Int = 0) {
            self.from = from
            self.to = to
            self.payload = payload
            self.emoji = emoji
        }
    }

    /// Channel configuration from the radio. `settings` is the radio's own ChannelSettings, kept
    /// so an edit changes only what the user changed (position precision, id and the rest ride
    /// along). Every field counts in equality: with only index, name and role, the channels
    /// state swallowed a re-read that changed the key or the MQTT switches.
    public struct MeshChannel: Sendable, Equatable {
        public var index: Int
        public var name: String
        public var role: Int
        public var psk: [UInt8]
        public var uplinkEnabled: Bool
        public var downlinkEnabled: Bool
        public var settings: Meshtastic_ChannelSettings?
        public init(
            index: Int, name: String, role: Int, psk: [UInt8], uplinkEnabled: Bool = false, downlinkEnabled: Bool = false,
            settings: Meshtastic_ChannelSettings? = nil
        ) {
            self.index = index
            self.name = name
            self.role = role
            self.psk = psk
            self.uplinkEnabled = uplinkEnabled
            self.downlinkEnabled = downlinkEnabled
            self.settings = settings
        }
    }
}
