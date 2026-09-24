// The facade's parse and encode paths against frames built with the generated protos: what
// Android's MeshtasticProtocol does with each FromRadio variant and portnum.
import MeshSatMeshtastic
import MeshSatProto
import SwiftProtobuf
import XCTest

final class MeshtasticProtocolTests: XCTestCase {
    /// A message's bytes; one built from scratch always serialises.
    private func wire<M: SwiftProtobuf.Message>(_ m: M) -> Data { (try? m.serializedBytes()) ?? Data() }

    private func frame(_ build: (inout Meshtastic_FromRadio) -> Void) -> [UInt8] {
        var fr = Meshtastic_FromRadio()
        build(&fr)
        return (try? fr.serializedBytes()) ?? []
    }

    private func packet(from: UInt32 = 0x1234_5678, to: UInt32 = 0xFFFF_FFFF, port: Meshtastic_PortNum, payload: Data, id: UInt32 = 77)
        -> Meshtastic_MeshPacket
    {
        var data = Meshtastic_Data()
        data.portnum = port
        data.payload = payload
        var pkt = Meshtastic_MeshPacket()
        pkt.from = from
        pkt.to = to
        pkt.id = id
        pkt.channel = 2
        pkt.decoded = data
        pkt.rxSnr = 8.25
        pkt.rxRssi = -91
        pkt.hopStart = 3
        pkt.hopLimit = 2
        return pkt
    }

    func testTextMessage() {
        let bytes = frame { $0.packet = packet(port: .textMessageApp, payload: Data("hello mesh".utf8)) }
        guard case .textMessage(let m)? = MeshtasticProtocol.parseFromRadioFull(bytes) else { return XCTFail("not text") }
        XCTAssertEqual(m.from, 0x1234_5678)
        XCTAssertEqual(m.to, 0xFFFF_FFFF)
        XCTAssertEqual(m.channel, 2)
        XCTAssertEqual(m.portnum, MeshtasticProtocol.portnumTextMessage)
        XCTAssertEqual(m.text, "hello mesh")
        XCTAssertEqual(m.id, 77)
        XCTAssertEqual(MeshtasticProtocol.parseFromRadio(bytes)?.text, "hello mesh")
    }

