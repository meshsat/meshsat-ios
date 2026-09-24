// Mirrors NodeProfileTest.kt: a node profile is written over what the node already has
// (MESHSAT-1285). set_config replaces a whole section, so a profile that names two fields of
// the radio section and is sent as a fresh section would silently reset the region, the power
// and everything else in it. These hold the line: what the profile leaves out survives, and
// nothing is guessed.
import MeshSatMeshtastic
import MeshSatProto
import XCTest

final class NodeProfileTests: XCTestCase {
    private let key = (0..<32).map { UInt8($0) }

    private var node: NodeSections {
        var device = Meshtastic_Config.DeviceConfig()
        device.role = .client
        device.nodeInfoBroadcastSecs = 900
        device.tzdef = "CET-1CEST"
        var lora = Meshtastic_Config.LoRaConfig()
        lora.region = .eu868
        lora.usePreset = true
        lora.txPower = 27
        lora.txEnabled = true
        lora.hopLimit = 3
        var position = Meshtastic_Config.PositionConfig()
        position.positionBroadcastSecs = 3600
        var power = Meshtastic_Config.PowerConfig()
        power.lsSecs = 300
        var bluetooth = Meshtastic_Config.BluetoothConfig()
        bluetooth.enabled = true
        var network = Meshtastic_Config.NetworkConfig()
        network.wifiSsid = "garden"
        var channel = Meshtastic_Channel()
        channel.index = 0
        channel.role = .primary
        channel.settings.psk = Data([1])
        return NodeSections(
            device: device, lora: lora, position: position, power: power, bluetooth: bluetooth, network: network,
            primaryChannel: channel)
    }

    private func ready(_ p: NodeProfile, file: StaticString = #filePath, line: UInt = #line) -> ([Meshtastic_AdminMessage], [String]) {
        guard case .ready(let messages, let sections) = NodeProfiles.plan(now: node, profile: p) else {
            XCTFail("refused", file: file, line: line)
            return ([], [])
        }
        return (messages, sections)
    }

    func testOneEditOpenedFirstAndCommittedLast() {
        let (messages, sections) = ready(NodeProfile(role: "CLIENT_MUTE", ignoreMqtt: true))
        XCTAssertEqual(messages.first?.beginEditSettings, true)
        XCTAssertEqual(messages.last?.commitEditSettings, true)
        XCTAssertEqual(sections, ["device", "radio"])
        XCTAssertEqual(messages.count, 4)
    }

    func testWhatTheProfileLeavesOutSurvives() {
        let (messages, _) = ready(NodeProfile(role: "CLIENT_MUTE", rxBoostedGain: true, ignoreMqtt: true))
        let device = messages[1].setConfig.device
        XCTAssertEqual(device.role, .clientMute)
        XCTAssertEqual(device.nodeInfoBroadcastSecs, 900)
        XCTAssertEqual(device.tzdef, "CET-1CEST")
        let lora = messages[2].setConfig.lora
        XCTAssertTrue(lora.sx126XRxBoostedGain)
        XCTAssertTrue(lora.ignoreMqtt)
        XCTAssertEqual(lora.region, .eu868)
        XCTAssertEqual(lora.txPower, 27)
        XCTAssertTrue(lora.txEnabled)
    }

    func testASectionNobodyMentionedIsNotSent() {
        let (messages, sections) = ready(NodeProfile(ntpServer: "meshtastic.pool.ntp.org"))
        XCTAssertEqual(sections, ["network"])
        XCTAssertEqual(messages[1].setConfig.network.wifiSsid, "garden")
    }

    func testTheChannelKeepsItsSlotAndTakesTheNewNameKeyAndSwitches() {
        let (messages, _) = ready(
            NodeProfile(channelName: "msat-test", channelPsk: key, channelUplink: true, channelDownlink: true, channelPositionPrecision: 0))
        let ch = messages[1].setChannel
        XCTAssertEqual(ch.index, 0)
        XCTAssertEqual(ch.role, .primary)
        XCTAssertEqual(ch.settings.name, "msat-test")
        XCTAssertEqual(ch.settings.psk.count, 32)
        XCTAssertTrue(ch.settings.uplinkEnabled && ch.settings.downlinkEnabled)
        XCTAssertEqual(ch.settings.moduleSettings.positionPrecision, 0)
    }

    func testNeverIsTheFirmwaresNever() {
        let (messages, _) = ready(NodeProfile(powerSaving: false, sdsSecs: NodeProfiles.sdsNever))
        let power = messages[1].setConfig.power
        XCTAssertEqual(power.sdsSecs, UInt32.max)
        XCTAssertFalse(power.isPowerSaving)
        XCTAssertEqual(power.lsSecs, 300)
    }

    func testNothingIsGuessed() {
        func refused(_ p: NodeProfile) -> Bool { NodeProfiles.plan(now: node, profile: p).isRefused }
        XCTAssertTrue(refused(NodeProfile(role: "CLIENT_MUTED")))
        XCTAssertTrue(refused(NodeProfile(region: "EU868")))
        XCTAssertTrue(refused(NodeProfile(preset: "LongFast")))
        XCTAssertTrue(refused(NodeProfile(gpsMode: "OFF")))
        XCTAssertTrue(refused(NodeProfile(hopLimit: 9)))
        XCTAssertTrue(refused(NodeProfile(channelPsk: [UInt8](repeating: 0, count: 20))))
        XCTAssertTrue(refused(NodeProfile(channelName: "a-name-too-long")))
        XCTAssertTrue(refused(NodeProfile(longName: "Only half a name")))
        XCTAssertTrue(refused(NodeProfile()))
    }

    func testKnownNamesAreAccepted() {
        let (messages, _) = ready(NodeProfile(region: "EU_868", preset: "LONG_FAST", gpsMode: "ENABLED"))
        XCTAssertEqual(messages[1].setConfig.lora.region, .eu868)
        XCTAssertEqual(messages[1].setConfig.lora.modemPreset, .longFast)
        XCTAssertEqual(messages[2].setConfig.position.gpsMode, .enabled)
    }

    func testASectionTheNodeHasNotReportedCannotBeWritten() {
        var blank = node
        blank.lora = nil
        XCTAssertTrue(NodeProfiles.plan(now: blank, profile: NodeProfile(ignoreMqtt: true)).isRefused)
    }

    func testAKeyIsShownAsAFingerprintNeverAsItself() {
        let shown = NodeProfiles.keyFingerprint(key)
        XCTAssertTrue(shown.hasSuffix("(256-bit)"))
        XCTAssertFalse(shown.contains(Data(key).base64EncodedString()))
        XCTAssertFalse(shown.replacingOccurrences(of: " ", with: "").contains(key.map { String(format: "%02x", $0) }.joined()))
        XCTAssertEqual(NodeProfiles.keyFingerprint([1]), "default (not private)")
        XCTAssertEqual(NodeProfiles.keyFingerprint([]), "none")
    }
}
