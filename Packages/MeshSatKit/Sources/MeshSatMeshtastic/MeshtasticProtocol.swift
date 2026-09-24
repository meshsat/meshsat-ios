// Mirrors ble/MeshtasticProtocol.kt: the Meshtastic protocol facade. The data types every
// screen and the engine use, one parse of a FromRadio frame dispatched by variant and portnum,
// and the ToRadio encoders. The protobuf work itself is in MeshtasticProtoAdapter.swift, so
// the rest of the app never sees a generated type except where Android exposes one too
// (Config sections, ChannelSettings).
import Foundation
import MeshSatProto

public enum MeshtasticProtocol {
    // MARK: Port numbers, mirrored from the PortNum enum for convenience
    public static let portnumTextMessage = 1
    public static let portnumRemoteHardware = 2
    public static let portnumPosition = 3
    public static let portnumNodeinfo = 4
    public static let portnumRouting = 5
    public static let portnumAdminApp = 6
    public static let portnumTextCompressed = 7
    public static let portnumWaypoint = 8
    public static let portnumAudio = 9
    public static let portnumDetectionSensor = 10
    public static let portnumReply = 32
    public static let portnumPaxcounter = 34
    public static let portnumSerial = 64
    public static let portnumStoreForward = 65
    public static let portnumRangeTest = 66
    public static let portnumTelemetry = 67
    public static let portnumTraceroute = 70
    public static let portnumNeighborinfo = 71
    public static let portnumPrivateApp = 256

    /// The broadcast address.
    public static let broadcastNodeNum: UInt32 = 0xFFFF_FFFF

    /// want_config_id nonce that asks for the configuration only, without the node list
    /// (firmware PhoneAPI SPECIAL_NONCE_ONLY_CONFIG). Older firmware treats it as a normal
    /// want_config and sends everything, which is harmless.
    public static let wantConfigOnlyConfig: UInt32 = 69420

    // MARK: Unified FromRadio parser: single parse, dispatch by type

    /// What one FromRadio frame was. Android's FromRadioResult has one non-null field; here the
    /// case says which. `.unhandled` is a frame that parsed but carries nothing the app reads.
    public enum FromRadioResult: Sendable, Equatable {
        case textMessage(MeshTextMessage)
        case position(MeshPosition)
        case telemetry(MeshTelemetry)
        case environmentTelemetry(MeshEnvironmentTelemetry)
        case myInfo(MyNodeInfo)
        case nodeInfo(MeshNodeInfo)
        case routing(MeshRouting)
        case waypoint(MeshWaypoint)
        case neighborInfo(MeshNeighborInfo)
        case traceroute(MeshTraceroute)
        case storeForward(MeshStoreForward)
        case rangeTest(MeshRangeTest)
        case detectionSensor(MeshDetectionSensor)
        case paxcounter(MeshPaxcounter)
        case reply(MeshReply)
        case channel(MeshChannel)
        case deviceMetadata(MeshDeviceMetadata)
        case configCompleteId(UInt32)
        case config(Meshtastic_Config)
        case unhandled
    }

    /// Parse raw FromRadio bytes into a `FromRadioResult`, parsing once and dispatching by
    /// variant and portnum. Nil when the bytes are not a FromRadio.
    public static func parseFromRadioFull(_ data: [UInt8], nowMs: Int64 = MeshtasticProtoAdapter.nowMs()) -> FromRadioResult? {
        guard let fromRadio = MeshtasticProtoAdapter.parseFromRadio(data) else { return nil }
        let a = MeshtasticProtoAdapter.self

        if let mi = a.extractMyInfo(fromRadio) { return .myInfo(mi) }
        if let ni = a.extractNodeInfo(fromRadio) { return .nodeInfo(ni) }
        if let ch = a.extractChannel(fromRadio) { return .channel(ch) }
        if let md = a.extractDeviceMetadata(fromRadio) { return .deviceMetadata(md) }
        if case .config(let config)? = fromRadio.payloadVariant { return .config(config) }
        if case .configCompleteID(let id)? = fromRadio.payloadVariant { return .configCompleteId(id) }

        guard let portnum = a.getPortnum(fromRadio) else { return .unhandled }
        return packetResult(fromRadio, portnum: portnum, nowMs: nowMs)
    }

