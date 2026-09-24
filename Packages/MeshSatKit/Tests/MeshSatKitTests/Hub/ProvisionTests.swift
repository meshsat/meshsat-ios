// Ports ProvisionLinkTest.kt and ProvisionClaimRetryTest.kt, and covers the claim loop and the
// claim state machine with a fake Hub.
import Foundation
import MeshSatNet
import XCTest

@testable import MeshSatHub

private let nonce = "0123456789abcdef0123456789abcdef"

/// A Hub that answers the claim with a scripted list of responses, then repeats the last.
final class FakeHttp: HttpGetter, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<HttpResponse, ByteStreamError>]
    private(set) var urls: [String] = []
    init(_ script: [Result<HttpResponse, ByteStreamError>]) { self.script = script }

    func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> HttpResponse {
        try take(url).get()
    }

    private func take(_ url: String) -> Result<HttpResponse, ByteStreamError> {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
        return script.count > 1 ? script.removeFirst() : script[0]
    }
}

private let bundleJson = """
    {"v":"1","bid":"msa-flaneur","mqtt":"ssl://hub.meshsat.net:8883","user":"u","pass":"p",
     "cert":"CERT","key":"KEY","ca":"CA","cert_exp":"2027-01-01","ret_tcp":"hub.meshsat.net:4242"}
    """

final class ProvisionLinkTests: XCTestCase {
    func testNonceLinkYieldsBridgeNonceAndClaimHost() throws {
        let req = try ProvisionImporter.parseLink("meshsat://provision/msa-flaneur/\(nonce)?hub=hub.meshsat.net")
        XCTAssertEqual(req.bridgeId, "msa-flaneur")
        XCTAssertEqual(req.nonce, nonce)
        XCTAssertEqual(req.hubHost, "hub.meshsat.net")
        XCTAssertEqual(req.claimUrl, "https://hub.meshsat.net/api/bridges/msa-flaneur/provision/\(nonce)")
    }

    func testInlineBundleLinkIsRefused() {
        XCTAssertThrowsError(try ProvisionImporter.parseLink("meshsat://provision/eyJicmlkZ2VfaWQiOiJ4In0"))
    }

    func testLinkWithoutAClaimHostIsRefused() {
        XCTAssertThrowsError(try ProvisionImporter.parseLink("meshsat://provision/msa-flaneur/\(nonce)?hub="))
    }

    func testMalformedNonceIsRefused() {
        XCTAssertThrowsError(try ProvisionImporter.parseLink("meshsat://provision/msa-flaneur/not-a-nonce?hub=hub.meshsat.net"))
    }

    func testOtherSchemesAreRefused() {
        XCTAssertThrowsError(try ProvisionImporter.parseLink("https://hub.meshsat.net/api/bridges/msa-flaneur/provision/\(nonce)"))
        XCTAssertFalse(ProvisionImporter.isProvisionUrl("https://hub.meshsat.net/"))
        XCTAssertTrue(ProvisionImporter.isProvisionUrl("meshsat://provision/x/y?hub=z"))
    }

    func testInlineBundleIsParsedFromAScan() async throws {
        let encoded = Data(bundleJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let bundle = try await ProvisionImporter.processQr("meshsat://provision/" + encoded, http: FakeHttp([.failure(.closed)]))
        XCTAssertEqual(bundle.bridgeId, "msa-flaneur")
        XCTAssertEqual(bundle.mqttUrl, "ssl://hub.meshsat.net:8883")
        XCTAssertEqual(bundle.reticulumTcp, "hub.meshsat.net:4242")
        XCTAssertEqual(bundle.certExpiry, "2027-01-01")
    }
}

final class ProvisionClaimRetryTests: XCTestCase {
    func testTheHubsRetryAfterIsHonouredWithinSaneBounds() {
        XCTAssertEqual(ProvisionImporter.claimRetryDelayMs(5), 5_000)
        XCTAssertEqual(ProvisionImporter.claimRetryDelayMs(nil), 5_000)
        XCTAssertEqual(ProvisionImporter.claimRetryDelayMs(0), 1_000)
        XCTAssertEqual(ProvisionImporter.claimRetryDelayMs(600), 15_000)
    }

    func testAScanWaitsLongEnoughForTheSlowestBrokerMeasured() {
        // Members accepted a new credential after 4.3, 28.2 and 52.8 s on 21 Sep 2026.
        XCTAssertGreaterThanOrEqual(ProvisionImporter.claimWaitMaxMs, 2 * 53_000)
    }

    private let request = ProvisionImporter.ProvisionRequest(bridgeId: "msa-flaneur", nonce: nonce, hubHost: "hub.meshsat.net")

    func testA503IsAWaitNotAFailure() async throws {
        let http = FakeHttp([
            .success(HttpResponse(status: 503, headers: ["Retry-After": "3"])),
            .success(HttpResponse(status: 503)),
            .success(HttpResponse(status: 200, body: Array(bundleJson.utf8))),
        ])
        let slept = Slept()
        let waits = Slept()
        let bundle = try await ProvisionImporter.claimBundle(
            request, http: http, onWaiting: { waits.add(Int64($0)) }, sleep: { slept.add($0) }, now: { 0 })
        XCTAssertEqual(bundle.username, "u")
        XCTAssertEqual(slept.values, [3_000, 5_000])
        XCTAssertEqual(waits.values, [1, 2])
        XCTAssertEqual(http.urls.count, 3)
        XCTAssertEqual(http.urls[0], request.claimUrl)
    }

