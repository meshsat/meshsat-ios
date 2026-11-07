// Mirrors kit/KitApiClientTest.kt (MESHSAT-1738, iOS MESHSAT-1820): a kit's API on the LAN with its
// token, against a fake standing in for the Bridge. The Bearer goes on every request when there is
// one and never when there is none, a 401 is the prompt for the token, and the token reaches no log
// line, no description and no error.
import Foundation
import MeshSatEngine
import XCTest

final class KitApiTests: XCTestCase {
    private let token = "s3cr3t-token-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    /// Answers from a script and records what it was asked; `failure` makes every request throw.
    private final class FakeKit: KitHttp, @unchecked Sendable {
        struct Asked {
            let method: String
            let url: String
            let headers: [String: String]
            let body: String?
        }
        private let lock = NSLock()
        private var answers: [KitApiClient.Response]
        private var seen: [Asked] = []
        let failure: String?
        init(_ answers: [KitApiClient.Response] = [], failure: String? = nil) {
            self.answers = answers
            self.failure = failure
        }
        var asked: [Asked] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
        func request(
            method: String, url: String, headers: [String: String], body: [UInt8]?, timeoutSeconds: Double
        ) async throws -> KitApiClient.Response {
            let next: KitApiClient.Response? = take(
                Asked(method: method, url: url, headers: headers, body: body.map { String(decoding: $0, as: UTF8.self) }))
            if let failure { throw KitRequestError(failure) }
            return next ?? KitApiClient.Response(code: 500, body: "")
        }
        private func take(_ a: Asked) -> KitApiClient.Response? {
            lock.lock()
            defer { lock.unlock() }
            seen.append(a)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) {
            lock.lock()
            items.append(s)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private let status = KitApiClient.Response(code: 200, body: #"{"bridge_id":"tesseract","version":"1.2.3","mode":"direct"}"#)

    func testTheTokenGoesAsTheBearerOnEveryRequest() async throws {
        let kit = FakeKit([status, KitApiClient.Response(code: 200, body: "{}"), status])
        let client = KitApiClient(baseUrl: "192.168.1.20", token: token, http: kit)
        let r = try await client.get("/api/status")
        XCTAssertEqual(r.code, 200)
        XCTAssertFalse(r.needsToken)
        _ = try await client.post("/api/send", json: #"{"text":"hi"}"#)
        let probed = await KitProbe.check(client, hasToken: true)
        XCTAssertEqual(probed, .reachable("tesseract, v1.2.3, direct"))
        XCTAssertEqual(KitProbe.line(probed), "Reachable: tesseract, v1.2.3, direct")
        let asked = kit.asked
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(asked[0].url, "http://192.168.1.20:6050/api/status")
        XCTAssertEqual(asked[0].headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(asked[1].method, "POST")
        XCTAssertEqual(asked[1].headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(asked[1].headers["Content-Type"], "application/json")
        XCTAssertEqual(asked[1].body, #"{"text":"hi"}"#)
        XCTAssertEqual(asked[2].url, "http://192.168.1.20:6050/api/status")
    }

    func testWithoutATokenNoAuthorizationHeaderIsSent() async throws {
        let kit = FakeKit([KitApiClient.Response(code: 200, body: "{}")])
        _ = try await KitApiClient(baseUrl: "kit-a", token: "", http: kit).get("/api/status")
        XCTAssertNil(kit.asked[0].headers["Authorization"])
        XCTAssertNil(KitApiClient.authHeader(""))
        XCTAssertNil(KitApiClient.authHeader("   "))
        XCTAssertEqual(KitApiClient.authHeader(" abc "), "Bearer abc")
    }

    func testA401IsThePromptForTheTokenOrARefusedOne() async {
        let unauthorized = KitApiClient.Response(code: 401, body: #"{"error":"api token required"}"#)
        let none = await KitProbe.check(KitApiClient(baseUrl: "kit-a", token: "", http: FakeKit([unauthorized])), hasToken: false)
        XCTAssertEqual(none, .needsToken)
        XCTAssertTrue(KitProbe.asksForToken(none))
        XCTAssertEqual(KitProbe.line(none), "This kit asks for its API token: enter it above and check again.")

        let wrong = await KitProbe.check(
            KitApiClient(baseUrl: "kit-a", token: "not-the-one", http: FakeKit([unauthorized])), hasToken: true)
        XCTAssertEqual(wrong, .wrongToken)
        XCTAssertTrue(KitProbe.asksForToken(wrong))

        let down = await KitProbe.check(
            KitApiClient(baseUrl: "kit-a", token: token, http: FakeKit([KitApiClient.Response(code: 503, body: "busy")])), hasToken: true)
        XCTAssertEqual(down, .unreachable("HTTP 503"))
        XCTAssertFalse(KitProbe.asksForToken(down))
    }

    func testTheTokenReachesNoLogLineNoDescriptionAndNoErrorMessage() async {
        let lines = Lines()
        let client = KitApiClient(
            baseUrl: "kit-a", token: token, http: FakeKit([KitApiClient.Response(code: 401, body: "no")]), log: { lines.add($0) })
        _ = try? await client.get("/api/status")
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all[0].contains("401") && lines.all[0].contains("token sent"), lines.all[0])
        XCTAssertFalse(client.description.contains(token))
        XCTAssertTrue(client.description.contains("token set"))

        // A connection that fails, even with the token in the transport's own text: scrubbed.
        let dead = KitApiClient(
            baseUrl: "kit-a", token: token, http: FakeKit(failure: "could not connect to kit-a with \(token)"), log: { lines.add($0) })
        let r = await KitProbe.check(dead, hasToken: true)
        guard case .unreachable = r else { return XCTFail("expected unreachable, got \(r)") }
        let all = lines.all.joined(separator: "\n") + "\n" + KitProbe.line(r)
        XCTAssertFalse(all.contains(token), all)
        XCTAssertEqual(dead.scrub("a \(token) b"), "a <token> b")
    }

    func testAddressesAsPeopleTypeThemBecomeTheKitsBaseURL() {
        XCTAssertEqual(KitApiClient.normalizeBase("192.168.1.20"), "http://192.168.1.20:6050")
        XCTAssertEqual(KitApiClient.normalizeBase(" http://192.168.1.20/ "), "http://192.168.1.20:6050")
        XCTAssertEqual(KitApiClient.normalizeBase("kit-a.local:6050/"), "http://kit-a.local:6050")
        XCTAssertEqual(KitApiClient.normalizeBase("kit-a:7000"), "http://kit-a:7000")
        XCTAssertEqual(KitApiClient.normalizeBase("https://kit.example.net:443"), "https://kit.example.net:443")
        XCTAssertEqual(KitApiClient.normalizeBase("https://kit.example.net"), "https://kit.example.net:6050")
        XCTAssertEqual(KitApiClient.normalizeBase("[fe80::1]"), "http://[fe80::1]:6050")
        XCTAssertEqual(KitApiClient.normalizeBase("  "), "")
        XCTAssertEqual(KitConnection(id: "k1", name: "tesseract", url: "192.168.1.20").base, "http://192.168.1.20:6050")
    }

    func testTheKitListRoundTripsWithoutAnyTokenInIt() {
        let a = KitConnection.create(name: "tesseract", url: "192.168.1.20")
        let b = KitConnection.create(name: "parallax", url: "parallax.local")
        let s = KitConnection.encodeList([a, b])
        XCTAssertFalse(s.contains("token"))
        XCTAssertEqual(KitConnection.decodeList(s), [a, b])
        XCTAssertEqual(KitConnection.decodeList(""), [])
        XCTAssertEqual(KitConnection.decodeList("not json"), [])
        XCTAssertEqual(KitConnection.decodeList(#"[{"name":"no id"}]"#), [])
        // Android's own encoding (JSONArray of id, name, url) reads here.
        XCTAssertEqual(
            KitConnection.decodeList(#"[{"id":"ab12cd34","name":"kit","url":"10.0.0.2"}]"#),
            [KitConnection(id: "ab12cd34", name: "kit", url: "10.0.0.2")])
        XCTAssertEqual(KitConnection.tokenKey(a.id), "kit_api_token:\(a.id)")
        XCTAssertEqual(a.id.count, 8)
        XCTAssertEqual(SettingsKey.kitsLan.key, "kits_lan")
    }
}
