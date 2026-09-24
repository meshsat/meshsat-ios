// Mirrors ble/MeshtasticProtoAdapter.kt: the adapter between the generated Meshtastic protobuf
// types (MeshSatProto, `Meshtastic_*`) and the facade's data types, so the rest of the app is
// decoupled from the raw protobuf API.
import Foundation
import MeshSatProto
import SwiftProtobuf

public enum MeshtasticProtoAdapter {
    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: FromRadio parsing

    /// Parse raw FromRadio bytes, or nil when they are not one.
    public static func parseFromRadio(_ data: [UInt8]) -> Meshtastic_FromRadio? {
        try? Meshtastic_FromRadio(serializedBytes: data)
    }

    /// The packet's decoded Data, when the frame is a packet the radio could decrypt.
    static func decoded(_ fromRadio: Meshtastic_FromRadio) -> (pkt: Meshtastic_MeshPacket, data: Meshtastic_Data)? {
        guard case .packet(let pkt)? = fromRadio.payloadVariant else { return nil }
        guard case .decoded(let data)? = pkt.payloadVariant else { return nil }
        return (pkt, data)
    }

    static func decodedPacket(_ fromRadio: Meshtastic_FromRadio, port: Meshtastic_PortNum) -> (
        pkt: Meshtastic_MeshPacket, data: Meshtastic_Data
    )? {
        guard let d = decoded(fromRadio), d.data.portnum == port else { return nil }
        return d
    }

    static func utf8(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    static func macString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func extractTextMessage(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshTextMessage? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .textMessageApp) else { return nil }
        return MeshtasticProtocol.MeshTextMessage(
            from: pkt.from, to: pkt.to, channel: Int(pkt.channel), portnum: data.portnum.rawValue,
            text: utf8(data.payload), id: pkt.id)
    }