    /// The packet variants, dispatched by portnum: a plain mirror of Android's `when`.
    private static func packetResult(_ fromRadio: Meshtastic_FromRadio, portnum: Meshtastic_PortNum, nowMs: Int64) -> FromRadioResult {
        let a = MeshtasticProtoAdapter.self
        switch portnum {
        case .textMessageApp:
            return a.extractTextMessage(fromRadio).map { .textMessage($0) } ?? .unhandled
        case .positionApp:
            return a.extractPosition(fromRadio, nowMs: nowMs).map { .position($0) } ?? .unhandled
        case .telemetryApp:
            if let env = a.extractEnvironmentTelemetry(fromRadio) { return .environmentTelemetry(env) }
            return a.extractTelemetry(fromRadio).map { .telemetry($0) } ?? .unhandled
        case .routingApp:
            return a.extractRouting(fromRadio).map { .routing($0) } ?? .unhandled
        case .waypointApp:
            return a.extractWaypoint(fromRadio).map { .waypoint($0) } ?? .unhandled
        case .neighborinfoApp:
            return a.extractNeighborInfo(fromRadio).map { .neighborInfo($0) } ?? .unhandled
        case .tracerouteApp:
            return a.extractTraceroute(fromRadio).map { .traceroute($0) } ?? .unhandled
        case .storeForwardApp:
            return a.extractStoreForward(fromRadio).map { .storeForward($0) } ?? .unhandled
        case .rangeTestApp:
            return a.extractRangeTest(fromRadio).map { .rangeTest($0) } ?? .unhandled
        case .detectionSensorApp:
            return a.extractDetectionSensor(fromRadio).map { .detectionSensor($0) } ?? .unhandled
        case .paxcounterApp:
            return a.extractPaxcounter(fromRadio).map { .paxcounter($0) } ?? .unhandled
        case .replyApp:
            return a.extractReply(fromRadio).map { .reply($0) } ?? .unhandled
        case .nodeinfoApp:
            // A node announcing itself on the air: the User is the packet's payload, not
            // FromRadio.node_info (MESHSAT-1287).
            return a.extractNodeInfoFromPacket(fromRadio, nowMs: nowMs).map { .nodeInfo($0) } ?? .unhandled
        default:
            return .unhandled
        }
    }

    // MARK: Single-purpose parsers, as Android's legacy methods

