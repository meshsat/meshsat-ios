// Mirrors test hubmsg/HubMsgFixturesTest.kt: the shared vectors of HeMB-NG stage 2 (fixture release
// fixtures-v1.1, whose integrity HembNgFixturesTests pins), consumed as this app's production code:
// the ids (C1e), the content digest (C1d), the receipt kinds (C6a), the reducer (C6) in every order
// with every event twice, and the inbox (C3), all 17 cases. [MESHSAT-1584]
import Foundation
import XCTest

@testable import MeshSatHub

final class HubMsgFixturesTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let lock = try XCTUnwrap(Bundle.module.url(forResource: "fixtures", withExtension: "lock", subdirectory: "Fixtures/hemb-ng"))
        let url = lock.deletingLastPathComponent().appendingPathComponent("v1").appendingPathComponent(name)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func hexBytes(_ s: String) -> [UInt8] {
        let c = Array(s.utf8)
        return stride(from: 0, to: c.count, by: 2).map { UInt8(String(decoding: c[$0..<$0 + 2], as: UTF8.self), radix: 16) ?? 0 }
    }

    private static func int64(_ any: Any?) -> Int64 { (any as? NSNumber)?.int64Value ?? 0 }

    func testTheIdsAreValidAsTheReleaseSays() throws {
        let f = try fixture("ids.json")
        XCTAssertEqual(HubMsgIds.namespace, f["namespace"] as? String)
        let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let x = c["context"] as? [String: Any] ?? [:]
            let ctx = HubMsgIds.Context(
                sender: x["sender"] as? String ?? "", name: x["name"] as? String ?? "", bridgeId: x["bridge_id"] as? String ?? "",
                runStartMs: x["run_start_ms"] != nil ? Self.int64(x["run_start_ms"]) : -1)
            XCTAssertEqual(
                c["valid"] as? Bool, HubMsgIds.idValid(c["id"] as? String ?? "", field: c["field"] as? String ?? "", context: ctx),
                c["case"] as? String ?? "")
        }
    }

    func testANewIdIsAV7WithItsTime() throws {
        let now: Int64 = 1_792_330_000_123
        let id = HubMsgIds.newV7(now)
        XCTAssertTrue(HubMsgIds.validV7(id))
        let b = try XCTUnwrap(HubMsgIds.parseCanonical(id))
        var ms: Int64 = 0
        for i in 0..<6 { ms = ms << 8 | Int64(b[i]) }
        XCTAssertEqual(now, ms)
    }

    func testTheContentDigestIsTheReleases() throws {
        let f = try fixture("content_digest.json")
        XCTAssertEqual(HubMsgDigest.tag, f["tag"] as? String)
        let vectors = try XCTUnwrap(f["vectors"] as? [[String: Any]])
        XCTAssertFalse(vectors.isEmpty)
        for v in vectors {
            let body = Self.hexBytes(v["body_hex"] as? String ?? "")
            let mid = v["mid"] as? String ?? ""
            let rcpt = v["recipient"] as? String ?? ""
            let ct = v["content_type"] as? String ?? ""
            let exp = Self.int64(v["mid_expires_at_ms"])
            let pre = HubMsgDigest.preimage(mid: mid, recipient: rcpt, contentType: ct, midExpiresAt: exp, body: body)
            XCTAssertEqual(v["preimage_hex"] as? String, pre?.map { String(format: "%02x", $0) }.joined(), v["case"] as? String ?? "")
            XCTAssertEqual(
                v["content_sha256"] as? String,
                HubMsgDigest.sha256Hex(mid: mid, recipient: rcpt, contentType: ct, midExpiresAt: exp, body: body),
                v["case"] as? String ?? "")
        }
    }

    func testTheReceiptKindsAreTheReleases() throws {
        let kinds = try XCTUnwrap(try fixture("c6a_receipt_kinds.json")["kinds"] as? [[String: Any]])
        let want = Set(
            kinds.map {
                HubMsgReducer.Kind(
                    kind: $0["kind"] as? String ?? "", cls: $0["class"] as? String ?? "", authority: $0["authority"] as? String ?? "")
            })
        XCTAssertEqual(want, HubMsgReducer.allowedKinds)
    }

    func testTheReducerIsTheReleasesInEveryOrderWithEveryEventTwice() throws {
        let f = try fixture("c6_reducer.json")
        let o = try XCTUnwrap(f["operation"] as? [String: Any])
        let op = HubMsgReducer.Operation(
            opId: o["op_id"] as? String ?? "", mid: o["mid"] as? String ?? "", recipient: o["recipient"] as? String ?? "")
        XCTAssertEqual(HubMsgReducer.projectionOrder, f["projection_order"] as? [String])
        XCTAssertEqual(HubMsgReducer.sourceOf, f["source_by_authority"] as? [String: String])
        let sets = try XCTUnwrap(f["sets"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(sets.count, 5)
        for set in sets {
            let events = (set["events"] as? [[String: Any]] ?? []).map { dict -> HubEvent in
                let data = try? JSONSerialization.data(withJSONObject: dict)
                return HubEvent.from(JSONBody.parse(data ?? Data()) ?? JSONBody())
            }
            let e = try XCTUnwrap(set["expect"] as? [String: Any])
            let want = HubMsgReducer.Projection(
                state: e["state"] as? String ?? "", conflict: e["conflict"] as? Bool ?? false,
                failedReasons: e["failed_reasons"] as? [String] ?? [], evidence: e["evidence"] as? [String] ?? [],
                rejected: e["rejected"] as? [String] ?? [])
            var n = 0
            Self.permute(events) { order in
                n += 1
                for evs in [order, order + order] {
                    XCTAssertEqual(want, HubMsgReducer.reduce(op, evs), "\(set["case"] as? String ?? ""), order \(n)")
                }
            }
        }
    }

    private static func permute(_ evs: [HubEvent], _ visit: ([HubEvent]) -> Void) {
        var a = evs
        func rec(_ k: Int) {
            if k == a.count {
                visit(a)
                return
            }
            for i in k..<a.count {
                a.swapAt(k, i)
                rec(k + 1)
                a.swapAt(k, i)
            }
        }
        rec(0)
    }

    func testTheInboxAnswersEveryCaseAsTheReleaseSays() throws {
        let f = try fixture("inbox_cases.json")
        XCTAssertEqual(HubMsgInbox.skewMs, Self.int64(f["skew_ms"]))
        XCTAssertEqual(HubMsgInbox.retentionAfterExpiryMs, Self.int64(f["retention_after_expiry_ms"]))
        XCTAssertEqual(Int64(HubMsgInbox.capacity), Self.int64(f["capacity_target"]))
        let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
        XCTAssertEqual(17, cases.count)
        for c in cases {
            let tx = MemInbox()
            for (i, s) in (c["steps"] as? [[String: Any]] ?? []).enumerated() {
                let sub = s["submission"] as? [String: Any] ?? [:]
                let body = String(decoding: Self.hexBytes(sub["body_hex"] as? String ?? ""), as: UTF8.self)
                let d = HubDelivery(
                    opId: sub["op_id"] as? String ?? "", mid: sub["mid"] as? String ?? "", from: sub["origin"] as? String ?? "",
                    to: sub["recipient"] as? String ?? "", contentType: sub["content_type"] as? String ?? "",
                    midExpiresAt: Self.int64(sub["mid_expires_at"]), expiresAt: Self.int64(sub["expires_at"]),
                    contentSha256: sub["content_sha256"] as? String ?? "", body: body)
                var got = try HubMsgInbox.commit(
                    tx, d, nowMs: Self.int64(s["now"]), clockEstablished: s["clock_established"] as? Bool ?? false,
                    capacity: Int(Self.int64(c["capacity"])))
                got.messageId = 0
                let e = s["expect"] as? [String: Any] ?? [:]
                let want = HubMsgInbox.Answer(
                    result: e["result"] as? String ?? "", reason: e["reason"] as? String ?? "",
                    storedNow: e["stored_now"] as? Bool ?? false,
                    withinSkew: e["accepted_within_skew"] as? Bool ?? false, unjudged: e["expiry_unjudged"] as? Bool ?? false)
                XCTAssertEqual(want, got, "\(c["case"] as? String ?? "") step \(i + 1)")
            }
        }
    }
}

/// An inbox in memory, for the tests.
final class MemInbox: HubMsgInbox.Transaction {
    var entries: [HubMsgInbox.Entry] = []
    var messages: [String] = []

    func byOp(origin: String, opId: String) throws -> HubMsgInbox.Entry? { entries.first { $0.origin == origin && $0.opId == opId } }
    func byMid(origin: String, mid: String) throws -> HubMsgInbox.Entry? {
        entries.filter { $0.origin == origin && $0.mid == mid }.min { $0.committedAt < $1.committedAt }
    }
    func count() throws -> Int { entries.count }
    func pruneBefore(_ nowMs: Int64) throws -> Int {
        let before = entries.count
        entries.removeAll { HubMsgInbox.retainedUntil($0.expiresAt) < nowMs }
        return before - entries.count
    }
    func insert(_ e: HubMsgInbox.Entry, store: Bool, body: String) throws -> HubMsgInbox.Entry {
        var kept = e
        if store {
            messages.append(body)
            kept.messageId = Int64(messages.count)
        }
        entries.append(kept)
        return kept
    }
}