    public static func extractPosition(_ fromRadio: Meshtastic_FromRadio, nowMs: Int64 = nowMs()) -> MeshtasticProtocol.MeshPosition? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .positionApp) else { return nil }
        guard let pos = try? Meshtastic_Position(serializedBytes: data.payload) else { return nil }
        // Skip zero positions (no GPS fix)
        if pos.latitudeI == 0 && pos.longitudeI == 0 { return nil }
        return MeshtasticProtocol.MeshPosition(
            from: pkt.from, latitude: Double(pos.latitudeI) / 1e7, longitude: Double(pos.longitudeI) / 1e7,
            altitude: Int(pos.altitude), time: pos.time != 0 ? Int64(pos.time) * 1000 : nowMs)
    }

    public static func extractTelemetry(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshTelemetry? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .telemetryApp) else { return nil }
        guard let telemetry = try? Meshtastic_Telemetry(serializedBytes: data.payload) else { return nil }
        guard case .deviceMetrics(let dm)? = telemetry.variant else {
            return MeshtasticProtocol.MeshTelemetry(from: pkt.from)
        }
        return MeshtasticProtocol.MeshTelemetry(from: pkt.from, batteryLevel: Int(dm.batteryLevel), voltage: dm.voltage)
    }

    public static func extractEnvironmentTelemetry(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshEnvironmentTelemetry? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .telemetryApp) else { return nil }
        guard let telemetry = try? Meshtastic_Telemetry(serializedBytes: data.payload) else { return nil }
        guard case .environmentMetrics(let em)? = telemetry.variant else { return nil }
        return MeshtasticProtocol.MeshEnvironmentTelemetry(
            from: pkt.from, temperature: em.temperature, relativeHumidity: em.relativeHumidity,
            barometricPressure: em.barometricPressure, gasResistance: em.gasResistance)
    }

    public static func extractMyInfo(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MyNodeInfo? {
        guard case .myInfo(let mi)? = fromRadio.payloadVariant else { return nil }
        // firmware_version left MyNodeInfo in recent protos; it comes with DeviceMetadata.
        return MeshtasticProtocol.MyNodeInfo(
            myNodeNum: mi.myNodeNum, firmwareVersion: "", rebootCount: Int(mi.rebootCount), minAppVersion: Int(mi.minAppVersion))
    }

    /// NodeInfo from the radio's own node list. hops_away has no presence in the bundled proto
    /// (upstream made it optional), so 0 reads the same as "not known". The firmware keeps the
    /// SNR of the last packet it heard from the node, so 0 hops together with a non-zero SNR,
    /// not via MQTT, is taken as heard directly; 0 hops with no SNR is reported as unknown (-1)
    /// rather than guessed.
    public static func extractNodeInfo(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshNodeInfo? {
        guard case .nodeInfo(let ni)? = fromRadio.payloadVariant else { return nil }
        let user: Meshtastic_User? = ni.hasUser ? ni.user : nil
        let hopsAway: Int
        if ni.hopsAway > 0 {
            hopsAway = Int(ni.hopsAway)
        } else if ni.snr != 0 && !ni.viaMqtt {
            hopsAway = 0
        } else {
            hopsAway = -1
        }
        return MeshtasticProtocol.MeshNodeInfo(
            nodeNum: ni.num,
            longName: user?.longName ?? "",
            shortName: user?.shortName ?? "",
            macaddr: user.map { macString($0.macaddr) } ?? "",
            hwModel: user?.hwModel.rawValue ?? 0,
            batteryLevel: ni.hasDeviceMetrics ? Int(ni.deviceMetrics.batteryLevel) : -1,
            lastHeard: ni.lastHeard != 0 ? Int64(ni.lastHeard) * 1000 : 0,
            snr: ni.snr,
            hopsAway: hopsAway,
            viaMqtt: ni.viaMqtt,
            isLicensed: user?.isLicensed ?? false)
    }

    /// A node announcing itself over the air (MESHSAT-1287): a NODEINFO_APP packet whose
    /// payload is the sender's User. A different shape from `extractNodeInfo`, which reads the
    /// node list the radio hands over at connect. Only the identity is known here; the merge in
    /// the radio state keeps the rest.
    public static func extractNodeInfoFromPacket(_ fromRadio: Meshtastic_FromRadio, nowMs: Int64 = nowMs()) -> MeshtasticProtocol
        .MeshNodeInfo?
    {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .nodeinfoApp) else { return nil }
        guard let user = try? Meshtastic_User(serializedBytes: data.payload) else { return nil }
        if user.longName.isEmpty && user.shortName.isEmpty { return nil }
        return MeshtasticProtocol.MeshNodeInfo(
            nodeNum: pkt.from, longName: user.longName, shortName: user.shortName, macaddr: macString(user.macaddr),
            hwModel: user.hwModel.rawValue, batteryLevel: -1, lastHeard: nowMs, snr: pkt.rxSnr, hopsAway: -1,
            viaMqtt: pkt.viaMqtt, isLicensed: user.isLicensed)
    }

    /// Ask `destNode` who it is: our own User, sent to it with want_response, which is how
    /// Meshtastic exchanges names. Without it a name arrives only with the node's own
    /// announcement, every three hours on this mesh.
    public static func encodeNodeInfoRequest(myNodeNum: UInt32, destNode: UInt32, longName: String, shortName: String) -> [UInt8] {
        var me = Meshtastic_User()
        me.id = MeshtasticProtocol.formatNodeId(myNodeNum)
        me.longName = longName
        me.shortName = shortName
        var data = Meshtastic_Data()
        data.portnum = .nodeinfoApp
        data.payload = bytesData(of: me)
        data.wantResponse = true
        var pkt = Meshtastic_MeshPacket()
        pkt.from = myNodeNum
        pkt.to = destNode
        pkt.decoded = data
        pkt.hopLimit = 3
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = pkt
        return bytes(of: toRadio)
    }

    /// How our radio heard this packet over the air, or nil when it did not: a packet that came
    /// through MQTT, or one with no receive metrics at all (our own node's packets, and anything
    /// the radio did not receive by LoRa, carry rx_snr 0 and rx_rssi 0). hop_start is set by the
    /// sender; hop_start - hop_limit is how many times it was relayed, 0 meaning our radio heard
    /// the sender itself. Without hop_start (older firmware) the hop count is unknown (-1).
    public static func extractLinkSignal(_ fromRadio: Meshtastic_FromRadio, nowMs: Int64 = nowMs()) -> MeshtasticProtocol.MeshLinkSignal? {
        guard case .packet(let pkt)? = fromRadio.payloadVariant else { return nil }
        if pkt.viaMqtt { return nil }
        if pkt.rxSnr == 0 && pkt.rxRssi == 0 { return nil }
        if pkt.from == 0 { return nil }
        let hopStart = pkt.hopStart
        let hopLimit = pkt.hopLimit
        let hops = (hopStart > 0 && hopLimit <= hopStart) ? Int(hopStart - hopLimit) : -1
        return MeshtasticProtocol.MeshLinkSignal(from: pkt.from, snr: pkt.rxSnr, rssi: Int(pkt.rxRssi), hopsAway: hops, heardAt: nowMs)
    }

    public static func extractDeviceMetadata(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshDeviceMetadata? {
        guard case .metadata(let md)? = fromRadio.payloadVariant else { return nil }
        return MeshtasticProtocol.MeshDeviceMetadata(
            firmwareVersion: md.firmwareVersion, canShutdown: md.canShutdown, hasWifi: md.hasWifi_p,
            hasBluetooth: md.hasBluetooth_p, hasEthernet: md.hasEthernet_p, hwModel: md.hwModel.rawValue)
    }

    public static func extractRouting(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshRouting? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .routingApp) else { return nil }
        guard let routing = try? Meshtastic_Routing(serializedBytes: data.payload) else { return nil }
        var reason = 0
        var name = "NONE"
        if case .errorReason(let err)? = routing.variant {
            reason = err.rawValue
            name = enumName(of: err, in: routing, field: "error_reason") ?? "UNKNOWN"
        }
        return MeshtasticProtocol.MeshRouting(from: pkt.from, requestId: data.requestID, errorReason: reason, errorName: name)
    }

    public static func extractWaypoint(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshWaypoint? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .waypointApp) else { return nil }
        guard let wp = try? Meshtastic_Waypoint(serializedBytes: data.payload) else { return nil }
        return MeshtasticProtocol.MeshWaypoint(
            id: wp.id, from: pkt.from, name: wp.name, description: wp.description_p, latitude: Double(wp.latitudeI) / 1e7,
            longitude: Double(wp.longitudeI) / 1e7, expire: Int64(wp.expire), icon: Int(wp.icon))
    }

    public static func extractNeighborInfo(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshNeighborInfo? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .neighborinfoApp) else { return nil }
        guard let ni = try? Meshtastic_NeighborInfo(serializedBytes: data.payload) else { return nil }
        // node_id is the reporter; fall back to the packet's sender if a firmware leaves it out.
        let reporter = ni.nodeID != 0 ? ni.nodeID : pkt.from
        return MeshtasticProtocol.MeshNeighborInfo(
            nodeId: reporter,
            neighbors: ni.neighbors.filter { $0.nodeID != 0 }.map { MeshtasticProtocol.MeshNeighbor(nodeId: $0.nodeID, snr: $0.snr) },
            broadcastIntervalSecs: Int(ni.nodeBroadcastIntervalSecs))
    }

    public static func extractTraceroute(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshTraceroute? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .tracerouteApp) else { return nil }
        guard let rd = try? Meshtastic_RouteDiscovery(serializedBytes: data.payload) else { return nil }
        return MeshtasticProtocol.MeshTraceroute(
            from: pkt.from, requestId: data.requestID, route: rd.route, snrTowards: rd.snrTowards.map(Int.init),
            snrBack: rd.snrBack.map(Int.init))
    }

    public static func extractStoreForward(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshStoreForward? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .storeForwardApp) else { return nil }
        guard let sf = try? Meshtastic_StoreAndForward(serializedBytes: data.payload) else { return nil }
        var text: String?
        var total = 0
        var saved = 0
        switch sf.variant {
        case .text(let t)?: text = utf8(t)
        case .stats(let s)?:
            total = Int(s.messagesTotal)
            saved = Int(s.messagesSaved)
        default: break
        }
        return MeshtasticProtocol.MeshStoreForward(
            from: pkt.from, requestResponse: sf.rr.rawValue, requestResponseName: enumName(of: sf.rr, in: sf, field: "rr") ?? "UNKNOWN",
            text: text, messagesTotal: total, messagesSaved: saved)
    }

    public static func extractRangeTest(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshRangeTest? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .rangeTestApp) else { return nil }
        return MeshtasticProtocol.MeshRangeTest(from: pkt.from, payload: utf8(data.payload), rxSnr: pkt.rxSnr, rxRssi: Int(pkt.rxRssi))
    }

    public static func extractDetectionSensor(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshDetectionSensor? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .detectionSensorApp) else { return nil }
        return MeshtasticProtocol.MeshDetectionSensor(from: pkt.from, name: utf8(data.payload))
    }

    public static func extractPaxcounter(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshPaxcounter? {
        guard let (pkt, _) = decodedPacket(fromRadio, port: .paxcounterApp) else { return nil }
        return MeshtasticProtocol.MeshPaxcounter(from: pkt.from)
    }

    public static func extractReply(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshReply? {
        guard let (pkt, data) = decodedPacket(fromRadio, port: .replyApp) else { return nil }
        return MeshtasticProtocol.MeshReply(from: pkt.from, to: pkt.to, payload: utf8(data.payload), emoji: Int(data.emoji))
    }

    /// The raw portnum of a FromRadio packet, or nil if it is not a decoded mesh packet.
    public static func getPortnum(_ fromRadio: Meshtastic_FromRadio) -> Meshtastic_PortNum? {
        decoded(fromRadio)?.data.portnum
    }

    public static func extractChannel(_ fromRadio: Meshtastic_FromRadio) -> MeshtasticProtocol.MeshChannel? {
        guard case .channel(let ch)? = fromRadio.payloadVariant else { return nil }
        let settings: Meshtastic_ChannelSettings? = ch.hasSettings ? ch.settings : nil
        return MeshtasticProtocol.MeshChannel(
            index: Int(ch.index), name: settings?.name ?? "",
            // rawValue, never a switch over known cases: a role this proto does not know must not throw.
            role: ch.role.rawValue, psk: settings.map { [UInt8]($0.psk) } ?? [],
            uplinkEnabled: settings?.uplinkEnabled ?? false, downlinkEnabled: settings?.downlinkEnabled ?? false,
            settings: settings)
    }

    // MARK: ToRadio encoding

    public static func encodeTextMessage(_ text: String, to: UInt32 = MeshtasticProtocol.broadcastNodeNum, channel: Int = 0) -> [UInt8] {
        var data = Meshtastic_Data()
        data.portnum = .textMessageApp
        data.payload = Data(text.utf8)
        var pkt = Meshtastic_MeshPacket()
        pkt.to = to
        pkt.channel = UInt32(channel)
        pkt.decoded = data
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = pkt
        return bytes(of: toRadio)
    }

    public static func encodeWaypoint(
        name: String, description: String, latitudeI: Int32, longitudeI: Int32, expire: Int64 = 0, icon: Int = 0,
        to: UInt32 = MeshtasticProtocol.broadcastNodeNum, channel: Int = 0
    ) -> [UInt8] {
        var wp = Meshtastic_Waypoint()
        wp.name = name
        wp.description_p = description
        wp.latitudeI = latitudeI
        wp.longitudeI = longitudeI
        wp.expire = UInt32(truncatingIfNeeded: expire)
        wp.icon = UInt32(icon)
        var data = Meshtastic_Data()
        data.portnum = .waypointApp
        data.payload = bytesData(of: wp)
        var pkt = Meshtastic_MeshPacket()
        pkt.to = to
        pkt.channel = UInt32(channel)
        pkt.decoded = data
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = pkt
        return bytes(of: toRadio)
    }

    public static func encodeTracerouteRequest(myNodeNum: UInt32, destNode: UInt32) -> [UInt8] {
        var data = Meshtastic_Data()
        data.portnum = .tracerouteApp
        data.payload = bytesData(of: Meshtastic_RouteDiscovery())
        data.wantResponse = true
        var pkt = Meshtastic_MeshPacket()
        pkt.from = myNodeNum
        pkt.to = destNode
        pkt.decoded = data
        pkt.hopLimit = 7
        pkt.wantAck = true
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = pkt
        return bytes(of: toRadio)
    }

    /// Request config from the radio (want_config_id).
    public static func encodeWantConfig(_ configId: UInt32 = 0) -> [UInt8] {
        var toRadio = Meshtastic_ToRadio()
        toRadio.wantConfigID = configId
        return bytes(of: toRadio)
    }

    // MARK: Admin message encoding

    public static func buildAdminGetConfig(myNodeNum: UInt32, configType: Int) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.getConfigRequest = Meshtastic_AdminMessage.ConfigType(rawValue: configType) ?? .deviceConfig
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminGetModuleConfig(myNodeNum: UInt32, moduleType: Int) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.getModuleConfigRequest = Meshtastic_AdminMessage.ModuleConfigType(rawValue: moduleType) ?? .mqttConfig
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminSetConfig(myNodeNum: UInt32, config: Meshtastic_Config) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.setConfig = config
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminSetModuleConfig(myNodeNum: UInt32, moduleConfig: Meshtastic_ModuleConfig) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.setModuleConfig = moduleConfig
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminSetChannel(myNodeNum: UInt32, channel: Meshtastic_Channel) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.setChannel = channel
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminGetChannel(myNodeNum: UInt32, channelIndex: Int) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.getChannelRequest = UInt32(channelIndex)
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminReboot(myNodeNum: UInt32, delaySecs: Int) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.rebootSeconds = Int32(delaySecs)
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminShutdown(myNodeNum: UInt32, delaySecs: Int) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.shutdownSeconds = Int32(delaySecs)
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminFactoryReset(myNodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.factoryResetDevice = 1
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminNodeDbReset(myNodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.nodedbReset = 1
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminFactoryResetConfig(myNodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.factoryResetConfig = 1
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminGetDeviceMetadata(myNodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.getDeviceMetadataRequest = true
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminSetTime(myNodeNum: UInt32, unixSec: Int64) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.setTimeOnly = UInt32(truncatingIfNeeded: unixSec)
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminSetOwner(myNodeNum: UInt32, longName: String, shortName: String, isLicensed: Bool = false) -> [UInt8] {
        var user = Meshtastic_User()
        user.longName = longName
        user.shortName = shortName
        user.isLicensed = isLicensed
        var admin = Meshtastic_AdminMessage()
        admin.setOwner = user
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminRemoveNode(myNodeNum: UInt32, nodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.removeByNodenum = nodeNum
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminSetFavoriteNode(myNodeNum: UInt32, nodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.setFavoriteNode = nodeNum
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    /// Any admin message, addressed to our own node (MESHSAT-1285).
    public static func buildAdmin(myNodeNum: UInt32, admin: Meshtastic_AdminMessage) -> [UInt8] {
        wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminBeginEditSettings(myNodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.beginEditSettings = true
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func buildAdminCommitEditSettings(myNodeNum: UInt32) -> [UInt8] {
        var admin = Meshtastic_AdminMessage()
        admin.commitEditSettings = true
        return wrapAdminToRadio(myNodeNum: myNodeNum, destNode: myNodeNum, admin: admin)
    }

    public static func encodeLoRaConfig(region: Int, modemPreset: Int, txPower: Int, hopLimit: Int, txEnabled: Bool) -> Meshtastic_Config {
        var lora = Meshtastic_Config.LoRaConfig()
        lora.region = Meshtastic_Config.LoRaConfig.RegionCode(rawValue: region) ?? .unset
        lora.modemPreset = Meshtastic_Config.LoRaConfig.ModemPreset(rawValue: modemPreset) ?? .longFast
        lora.txPower = Int32(txPower)
        lora.hopLimit = UInt32(hopLimit)
        lora.txEnabled = txEnabled
        var config = Meshtastic_Config()
        config.lora = lora
        return config
    }

    static func wrapAdminToRadio(myNodeNum: UInt32, destNode: UInt32, admin: Meshtastic_AdminMessage) -> [UInt8] {
        var data = Meshtastic_Data()
        data.portnum = .adminApp
        data.payload = bytesData(of: admin)
        data.wantResponse = true
        var pkt = Meshtastic_MeshPacket()
        pkt.from = myNodeNum
        pkt.to = destNode
        pkt.decoded = data
        pkt.hopLimit = 3
        pkt.wantAck = true
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = pkt
        return bytes(of: toRadio)
    }

    // MARK: Bytes and names

    /// Serialising a message built from scratch cannot fail; an empty array would be a bug.
    public static func bytes<M: SwiftProtobuf.Message>(of message: M) -> [UInt8] {
        (try? message.serializedBytes()) ?? []
    }

    static func bytesData<M: SwiftProtobuf.Message>(of message: M) -> Data {
        (try? message.serializedBytes()) ?? Data()
    }

    /// The proto name of an enum value ("CLIENT_MUTE", "HELTEC_V3"), through the text format,
    /// which is the one public way swift-protobuf spells enum names. `message` must carry the
    /// value in `field`. Nil for a value the bundled proto does not know.
    static func enumName<E: SwiftProtobuf.Enum, M: SwiftProtobuf.Message>(of value: E, in message: M, field: String) -> String? {
        if case .some = Optional(value), String(describing: value).hasPrefix("UNRECOGNIZED") { return nil }
        for line in message.textFormatString().split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(field + ": ") {
                let name = trimmed.dropFirst(field.count + 2)
                return name.first?.isNumber == true ? nil : String(name)
            }
        }
        return nil
    }

    /// The proto name of a HardwareModel code, e.g. 43 -> "HELTEC_V3"; nil when unknown.
    public static func hardwareModelName(_ code: Int) -> String? {
        guard let model = Meshtastic_HardwareModel(rawValue: code) else { return nil }
        var user = Meshtastic_User()
        user.hwModel = model
        return enumName(of: model, in: user, field: "hw_model")
    }

    /// The enum value whose proto name is `name`, e.g. "CLIENT_MUTE", through the text format
    /// decoder; nil when the proto has no such name.
    static func enumValue<E: SwiftProtobuf.Enum & Equatable, M: SwiftProtobuf.Message>(
        named name: String, field: String, in prototype: M, read: (M) -> E
    ) -> E? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !name.isEmpty else { return nil }
        guard let parsed = try? M(textFormatString: "\(field): \(name)") else { return nil }
        _ = prototype
        return read(parsed)
    }
}