    func testPositionAndZeroPositionIsNoFix() throws {
        var pos = Meshtastic_Position()
        pos.latitudeI = 521_234_567
        pos.longitudeI = 47_654_321
        pos.altitude = 12
        pos.time = 1_700_000_000
        let bytes = frame { $0.packet = packet(port: .positionApp, payload: wire(pos)) }
        guard case .position(let p)? = MeshtasticProtocol.parseFromRadioFull(bytes) else { return XCTFail("not position") }
        XCTAssertEqual(p.latitude, 52.1234567, accuracy: 1e-9)
        XCTAssertEqual(p.longitude, 4.7654321, accuracy: 1e-9)
        XCTAssertEqual(p.altitude, 12)
        XCTAssertEqual(p.time, 1_700_000_000_000)
        let zero = frame { $0.packet = packet(port: .positionApp, payload: wire(Meshtastic_Position())) }
        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(zero), .unhandled)
    }

    func testTelemetryDeviceAndEnvironment() throws {
        var t = Meshtastic_Telemetry()
        t.deviceMetrics.batteryLevel = 82
        t.deviceMetrics.voltage = 3.98
        let dev = frame { $0.packet = packet(port: .telemetryApp, payload: wire(t)) }
        guard case .telemetry(let d)? = MeshtasticProtocol.parseFromRadioFull(dev) else { return XCTFail("not telemetry") }
        XCTAssertEqual(d.batteryLevel, 82)
        XCTAssertEqual(d.voltage, 3.98, accuracy: 0.001)

        var e = Meshtastic_Telemetry()
        e.environmentMetrics.temperature = 21.5
        e.environmentMetrics.relativeHumidity = 40
        let env = frame { $0.packet = packet(port: .telemetryApp, payload: wire(e)) }
        guard case .environmentTelemetry(let em)? = MeshtasticProtocol.parseFromRadioFull(env) else { return XCTFail("not env") }
        XCTAssertEqual(em.temperature, 21.5)
        XCTAssertEqual(em.relativeHumidity, 40)
    }

    func testMyInfoNodeInfoChannelMetadataConfigAndComplete() {
        let my = frame {
            $0.myInfo.myNodeNum = 0xbf6e_e7bc
            $0.myInfo.rebootCount = 4
        }
        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(my), .myInfo(.init(myNodeNum: 0xbf6e_e7bc, rebootCount: 4)))

        let node = frame {
            $0.nodeInfo.num = 0x4370_c1d8
            $0.nodeInfo.user.longName = "MeshSat tesseract"
            $0.nodeInfo.user.shortName = "TESS"
            $0.nodeInfo.user.hwModel = .tbeam
            $0.nodeInfo.user.macaddr = Data([0xAA, 0xBB, 0xCC])
            $0.nodeInfo.snr = 6.5
            $0.nodeInfo.lastHeard = 1_700_000_000
            $0.nodeInfo.deviceMetrics.batteryLevel = 55
        }
        guard case .nodeInfo(let ni)? = MeshtasticProtocol.parseFromRadioFull(node) else { return XCTFail("not node info") }
        XCTAssertEqual(ni.nodeNum, 0x4370_c1d8)
        XCTAssertEqual(ni.longName, "MeshSat tesseract")
        XCTAssertEqual(ni.macaddr, "aa:bb:cc")
        XCTAssertEqual(ni.hwModel, 4)
        XCTAssertEqual(ni.batteryLevel, 55)
        XCTAssertEqual(ni.lastHeard, 1_700_000_000_000)
        XCTAssertEqual(ni.hopsAway, 0, "SNR without MQTT is heard directly")

        let quiet = frame { $0.nodeInfo.num = 9 }
        guard case .nodeInfo(let q)? = MeshtasticProtocol.parseFromRadioFull(quiet) else { return XCTFail("not node info") }
        XCTAssertEqual(q.hopsAway, -1, "no SNR: unknown, never guessed")
        XCTAssertEqual(q.batteryLevel, -1)

        let ch = frame {
            $0.channel.index = 1
            $0.channel.role = .secondary
            $0.channel.settings.name = "msat"
            $0.channel.settings.psk = Data([1])
            $0.channel.settings.uplinkEnabled = true
        }
        guard case .channel(let c)? = MeshtasticProtocol.parseFromRadioFull(ch) else { return XCTFail("not channel") }
        XCTAssertEqual(c.index, 1)
        XCTAssertEqual(c.role, 2)
        XCTAssertEqual(c.name, "msat")
        XCTAssertEqual(c.psk, [1])
        XCTAssertTrue(c.uplinkEnabled)
        XCTAssertNotNil(c.settings)

        let md = frame {
            $0.metadata.firmwareVersion = "2.8.0"
            $0.metadata.hasBluetooth_p = true
            $0.metadata.hwModel = .heltecV3
        }
        XCTAssertEqual(
            MeshtasticProtocol.parseFromRadioFull(md), .deviceMetadata(.init(firmwareVersion: "2.8.0", hasBluetooth: true, hwModel: 43)))

        let cfg = frame { $0.config.lora.region = .eu868 }
        guard case .config(let conf)? = MeshtasticProtocol.parseFromRadioFull(cfg) else { return XCTFail("not config") }
        XCTAssertEqual(conf.lora.region, .eu868)

        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(frame { $0.configCompleteID = 69420 }), .configCompleteId(69420))
        XCTAssertNil(MeshtasticProtocol.parseFromRadioFull([0xFF, 0xFF, 0xFF]))
    }

    func testRoutingAckAndNak() throws {
        var ack = Meshtastic_Routing()
        ack.errorReason = .none
        var data = Meshtastic_Data()
        data.portnum = .routingApp
        data.payload = try ack.serializedBytes()
        data.requestID = 4242
        var pkt = Meshtastic_MeshPacket()
        pkt.from = 5
        pkt.decoded = data
        let ackBytes = frame { $0.packet = pkt }
        guard case .routing(let r)? = MeshtasticProtocol.parseFromRadioFull(ackBytes) else { return XCTFail("not routing") }
        XCTAssertTrue(r.isAck)
        XCTAssertEqual(r.requestId, 4242)
        XCTAssertEqual(r.errorName, "NONE")

        var nak = Meshtastic_Routing()
        nak.errorReason = .noRoute
        data.payload = try nak.serializedBytes()
        pkt.decoded = data
        guard case .routing(let n)? = MeshtasticProtocol.parseFromRadioFull(frame { $0.packet = pkt }) else {
            return XCTFail("not routing")
        }
        XCTAssertTrue(n.isNak)
        XCTAssertEqual(n.errorReason, 1)
        XCTAssertEqual(n.errorName, "NO_ROUTE")
    }

    func testLinkObservationAndNeighborInfo() throws {
        var ni = Meshtastic_NeighborInfo()
        ni.nodeID = 0x4370_c1d8
        ni.nodeBroadcastIntervalSecs = 600
        var n1 = Meshtastic_Neighbor()
        n1.nodeID = 0xbf6e_e7bc
        n1.snr = 4.5
        var n0 = Meshtastic_Neighbor()
        n0.nodeID = 0
        ni.neighbors = [n1, n0]
        let bytes = frame { $0.packet = packet(from: 0x4370_c1d8, port: .neighborinfoApp, payload: wire(ni)) }
        let obs = MeshtasticProtocol.parseLinkObservation(bytes, nowMs: 1000)
        XCTAssertEqual(obs?.signal, .init(from: 0x4370_c1d8, snr: 8.25, rssi: -91, hopsAway: 1, heardAt: 1000))
        XCTAssertEqual(
            obs?.neighborInfo, .init(nodeId: 0x4370_c1d8, neighbors: [.init(nodeId: 0xbf6e_e7bc, snr: 4.5)], broadcastIntervalSecs: 600))
        guard case .neighborInfo(let parsed)? = MeshtasticProtocol.parseFromRadioFull(bytes) else { return XCTFail("not neighbor info") }
        XCTAssertEqual(parsed.neighbors.count, 1)

        // Through MQTT, or with no receive metrics: no signal.
        var viaMqtt = packet(port: .textMessageApp, payload: Data("x".utf8))
        viaMqtt.viaMqtt = true
        XCTAssertNil(MeshtasticProtocol.parseLinkObservation(frame { $0.packet = viaMqtt }))
        var own = packet(port: .textMessageApp, payload: Data("x".utf8))
        own.rxSnr = 0
        own.rxRssi = 0
        XCTAssertNil(MeshtasticProtocol.parseLinkObservation(frame { $0.packet = own }))
    }

    func testWaypointTracerouteAndStoreForward() throws {
        var wp = Meshtastic_Waypoint()
        wp.id = 9
        wp.name = "Camp"
        wp.description_p = "tents"
        wp.latitudeI = 520_000_000
        wp.longitudeI = 48_000_000
        wp.expire = 1_800_000_000
        wp.icon = 0x1F3D5
        guard
            case .waypoint(let w)? = MeshtasticProtocol.parseFromRadioFull(
                frame { $0.packet = packet(port: .waypointApp, payload: wire(wp)) })
        else {
            return XCTFail("not waypoint")
        }
        XCTAssertEqual(w.name, "Camp")
        XCTAssertEqual(w.description, "tents")
        XCTAssertEqual(w.latitude, 52.0, accuracy: 1e-9)
        XCTAssertEqual(w.expire, 1_800_000_000)
        XCTAssertEqual(w.icon, 0x1F3D5)

        var rd = Meshtastic_RouteDiscovery()
        rd.route = [1, 2]
        rd.snrTowards = [10, -4]
        guard
            case .traceroute(let t)? = MeshtasticProtocol.parseFromRadioFull(
                frame { $0.packet = packet(port: .tracerouteApp, payload: wire(rd)) })
        else {
            return XCTFail("not traceroute")
        }
        XCTAssertEqual(t.route, [1, 2])
        XCTAssertEqual(t.snrTowards, [10, -4])

        var sf = Meshtastic_StoreAndForward()
        sf.rr = .routerTextDirect
        sf.text = Data("stored".utf8)
        guard
            case .storeForward(let s)? = MeshtasticProtocol.parseFromRadioFull(
                frame { $0.packet = packet(port: .storeForwardApp, payload: wire(sf)) })
        else {
            return XCTFail("not store-forward")
        }
        XCTAssertEqual(s.text, "stored")
        XCTAssertEqual(s.requestResponseName, "ROUTER_TEXT_DIRECT")
    }

    func testSmallPortnums() {
        guard
            case .rangeTest(let r)? = MeshtasticProtocol.parseFromRadioFull(
                frame { $0.packet = packet(port: .rangeTestApp, payload: Data("seq 12".utf8)) })
        else {
            return XCTFail("not range test")
        }
        XCTAssertEqual(r.payload, "seq 12")
        XCTAssertEqual(r.rxRssi, -91)
        guard
            case .detectionSensor(let d)? = MeshtasticProtocol.parseFromRadioFull(
                frame { $0.packet = packet(port: .detectionSensorApp, payload: Data("door".utf8)) })
        else {
            return XCTFail("not detection")
        }
        XCTAssertEqual(d.name, "door")
        XCTAssertEqual(
            MeshtasticProtocol.parseFromRadioFull(frame { $0.packet = packet(port: .paxcounterApp, payload: Data()) }),
            .paxcounter(.init(from: 0x1234_5678)))
        var reply = packet(port: .replyApp, payload: Data("👍".utf8))
        reply.decoded.emoji = 1
        guard case .reply(let rp)? = MeshtasticProtocol.parseFromRadioFull(frame { $0.packet = reply }) else { return XCTFail("not reply") }
        XCTAssertEqual(rp.emoji, 1)
        XCTAssertEqual(rp.payload, "👍")
        XCTAssertEqual(MeshtasticProtocol.parseFromRadioFull(frame { $0.packet = packet(port: .audioApp, payload: Data()) }), .unhandled)
    }

    func testEncoders() throws {
        let text = try Meshtastic_ToRadio(serializedBytes: MeshtasticProtocol.encodeTextMessage("hi", to: 0x4370_c1d8, channel: 1))
        XCTAssertEqual(text.packet.to, 0x4370_c1d8)
        XCTAssertEqual(text.packet.channel, 1)
        XCTAssertEqual(text.packet.decoded.portnum, .textMessageApp)
        XCTAssertEqual(String(decoding: text.packet.decoded.payload, as: UTF8.self), "hi")

        let want = try Meshtastic_ToRadio(serializedBytes: MeshtasticProtocol.encodeWantConfig(69420))
        XCTAssertEqual(want.wantConfigID, 69420)

        let admin = try Meshtastic_ToRadio(
            serializedBytes: MeshtasticProtocol.buildAdminGetConfig(myNodeNum: 7, configType: MeshtasticProtocol.configLora))
        XCTAssertEqual(admin.packet.from, 7)
        XCTAssertEqual(admin.packet.to, 7)
        XCTAssertTrue(admin.packet.wantAck)
        XCTAssertEqual(admin.packet.hopLimit, 3)
        XCTAssertEqual(admin.packet.decoded.portnum, .adminApp)
        let am = try Meshtastic_AdminMessage(serializedBytes: admin.packet.decoded.payload)
        XCTAssertEqual(am.getConfigRequest, .loraConfig)

        let owner = try Meshtastic_AdminMessage(
            serializedBytes: try Meshtastic_ToRadio(
                serializedBytes: MeshtasticProtocol.buildAdminSetOwner(myNodeNum: 7, longName: "MeshSat flaneur", shortName: "FLNR")
            ).packet.decoded.payload)
        XCTAssertEqual(owner.setOwner.shortName, "FLNR")

        let lora = try Meshtastic_Config(
            serializedBytes: MeshtasticProtocol.encodeLoRaConfig(region: 3, modemPreset: 0, txPower: 27, hopLimit: 3, txEnabled: true))
        XCTAssertEqual(lora.lora.region, .eu868)
        XCTAssertEqual(lora.lora.txPower, 27)

        let tr = try Meshtastic_ToRadio(serializedBytes: MeshtasticProtocol.encodeTracerouteRequest(myNodeNum: 7, destNode: 9))
        XCTAssertEqual(tr.packet.hopLimit, 7)
        XCTAssertTrue(tr.packet.decoded.wantResponse)

        let wp = try Meshtastic_ToRadio(
            serializedBytes: MeshtasticProtocol.encodeWaypoint(
                name: "Camp", description: "", latitudeI: 1, longitudeI: 2, expire: 0, icon: 0))
        XCTAssertEqual(try Meshtastic_Waypoint(serializedBytes: wp.packet.decoded.payload).name, "Camp")

        let time = try Meshtastic_AdminMessage(
            serializedBytes: try Meshtastic_ToRadio(
                serializedBytes: MeshtasticProtocol.buildAdminSetTime(myNodeNum: 7, unixSec: 1_800_000_000)
            ).packet.decoded.payload)
        XCTAssertEqual(time.setTimeOnly, 1_800_000_000)
    }

    func testNamesAndCodes() {
        XCTAssertEqual(MeshtasticProtocol.formatNodeId(0x27ca_8f1c), "!27ca8f1c")
        XCTAssertEqual(MeshtasticProtocol.formatNodeId(0xbf6e_e7bc), "!bf6ee7bc")
        XCTAssertEqual(MeshtasticProtocol.hardwareName(0), "Unknown model")
        XCTAssertEqual(MeshtasticProtocol.hardwareName(4), "LilyGO T-Beam")
        XCTAssertEqual(MeshtasticProtocol.hardwareName(43), "Heltec V3")
        XCTAssertEqual(
            MeshtasticProtocol.hardwareName(2), "Tlora V1", "a proto name the app does not override, spelled as Android spells it")
        XCTAssertEqual(MeshtasticProtocol.hardwareName(1), "Tlora V2")
        XCTAssertEqual(MeshtasticProtocol.hardwareName(9999), "Unknown model (code 9999)")
        XCTAssertEqual(MeshtasticProtocol.LoRaRegion.fromCode(3).label, "EU 868")
        XCTAssertEqual(MeshtasticProtocol.LoRaRegion.fromCode(99), .unset)
        XCTAssertEqual(MeshtasticProtocol.ModemPreset.fromCode(2).label, "Very Long Slow")
        XCTAssertEqual(MeshtasticProtocol.ModemPreset.fromCode(99), .longFast)
    }
}
