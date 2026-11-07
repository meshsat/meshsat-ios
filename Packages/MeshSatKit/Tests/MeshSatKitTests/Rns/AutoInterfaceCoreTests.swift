// Mirrors rns/AutoInterfaceTest.kt: the AutoInterface derivations against values computed with
// Python RNS 1.5.5, its address text rules, and the peer table (MESHSAT-1553 P4, here MESHSAT-1735).
import XCTest

@testable import MeshSatRns

final class AutoInterfaceCoreTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private func unhex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testMulticastGroupMatchesUpstream() {
        XCTAssertEqual(hex(AutoInterfaceCore.multicastGroup("reticulum")), "ff120000d70bfb1c16e45e39485e31e1")
        XCTAssertEqual(AutoInterfaceCore.compress(AutoInterfaceCore.multicastGroup("reticulum")), "ff12:0:d70b:fb1c:16e4:5e39:485e:31e1")
        XCTAssertEqual(hex(AutoInterfaceCore.multicastGroup("meshsat-test")), "ff12000008e15fef2248d6feb6f6e0df")
    }

    func testTokenMatchesUpstream() {
        XCTAssertEqual(
            hex(AutoInterfaceCore.token(groupId: "reticulum", linkLocalText: "fe80::1")),
            "97b25576749ea936b0d8a8536ffaf442d157cf47d460dcf13c48b7bd18b6c163")
        XCTAssertEqual(
            hex(AutoInterfaceCore.token(groupId: "reticulum", linkLocalText: "fe80::fc0a:1eff:fef2:f2ac")),
            "8f55515369a0f2af8df9fa724c08bbf5d915b9e4f46607118d93d6f38a5aa53b")
    }

    func testAddressTextAsInetNtop() {
        XCTAssertEqual(AutoInterfaceCore.compress(unhex("fe80000000000000fc0a1efffef2f2ac")), "fe80::fc0a:1eff:fef2:f2ac")
        XCTAssertEqual(AutoInterfaceCore.compress(unhex("fe800000000000000000000000000001")), "fe80::1")
        XCTAssertEqual(AutoInterfaceCore.compress([UInt8](repeating: 0, count: 16)), "::")
        var one = [UInt8](repeating: 0, count: 16)
        one[15] = 1
        XCTAssertEqual(AutoInterfaceCore.compress(one), "::1")
        XCTAssertEqual(AutoInterfaceCore.compress(unhex("20010db8000000000001000000000001")), "2001:db8::1:0:0:1")
        XCTAssertEqual(AutoInterfaceCore.compress(unhex("00010000000000020000000000000003")), "1:0:0:2::3")
        XCTAssertEqual(AutoInterfaceCore.compress(unhex("00010000000200000000000000000003")), "1:0:2::3")
        XCTAssertEqual(AutoInterfaceCore.compress(unhex("00010000000000000002000000000003")), "1::2:0:0:3")
    }

    func testDescopeAsUpstream() {
        XCTAssertEqual(AutoInterfaceCore.descope("fe80::fc0a:1eff:fef2:f2ac%veth1"), "fe80::fc0a:1eff:fef2:f2ac")
        XCTAssertEqual(AutoInterfaceCore.descope("fe80:2::1"), "fe80::1")
        XCTAssertEqual(AutoInterfaceCore.descope("fe80::1"), "fe80::1")
        XCTAssertEqual(AutoInterfaceCore.descope("fe80::1%en0"), "fe80::1")
    }

    func testTokenVerification() {
        let tok = AutoInterfaceCore.token(groupId: "reticulum", linkLocalText: "fe80::1")
        XCTAssertTrue(AutoInterfaceCore.verifies(tok, groupId: "reticulum", sourceText: "fe80::1"))
        XCTAssertFalse(AutoInterfaceCore.verifies(tok, groupId: "reticulum", sourceText: "fe80::2"))
        XCTAssertFalse(AutoInterfaceCore.verifies(Array(tok.prefix(31)), groupId: "reticulum", sourceText: "fe80::1"))
    }

    func testPeerTableAddsRefreshesTimesOutAndReversePeers() {
        let t = AutoPeerTable(ownAddresses: ["fe80::a"])
        XCTAssertFalse(t.heard(address: "fe80::a", device: "en0", nowMs: 0), "our own echo is not a peer")
        XCTAssertTrue(t.heard(address: "fe80::b", device: "en0", nowMs: 0))
        XCTAssertFalse(t.heard(address: "fe80::b", device: "en0", nowMs: 1000), "known: refreshed only")
        XCTAssertTrue(t.dataFrom(address: "fe80::b", nowMs: 2000))
        XCTAssertFalse(t.dataFrom(address: "fe80::c", nowMs: 2000), "data from a stranger is dropped")
        let first = t.jobs(nowMs: 6000)
        XCTAssertEqual(first.reverse.map(\.address), ["fe80::b"])
        XCTAssertTrue(first.timedOut.isEmpty)
        XCTAssertTrue(t.jobs(nowMs: 7000).reverse.isEmpty, "the next token is 5.2 s later")
        let late = t.jobs(nowMs: 2000 + AutoInterfaceCore.peeringTimeoutMs + 1)
        XCTAssertEqual(late.timedOut, ["fe80::b"])
        XCTAssertEqual(t.count, 0)
    }

    func testDedupWithinItsWindow() {
        let t = AutoPeerTable()
        let d: [UInt8] = [1, 2, 3]
        XCTAssertFalse(t.isDuplicate(d, nowMs: 0))
        XCTAssertTrue(t.isDuplicate(d, nowMs: 500))
        XCTAssertFalse(t.isDuplicate(d, nowMs: 2000), "past 750 ms it is a new datagram")
        XCTAssertFalse(t.isDuplicate([4], nowMs: 2000))
    }
}
