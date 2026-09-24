// Mirrors RuleLinkChoicesTest.kt and DuplicatesTheHubTest.kt, plus the keyword merge (B9).
import MeshSatEngine
import XCTest

@testable import MeshSatUI

final class RuleWordsTests: XCTestCase {
    func testTheLinkThatReachesTheHubIsTheOneCalledHub() {
        XCTAssertEqual(Words.channel("hub_0"), "Hub")
        XCTAssertEqual(Words.channel("hub_relay"), "Hub relay")
        XCTAssertEqual(Words.channel("mqtt_0"), "MQTT broker")
    }

    func testNoTwoLinksShareAName() {
        let ids = ["mesh_0", "iridium_0", "iridium9704_0", "sms_0", "hub_0", "hub_relay", "mqtt_0", "aprs_0"]
        let names = ids.map { Words.channel($0) }
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testASwitchedOffLinkIsNotOffered() {
        let all = [("mesh_0", false), ("mqtt_0", true), ("hub_0", false), ("aprs_0", true)].map { (id: $0.0, disabled: $0.1) }
        XCTAssertEqual(RuleWords.linkChoices(all, keep: ""), ["mesh_0", "hub_0"])
    }

    func testTheLinkASavedRuleAlreadyNamesStays() {
        let all = [("mesh_0", false), ("mqtt_0", true), ("hub_0", false)].map { (id: $0.0, disabled: $0.1) }
        XCTAssertEqual(RuleWords.linkChoices(all, keep: "mqtt_0"), ["mesh_0", "mqtt_0", "hub_0"])
    }

    func testSatelliteToTheHubDuplicatesWhatTheProviderAlreadySends() {
        XCTAssertTrue(RuleWords.duplicatesTheHub("iridium_0", "hub_0"))
        XCTAssertTrue(RuleWords.duplicatesTheHub("iridium9704_0", "hub_0"))
    }

    func testMeshAndSmsToTheHubAreThePointOfTheFeature() {
        XCTAssertFalse(RuleWords.duplicatesTheHub("mesh_0", "hub_0"))
        XCTAssertFalse(RuleWords.duplicatesTheHub("sms_0", "hub_0"))
        XCTAssertFalse(RuleWords.duplicatesTheHub("aprs_0", "hub_0"))
    }

    func testSatelliteAnywhereElseIsNotTheHubsBusiness() {
        XCTAssertFalse(RuleWords.duplicatesTheHub("iridium_0", "sms_0"))
        XCTAssertFalse(RuleWords.duplicatesTheHub("iridium_0", "mesh_0"))
        XCTAssertFalse(RuleWords.duplicatesTheHub("iridium_0", "hub_relay"))
    }

    func testSavingAKeywordKeepsEveryOtherFilter() {
        let merged = RuleWords.mergeKeyword(#"{"channels":[0,1],"keyword":"old"}"#, "new")
        let obj = RuleWords.jsonObject(merged)!
        XCTAssertEqual(obj["keyword"] as? String, "new")
        XCTAssertEqual((obj["channels"] as? [Int]) ?? [], [0, 1])
        XCTAssertEqual(RuleWords.mergeKeyword(#"{"keyword":"x"}"#, ""), "{}")
        XCTAssertEqual(RuleWords.mergeKeyword("not json", ""), "not json")
        XCTAssertEqual(RuleWords.keyword(AccessRule(interfaceId: "mesh_0", direction: "ingress", name: "r", filters: merged)), "new")
    }

    func testStoredTimestampsParseAsUtc() {
        XCTAssertEqual(RuleWords.parseUtcStamp("2026-09-20T10:15:00Z"), 1_789_899_300_000)
        XCTAssertEqual(RuleWords.parseUtcStamp("2026-09-20 10:15:00"), 1_789_899_300_000)
        XCTAssertNil(RuleWords.parseUtcStamp(""))
    }
}