    func testTheWaitGivesUpAtTheDeadline() async {
        let http = FakeHttp([.success(HttpResponse(status: 503, headers: ["retry-after": "15"]))])
        let clock = Slept()
        do {
            _ = try await ProvisionImporter.claimBundle(
                request, http: http, sleep: { clock.add($0) }, now: { clock.values.reduce(0, +) })
            XCTFail("expected the deadline")
        } catch let e as ProvisionImporter.ProvisionError {
            XCTAssertTrue(e.message.hasPrefix("The Hub is still getting the new credentials ready"))
        } catch {
            XCTFail("\(error)")
        }
        // 15 s a round, eight rounds fit in 120 s; the ninth would pass the deadline.
        XCTAssertEqual(clock.values.count, 8)
    }

    func testTheHubsStatusesHaveTheirWords() async {
        let cases = [
            (404, "Provisioning token expired or already used"), (410, "Provisioning token expired (>30"),
            (500, "Hub returned HTTP 500"),
        ]
        for (status, prefix) in cases {
            do {
                _ = try await ProvisionImporter.claimBundle(request, http: FakeHttp([.success(HttpResponse(status: status))]))
                XCTFail("expected an error for \(status)")
            } catch let e as ProvisionImporter.ProvisionError {
                XCTAssertTrue(e.message.hasPrefix(prefix), e.message)
            } catch {
                XCTFail("\(error)")
            }
        }
        do {
            _ = try await ProvisionImporter.claimBundle(request, http: FakeHttp([.failure(.refused("down"))]))
            XCTFail("expected an error")
        } catch let e as ProvisionImporter.ProvisionError {
            XCTAssertEqual(e.message, "Cannot reach Hub at hub.meshsat.net. Check network connectivity.")
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class Slept: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Int64] = []
    func add(_ v: Int64) {
        lock.lock()
        values.append(v)
        lock.unlock()
    }
}

final class FakeApplier: ProvisionApplier, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var applied: [ProvisionImporter.ProvisionBundle] = []
    var fail = false
    func apply(_ bundle: ProvisionImporter.ProvisionBundle) async throws {
        try record(bundle)
    }

    private func record(_ bundle: ProvisionImporter.ProvisionBundle) throws {
        lock.lock()
        defer { lock.unlock() }
        if fail { throw ProvisionImporter.ProvisionError("disk full") }
        applied.append(bundle)
    }
}

final class ProvisionClaimTests: XCTestCase {
    private func wait(for claim: ProvisionClaim, _ test: @escaping (ProvisionClaim.State) -> Bool) async -> ProvisionClaim.State {
        for _ in 0..<200 {
            if test(claim.state.value) { return claim.state.value }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return claim.state.value
    }

    func testALinkClaimsWaitsAndApplies() async {
        let http = FakeHttp([
            .success(HttpResponse(status: 503, headers: ["Retry-After": "1"])),
            .success(HttpResponse(status: 200, body: Array(bundleJson.utf8))),
        ])
        let applier = FakeApplier()
        let claim = ProvisionClaim(http: http, applier: applier, now: { 1_000 }, sleep: { _ in })
        claim.fromLink(ProvisionImporter.ProvisionRequest(bridgeId: "msa-flaneur", nonce: nonce, hubHost: "hub.meshsat.net"))
        let end = await wait(for: claim) { if case .applied = $0 { return true } else { return false } }
        XCTAssertEqual(end, .applied(bridgeId: "msa-flaneur"))
        XCTAssertEqual(applier.applied.count, 1)
    }

    func testAScanAsksForConfirmationThenApplies() async {
        let http = FakeHttp([.success(HttpResponse(status: 200, body: Array(bundleJson.utf8)))])
        let applier = FakeApplier()
        let claim = ProvisionClaim(http: http, applier: applier, now: { 1_000 }, sleep: { _ in })
        claim.fromQr("meshsat://provision/msa-flaneur/\(nonce)?hub=hub.meshsat.net")
        let ready = await wait(for: claim) { if case .ready = $0 { return true } else { return false } }
        guard case .ready(let bundle) = ready else { return XCTFail("\(ready)") }
        XCTAssertEqual(bundle.bridgeId, "msa-flaneur")
        XCTAssertTrue(applier.applied.isEmpty)
        claim.apply()
        if case .ready = claim.state.value { XCTFail("the dialog must go at once") }  // idle, or already applied under load
        let end = await wait(for: claim) { if case .applied = $0 { return true } else { return false } }
        XCTAssertEqual(end, .applied(bridgeId: "msa-flaneur"))
        claim.apply()  // a second tap applies nothing
        XCTAssertEqual(applier.applied.count, 1)
    }

    func testAFailedClaimSaysWhyAndDismissClears() async {
        let claim = ProvisionClaim(
            http: FakeHttp([.success(HttpResponse(status: 404))]), applier: FakeApplier(), now: { 0 }, sleep: { _ in })
        claim.fromLink(ProvisionImporter.ProvisionRequest(bridgeId: "b", nonce: nonce, hubHost: "h"))
        let end = await wait(for: claim) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let m) = end else { return XCTFail("\(end)") }
        XCTAssertTrue(m.hasPrefix("Provisioning token expired or already used"))
        claim.dismiss()
        XCTAssertEqual(claim.state.value, .idle)
    }

    func testAFailedApplyIsReported() async {
        let applier = FakeApplier()
        applier.fail = true
        let http = FakeHttp([.success(HttpResponse(status: 200, body: Array(bundleJson.utf8)))])
        let claim = ProvisionClaim(http: http, applier: applier, now: { 0 }, sleep: { _ in })
        claim.fromLink(ProvisionImporter.ProvisionRequest(bridgeId: "b", nonce: nonce, hubHost: "h"))
        let end = await wait(for: claim) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let m) = end else { return XCTFail("\(end)") }
        XCTAssertTrue(m.hasPrefix("Could not save the Hub settings"))
    }
}