    public static func parseFromRadio(_ data: [UInt8]) -> MeshTextMessage? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractTextMessage)
    }

    public static func parsePositionFromRadio(_ data: [UInt8]) -> MeshPosition? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap { MeshtasticProtoAdapter.extractPosition($0) }
    }

    public static func parseMyInfo(_ data: [UInt8]) -> MyNodeInfo? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractMyInfo)
    }

    public static func parseNodeInfo(_ data: [UInt8]) -> MeshNodeInfo? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractNodeInfo)
    }

    public static func parseTelemetryFromRadio(_ data: [UInt8]) -> MeshTelemetry? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractTelemetry)
    }

    public static func parseRoutingFromRadio(_ data: [UInt8]) -> MeshRouting? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractRouting)
    }

    public static func parseWaypointFromRadio(_ data: [UInt8]) -> MeshWaypoint? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractWaypoint)
    }

    /// What one raw FromRadio frame says about mesh links: the over-the-air signal of its packet
    /// and, for a NEIGHBORINFO_APP packet, the neighbours it reports. Nil when it says nothing.
    public static func parseLinkObservation(_ data: [UInt8], nowMs: Int64 = MeshtasticProtoAdapter.nowMs()) -> LinkObservation? {
        guard let fromRadio = MeshtasticProtoAdapter.parseFromRadio(data) else { return nil }
        let signal = MeshtasticProtoAdapter.extractLinkSignal(fromRadio, nowMs: nowMs)
        let neighbors = MeshtasticProtoAdapter.extractNeighborInfo(fromRadio)
        if signal == nil && neighbors == nil { return nil }
        return LinkObservation(signal: signal, neighborInfo: neighbors)
    }

    public static func parseNeighborInfoFromRadio(_ data: [UInt8]) -> MeshNeighborInfo? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractNeighborInfo)
    }

    public static func parseTracerouteFromRadio(_ data: [UInt8]) -> MeshTraceroute? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractTraceroute)
    }

    public static func parseStoreForwardFromRadio(_ data: [UInt8]) -> MeshStoreForward? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractStoreForward)
    }

    public static func parseEnvironmentTelemetryFromRadio(_ data: [UInt8]) -> MeshEnvironmentTelemetry? {
        MeshtasticProtoAdapter.parseFromRadio(data).flatMap(MeshtasticProtoAdapter.extractEnvironmentTelemetry)
    }

    // MARK: Encoding

    /// Encode a text message as a ToRadio protobuf.
    public static func encodeTextMessage(_ text: String, to: UInt32 = broadcastNodeNum, channel: Int = 0) -> [UInt8] {
        MeshtasticProtoAdapter.encodeTextMessage(text, to: to, channel: channel)
    }

    /// Format a node number as Meshtastic does: "!27ca8f1c".
    public static func formatNodeId(_ num: UInt32) -> String {
        "!" + String(format: "%08x", num)
    }

    /// Request config from the radio.
    public static func encodeWantConfig(_ configId: UInt32 = 0) -> [UInt8] {
        MeshtasticProtoAdapter.encodeWantConfig(configId)
    }

    // Names for models the bundled proto predates or spells in a way people do not use.
    private static let hardwareNames: [Int: String] = [
        4: "LilyGO T-Beam",
        7: "LilyGO T-Echo",
        9: "RAK WisBlock 4631",
        12: "LilyGO T-Beam Supreme",
        43: "Heltec V3",
        44: "Heltec Wireless Stick Lite V3",
        48: "Heltec Wireless Tracker",
        50: "LilyGO T-Deck",
        51: "LilyGO T-Watch S3",
        65: "Heltec Capsule Sensor V3",
        69: "Heltec Mesh Node T114",
        71: "Seeed Card Tracker T1000-E",
        80: "M5Stack CoreS3",
        81: "Seeed XIAO ESP32-S3",
        88: "Seeed XIAO nRF52840 kit",
        89: "ThinkNode M1",
        90: "ThinkNode M2",
        94: "Heltec Mesh Pocket",
        95: "Seeed Solar Node",
        99: "Seeed Wio Tracker L1",
        102: "LilyGO T-Deck Pro",
        103: "LilyGO T-Lora Pager",
        110: "Heltec V4",
        255: "Custom hardware",
    ]

    /// The hardware model a node reports (User.hw_model), as a name people recognise. One
    /// mapping for every screen: "Unknown model (code N)" when neither this app nor its proto
    /// knows the code.
    public static func hardwareName(_ code: Int) -> String {
        if code == 0 { return "Unknown model" }
        if let name = hardwareNames[code] { return name }
        guard let known = MeshtasticProtoAdapter.hardwareModelName(code) else { return "Unknown model (code \(code))" }
        return known.split(separator: "_").map { word -> String in
            if word.contains(where: \.isNumber) || word.count <= 3 { return String(word) }
            return word.lowercased().prefix(1).uppercased() + word.lowercased().dropFirst()
        }.joined(separator: " ")
    }

    // MARK: Admin message encoding

    // Config section enum values (backward-compatible constants)
    public static let configDevice = 0
    public static let configPosition = 1
    public static let configPower = 2
    public static let configNetwork = 3
    public static let configDisplay = 4
    public static let configLora = 5
    public static let configBluetooth = 6
    public static let configSecurity = 7

    // ModuleConfig section enum values
    public static let moduleMqtt = 0
    public static let moduleSerial = 1
    public static let moduleExtNotification = 2
    public static let moduleStoreForward = 3
    public static let moduleRangeTest = 4
    public static let moduleTelemetry = 5
    public static let moduleCannedMessage = 6

    /// LoRa region codes (Meshtastic RegionCode enum).
    public enum LoRaRegion: Int, CaseIterable, Sendable {
        case unset = 0, us = 1, eu433 = 2, eu868 = 3, cn = 4, jp = 5, anz = 6, kr = 7, tw = 8, ru = 9, india = 10
        case nz865 = 11, th = 12, lora24 = 13, ua433 = 14, ua868 = 15, my433 = 16, my919 = 17, sg923 = 18

        public var code: Int { rawValue }

        public var label: String {
            switch self {
            case .unset: "Unset"
            case .us: "US"
            case .eu433: "EU 433"
            case .eu868: "EU 868"
            case .cn: "CN"
            case .jp: "JP"
            case .anz: "ANZ"
            case .kr: "KR"
            case .tw: "TW"
            case .ru: "RU"
            case .india: "IN"
            case .nz865: "NZ 865"
            case .th: "TH"
            case .lora24: "2.4 GHz"
            case .ua433: "UA 433"
            case .ua868: "UA 868"
            case .my433: "MY 433"
            case .my919: "MY 919"
            case .sg923: "SG 923"
            }
        }

        public static func fromCode(_ code: Int) -> LoRaRegion { LoRaRegion(rawValue: code) ?? .unset }
    }

    /// Modem preset codes (Meshtastic ModemPreset enum).
    public enum ModemPreset: Int, CaseIterable, Sendable {
        case longFast = 0, longSlow = 1, vLongSlow = 2, medSlow = 3, medFast = 4, shortSlow = 5, shortFast = 6
        case longMod = 7, shortTurbo = 8

        public var code: Int { rawValue }

        public var label: String {
            switch self {
            case .longFast: "Long Fast"
            case .longSlow: "Long Slow"
            case .vLongSlow: "Very Long Slow"
            case .medSlow: "Medium Slow"
            case .medFast: "Medium Fast"
            case .shortSlow: "Short Slow"
            case .shortFast: "Short Fast"
            case .longMod: "Long Moderate"
            case .shortTurbo: "Short Turbo"
            }
        }

        public static func fromCode(_ code: Int) -> ModemPreset { ModemPreset(rawValue: code) ?? .longFast }
    }

    public static func buildAdminGetConfig(myNodeNum: UInt32, configType: Int) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminGetConfig(myNodeNum: myNodeNum, configType: configType)
    }

    public static func buildAdminGetModuleConfig(myNodeNum: UInt32, moduleType: Int) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminGetModuleConfig(myNodeNum: myNodeNum, moduleType: moduleType)
    }

    /// Set a config section from raw Config bytes (legacy shape).
    public static func buildAdminSetConfig(myNodeNum: UInt32, configData: [UInt8]) throws -> [UInt8] {
        let config = try Meshtastic_Config(serializedBytes: configData)
        return MeshtasticProtoAdapter.buildAdminSetConfig(myNodeNum: myNodeNum, config: config)
    }

    /// Set a module config section from raw ModuleConfig bytes (legacy shape).
    public static func buildAdminSetModuleConfig(myNodeNum: UInt32, configData: [UInt8]) throws -> [UInt8] {
        let moduleConfig = try Meshtastic_ModuleConfig(serializedBytes: configData)
        return MeshtasticProtoAdapter.buildAdminSetModuleConfig(myNodeNum: myNodeNum, moduleConfig: moduleConfig)
    }

    public static func buildAdminReboot(myNodeNum: UInt32, delaySecs: Int) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminReboot(myNodeNum: myNodeNum, delaySecs: delaySecs)
    }

    public static func buildAdminShutdown(myNodeNum: UInt32, delaySecs: Int) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminShutdown(myNodeNum: myNodeNum, delaySecs: delaySecs)
    }

    public static func buildAdminFactoryReset(myNodeNum: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminFactoryReset(myNodeNum: myNodeNum)
    }

    public static func buildAdminNodeDbReset(myNodeNum: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminNodeDbReset(myNodeNum: myNodeNum)
    }

    public static func buildAdminGetDeviceMetadata(myNodeNum: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminGetDeviceMetadata(myNodeNum: myNodeNum)
    }

    public static func buildAdminSetTime(myNodeNum: UInt32, unixSec: Int64) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminSetTime(myNodeNum: myNodeNum, unixSec: unixSec)
    }

    public static func buildAdminSetOwner(myNodeNum: UInt32, longName: String, shortName: String, isLicensed: Bool = false) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminSetOwner(myNodeNum: myNodeNum, longName: longName, shortName: shortName, isLicensed: isLicensed)
    }

    public static func buildAdminSetChannel(myNodeNum: UInt32, channel: Meshtastic_Channel) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminSetChannel(myNodeNum: myNodeNum, channel: channel)
    }

    public static func buildAdminGetChannel(myNodeNum: UInt32, channelIndex: Int) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminGetChannel(myNodeNum: myNodeNum, channelIndex: channelIndex)
    }

    public static func buildAdminRemoveNode(myNodeNum: UInt32, nodeNum: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminRemoveNode(myNodeNum: myNodeNum, nodeNum: nodeNum)
    }

    public static func buildAdminBeginEditSettings(myNodeNum: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminBeginEditSettings(myNodeNum: myNodeNum)
    }

    public static func buildAdminCommitEditSettings(myNodeNum: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.buildAdminCommitEditSettings(myNodeNum: myNodeNum)
    }

    /// Encode a LoRa config as Config protobuf bytes (backward-compatible).
    public static func encodeLoRaConfig(region: Int, modemPreset: Int, txPower: Int, hopLimit: Int, txEnabled: Bool) -> [UInt8] {
        let config = MeshtasticProtoAdapter.encodeLoRaConfig(
            region: region, modemPreset: modemPreset, txPower: txPower, hopLimit: hopLimit, txEnabled: txEnabled)
        return MeshtasticProtoAdapter.bytes(of: config)
    }

    /// Encode a waypoint as a ToRadio protobuf.
    public static func encodeWaypoint(
        name: String, description: String, latitudeI: Int32, longitudeI: Int32, expire: Int64 = 0, icon: Int = 0,
        to: UInt32 = broadcastNodeNum, channel: Int = 0
    ) -> [UInt8] {
        MeshtasticProtoAdapter.encodeWaypoint(
            name: name, description: description, latitudeI: latitudeI, longitudeI: longitudeI, expire: expire, icon: icon,
            to: to, channel: channel)
    }

    /// Encode a traceroute request as a ToRadio protobuf.
    public static func encodeTracerouteRequest(myNodeNum: UInt32, destNode: UInt32) -> [UInt8] {
        MeshtasticProtoAdapter.encodeTracerouteRequest(myNodeNum: myNodeNum, destNode: destNode)
    }
}
