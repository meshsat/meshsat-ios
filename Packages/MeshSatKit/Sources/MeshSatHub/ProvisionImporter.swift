// Mirrors crypto/ProvisionImporter.kt: two-step Hub provisioning from a QR code or a deep link.
//
// Step 1: the code or link carries meshsat://provision/{bid}/{nonce}?hub={host}.
// Step 2: the app claims the credentials with GET https://{hub}/api/bridges/{bid}/provision/{nonce}.
// The nonce is single-use (the Hub deletes the stash after the claim) with a 30 minute TTL.
// HTTP and time are injected so the loop runs on Linux in the tests.
import Foundation
import MeshSatNet

public enum ProvisionImporter {
    public static let urlPrefix = "meshsat://provision/"
    /// How long a scan may wait for the Hub to be ready before it gives up (MESHSAT-1298).
    public static let claimWaitMaxMs: Int64 = 120_000

    /// The claim parameters of a code or link; no credentials yet.
    public struct ProvisionRequest: Sendable, Equatable {
        public let bridgeId: String
        public let nonce: String
        public let hubHost: String
        public init(bridgeId: String, nonce: String, hubHost: String) {
            self.bridgeId = bridgeId
            self.nonce = nonce
            self.hubHost = hubHost
        }
        public var claimUrl: String { "https://\(hubHost)/api/bridges/\(bridgeId)/provision/\(nonce)" }
    }

    /// The credential bundle the Hub hands out.
    public struct ProvisionBundle: Sendable, Equatable {
        public var version = "1"
        public var bridgeId = ""
        public var mqttUrl = ""
        public var username = ""
        public var password = ""
        public var clientCertPem = ""
        public var clientKeyPem = ""
        public var caCertPem = ""
        public var certExpiry = ""
        public var reticulumTcp = ""
        /// "meshsat", or "meshsat/{tenant}" for a customer tenant; every topic hangs off it.
        public var topicPrefix = HubTopics.platformPrefix
        public init() {}
    }

    /// Android's ProvisionException and IllegalArgumentException, with the words the user sees.
    public struct ProvisionError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// A scanned string that is a provisioning code or link.
    public static func isProvisionUrl(_ url: String) -> Bool { url.hasPrefix(urlPrefix) }

    /// The claim parameters of a `meshsat://provision/` deep link, for a caller that shows them
    /// before anything is fetched (MESHSAT-1235). Any app or page can fire a link, unlike a QR
    /// the user chose to scan, so only the nonce form is accepted: an inline bundle carries the
    /// credentials in the link itself.
    public static func parseLink(_ url: String) throws -> ProvisionRequest {
        guard url.hasPrefix(urlPrefix) else { throw ProvisionError("Not a MeshSat provisioning link") }
        let payload = String(url.dropFirst(urlPrefix.count))
        guard payload.contains("?hub=") else { throw ProvisionError("Inline provisioning codes must be scanned in Settings") }
        return try parseNonceUrl(payload)
    }

    /// The bundle of a scanned code, claiming it from the Hub when the code is the nonce form.
    public static func processQr(
        _ url: String, http: any HttpGetter, onWaiting: (@Sendable (Int) -> Void)? = nil,
        sleep: @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) async throws -> ProvisionBundle {
        guard url.hasPrefix(urlPrefix) else { throw ProvisionError("Not a MeshSat provisioning QR code") }
        let payload = String(url.dropFirst(urlPrefix.count))
        if payload.contains("?hub=") {
            return try await claimBundle(try parseNonceUrl(payload), http: http, onWaiting: onWaiting, sleep: sleep, now: now)
        }
        return try parseInlineBundle(payload)
    }

