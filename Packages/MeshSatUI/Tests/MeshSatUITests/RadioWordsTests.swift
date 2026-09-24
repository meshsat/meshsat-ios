import MeshSatMeshtastic
import XCTest

@testable import MeshSatUI

final class RadioWordsTests: XCTestCase {
    func testTheRegionWarningFollowsThePhonesCountry() {
        XCTAssertNil(RegionCheck.warning(MeshtasticProtocol.LoRaRegion.eu868.code, "NL"))
        XCTAssertNil(RegionCheck.warning(MeshtasticProtocol.LoRaRegion.lora24.code, "NL"))
        XCTAssertNil(RegionCheck.warning(MeshtasticProtocol.LoRaRegion.us.code, nil))
        XCTAssertNil(RegionCheck.warning(MeshtasticProtocol.LoRaRegion.us.code, "ZZ"))
        XCTAssertTrue(RegionCheck.warning(MeshtasticProtocol.LoRaRegion.us.code, "NL")!.contains("EU 868 or EU 433"))
        XCTAssertTrue(RegionCheck.warning(0, "NL")!.contains("No region is set"))
    }

    func testChannelKeyWords() {
        XCTAssertEqual(RadioWords.channelKey([], role: 2).label, "Channel key: same as the main channel")
        XCTAssertEqual(RadioWords.channelKey([0], role: 1).label, "Channel key: none (not encrypted)")
        XCTAssertEqual(RadioWords.channelKey([1], role: 1).label, "Channel key: default (not private)")
        XCTAssertEqual(RadioWords.channelKey([UInt8](repeating: 7, count: 16), role: 1).label, "Channel key: private")
    }

    func testLabelsForUnknownCodes() {
        XCTAssertEqual(RadioWords.regionLabel(0), "Not set")
        XCTAssertEqual(RadioWords.regionLabel(3), "EU 868")
        XCTAssertEqual(RadioWords.regionLabel(99), "Region code 99")
        XCTAssertEqual(RadioWords.presetLabel(0), "Long Fast")
        XCTAssertNil(RadioWords.presetDetails(42))
    }
}

final class AprsIsPasscodeTests: XCTestCase {
    func testTheWellKnownHash() {
        // aprs.fi's published examples for the standard algorithm.
        XCTAssertEqual(AprsIsPasscode.calculate("N0CALL"), "13023")
        XCTAssertEqual(AprsIsPasscode.calculate("n0call-7"), "13023")
    }
}
