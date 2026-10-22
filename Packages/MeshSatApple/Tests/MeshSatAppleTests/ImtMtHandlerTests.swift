// The r34 review's R34-R1 on the App's real MT handler (storeIridium9704Mt): a framed Reticulum
// packet never becomes a text row, a notification or a forwarding call, while a plain text, the H
// chain, the legacy chain and a sealed message that does not open keep their own paths.
// [MESHSAT-1624]
import Foundation
import MeshSatEngine
import MeshSatStore
import MeshSatWire
import XCTest

@testable import MeshSatPlatform

final class ImtMtHandlerTests: XCTestCase {
    private let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let otherKey = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
    private let greek = Array("Καλησπέρα από το σκάφος, όλα καλά".utf8)

    /// The review's input: 52 4e 53 49 01 | 00 00 | 07 x 16 | 00 | "payload".
    private let framed: [UInt8] =
        [0x52, 0x4E, 0x53, 0x49, 0x01, 0x00, 0x00] + [UInt8](repeating: 0x07, count: 16) + [0x00]
        + Array("payload".utf8)

    private func makeGateway() async throws -> GatewayController {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "net.meshsat.ios.tests.\(UUID().uuidString)"))
        let settings = SettingsRepository(defaults: defaults, secure: MemoryKeyValueStore())
        settings.set(SettingsKey.satelliteChain, SatelliteChain.modeSealed)
        let gateway = GatewayController(settings: settings, db: try AppDatabase.inMemory())
        try await gateway.db.conversationKeys.upsert(ConversationKey(sender: SatelliteChain.keyRef, hexKey: key, label: "test"))
        return gateway
    }

    func testAReticulumFrameIsNeverATextRowANotificationOrAForward() async throws {
        let gateway = try await makeGateway()
        let outcome = await gateway.storeIridium9704Mt(framed)
        XCTAssertEqual(outcome, .reticulumFrame, "not handed to the forwarding rules")
        let rows = try await gateway.db.messages.count()
        XCTAssertEqual(rows, 0, "no text row")
        XCTAssertNil(gateway.messageNotifications.value, "no notification")
    }

    func testTextsAndSealedMessagesKeepTheirPaths() async throws {
        let gateway = try await makeGateway()
        let club = "RNSI is the name of our club tonight"
        let plain = await gateway.storeIridium9704Mt(Array(club.utf8))
        XCTAssertEqual(plain, .text(sealed: false), "a text that starts with the magic is still a text")
        XCTAssertEqual(gateway.messageNotifications.value?.text, club)

        let h = await gateway.storeIridium9704Mt(try SatelliteChain.seal(greek, keyHex: key))
        XCTAssertEqual(h, .text(sealed: true))
        XCTAssertEqual(gateway.messageNotifications.value?.text, String(decoding: greek, as: UTF8.self))

        let legacy = await gateway.storeIridium9704Mt(try SatelliteChain.seal(greek + Array(" (old)".utf8), keyHex: key, chain: .legacy))
        XCTAssertEqual(legacy, .text(sealed: true))

        let wrong = await gateway.storeIridium9704Mt(try SatelliteChain.seal(greek, keyHex: otherKey))
        XCTAssertEqual(wrong, .unopened, "a sealed message that does not open is never forwarded")

        let rows = try await gateway.db.messages.count()
        XCTAssertEqual(rows, 4)
        let encrypted = try await gateway.db.messages.countEncrypted()
        XCTAssertEqual(encrypted, 3)
    }
}
