// The gateway's pure helpers, on an in-memory store and settings, without starting it (no
// Bluetooth, no location): what the APRS, satellite, SMS and configuration paths compute
// from the settings. The transports themselves are covered by the Kit's tests.
import MeshSatEngine
import MeshSatStore
import MeshSatWire
import XCTest

@testable import MeshSatPlatform

final class GatewayHelpersTests: XCTestCase {
    private func makeGateway() throws -> (GatewayController, SettingsRepository) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "net.meshsat.ios.tests.\(UUID().uuidString)"))
        let settings = SettingsRepository(defaults: defaults, secure: MemoryKeyValueStore())
        let gateway = GatewayController(settings: settings, db: try AppDatabase.inMemory())
        return (gateway, settings)
    }

    func testAprsCallsignAndNodeId() throws {
        let (gateway, settings) = try makeGateway()
        XCTAssertEqual(gateway.aprsFullCallsign(), "")
        settings.set(SettingsKey.aprsCallsign, "pa3xyz")
        XCTAssertEqual(gateway.aprsFullCallsign(), "PA3XYZ-10", "the default SSID is 10")
        settings.set(SettingsKey.aprsSsid, "0")
        XCTAssertEqual(gateway.aprsFullCallsign(), "PA3XYZ")
        // Java's String.hashCode masked to 32 bits, as Android keys the station.
        XCTAssertEqual(GatewayController.aprsNodeId("PA3XYZ-10"), 3668385237)
        XCTAssertEqual(GatewayController.aprsNodeId("MESHSAT-KIT1"), 126669519)
    }

    func testSatelliteBytesArePlainWithoutTheEncoder() throws {
        let (gateway, settings) = try makeGateway()
        XCTAssertEqual(gateway.satelliteBytes(for: "hello"), Array("hello".utf8))
        settings.set(SettingsKey.compressIridium, "msvqsc")
        XCTAssertEqual(gateway.satelliteBytes(for: "hello"), Array("hello".utf8), "no encoder loaded: as typed")
        XCTAssertNil(gateway.msvqscText(from: [0x01, 0x31, 1, 0, 2, 0, 3, 0]), "no codebook loaded")
        XCTAssertEqual(gateway.msvqscStages, 3)
        settings.set(SettingsKey.msvqscStages, "5")
        XCTAssertEqual(gateway.msvqscStages, 5)
    }

    func testSmsWireBodyFollowsTheKeysAndTheMode() async throws {
        let (gateway, settings) = try makeGateway()
        let plain = await gateway.smsWireBody("meet at the bridge", recipient: "+31600000000")
        XCTAssertEqual(plain, SmsWire.Encoded(body: "meet at the bridge", compressed: false, encrypted: false))
        // The global key applies only when encryption is on.
        let key = AesGcmCrypto.generateKey()
        settings.setEncryptionKey(key)
        let stillPlain = await gateway.smsWireBody("meet at the bridge", recipient: "+31600000000")
        XCTAssertFalse(stillPlain.encrypted)
        settings.set(SettingsKey.encryptionEnabled, true)
        let keyed = await gateway.smsWireBody("meet at the bridge", recipient: "+31600000000")
        XCTAssertTrue(keyed.encrypted)
        XCTAssertTrue(keyed.compressed, "a keyed message is smaz2-compressed unless msvqsc is set")
        XCTAssertEqual(SmsWire.decode(keyed.body, keys: [key]).text, "meet at the bridge")
        // A conversation key for the recipient wins over the global one.
        let convKey = AesGcmCrypto.generateKey()
        try await gateway.db.conversationKeys.upsert(ConversationKey(sender: "+31600000000", hexKey: convKey))
        let conv = await gateway.smsWireBody("hi there", recipient: "+31600000000")
        XCTAssertEqual(SmsWire.decode(conv.body, keys: [convKey]).text, "hi there")
        XCTAssertEqual(SmsWire.decode(conv.body, keys: [key]).text, conv.body, "the global key does not open it")
    }

    func testConfigurationExportOnAnEmptyStore() async throws {
        let (gateway, _) = try makeGateway()
        let json = await gateway.exportConfiguration(yaml: false)
        XCTAssertTrue(json.contains("\"version\": \"0.4.0\""))
        XCTAssertTrue(json.contains("\"access_rules\": []"))
        let yaml = await gateway.exportConfiguration(yaml: true)
        XCTAssertTrue(yaml.hasPrefix("version: \"0.4.0\"\n"))
        XCTAssertTrue(yaml.contains("access_rules:\n  []\n"))
        let imported = await gateway.importConfiguration(
            "{\"version\":\"0.4.0\",\"access_rules\":[{\"interface_id\":\"mesh_0\",\"direction\":\"in\",\"name\":\"r\"}]}")
        XCTAssertEqual(try imported.get()["access_rules"], 1)
        let rules = try await gateway.db.accessRules.getAllSync()
        XCTAssertEqual(rules.map(\.name), ["r"])
        // Text that is not JSON goes through the YAML reader, as Android's importAuto sends it,
        // and comes out as an empty document.
        if case .failure(let e) = await gateway.previewConfiguration("nope") {
            XCTAssertEqual(e.description, "missing version field")
        } else {
            XCTFail("refused")
        }
        XCTAssertEqual(gateway.burstPending, 0)
        let scores = await gateway.healthScores()
        XCTAssertTrue(scores.isEmpty, "no scorer before start")
    }
}