    /// The v2.2.0 format: the bundle itself, base64url JSON, in the code.
    static func parseInlineBundle(_ encoded: String) throws -> ProvisionBundle {
        var b64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw ProvisionError("Not a MeshSat provisioning QR code") }
        return try parseBundle(data)
    }

    /// {bid}/{nonce}?hub={host}
    static func parseNonceUrl(_ payload: String) throws -> ProvisionRequest {
        guard let q = payload.firstIndex(of: "?"), q > payload.startIndex else { throw ProvisionError("Missing ?hub= parameter") }
        let path = payload[..<q]
        let query = payload[payload.index(after: q)...]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ProvisionError("Expected {bid}/{nonce}") }
        let bid = String(parts[0])
        let nonce = String(parts[1])
        guard !bid.trimmingCharacters(in: .whitespaces).isEmpty else { throw ProvisionError("Empty bridge ID") }
        guard nonce.count == 32, nonce.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ProvisionError("Invalid nonce: must be 32 hex chars")
        }
        var hubHost = ""
        for param in query.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2, kv[0] == "hub" { hubHost = String(kv[1]) }
        }
        guard !hubHost.trimmingCharacters(in: .whitespaces).isEmpty else { throw ProvisionError("Missing hub host") }
        return ProvisionRequest(bridgeId: bid, nonce: nonce, hubHost: hubHost)
    }

    /// Claim the bundle. No auth header: the nonce is the authentication, and the Hub deletes
    /// the stash after this call. The Hub answers 503 with Retry-After while its broker has not
    /// yet accepted the new password; the claim stays valid and the same link works a few
    /// seconds later (MESHSAT-1298, measured up to 53 s). That is a wait, not a failed scan.
    public static func claimBundle(
        _ request: ProvisionRequest, http: any HttpGetter, onWaiting: (@Sendable (Int) -> Void)? = nil,
        sleep: @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) async throws -> ProvisionBundle {
        let deadlineMs = now() + claimWaitMaxMs
        var attempt = 0
        while true {
            attempt += 1
            switch try await claimOnce(request, http: http) {
            case .done(let bundle):
                return bundle
            case .notYet(let retryAfterSec):
                let waitMs = claimRetryDelayMs(retryAfterSec)
                if now() + waitMs > deadlineMs {
                    throw ProvisionError(
                        "The Hub is still getting the new credentials ready. Wait a minute, then scan the same code again.")
                }
                onWaiting?(attempt)
                try await sleep(waitMs)
            }
        }
    }

    enum Claim: Equatable {
        case done(ProvisionBundle)
        case notYet(Int?)
    }

    static func claimOnce(_ request: ProvisionRequest, http: any HttpGetter) async throws -> Claim {
        let response: HttpResponse
        do {
            response = try await http.get(request.claimUrl, headers: ["Accept": "application/json"], timeoutSeconds: 10)
        } catch {
            throw ProvisionError("Cannot reach Hub at \(request.hubHost). Check network connectivity.")
        }
        switch response.status {
        case 200:
            return .done(try parseBundle(Data(response.body)))
        case 503:
            let retry = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
            return .notYet(retry.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        case 404:
            throw ProvisionError("Provisioning token expired or already used. Generate a new QR from the Hub.")
        case 410:
            throw ProvisionError("Provisioning token expired (>30 minutes). Generate a new QR.")
        default:
            throw ProvisionError("Hub returned HTTP \(response.status). Try again or generate a new QR.")
        }
    }

    /// The JSON the claim endpoint answers: v, bid, mqtt, user, pass, cert, key, ca, cert_exp, ret_tcp.
    static func parseBundle(_ data: Data) throws -> ProvisionBundle {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProvisionError("The Hub's answer was not a provisioning bundle")
        }
        func str(_ key: String, _ fallback: String = "") -> String {
            if let s = json[key] as? String { return s }
            if let n = json[key] as? NSNumber { return n.stringValue }
            return fallback
        }
        var b = ProvisionBundle()
        b.version = str("v", "1")
        b.bridgeId = str("bid")
        b.mqttUrl = str("mqtt")
        b.username = str("user")
        b.password = str("pass")
        b.clientCertPem = str("cert")
        b.clientKeyPem = str("key")
        b.caCertPem = str("ca")
        b.certExpiry = str("cert_exp")
        b.reticulumTcp = str("ret_tcp")
        b.topicPrefix = str("mqtt_topic_prefix", HubTopics.platformPrefix)
        return b
    }

    /// The Hub's Retry-After, kept between 1 and 15 s; 5 s when it names none. Pure, so it has a test.
    public static func claimRetryDelayMs(_ retryAfterSec: Int?) -> Int64 {
        Int64(min(15, max(1, retryAfterSec ?? 5))) * 1000
    }
}
