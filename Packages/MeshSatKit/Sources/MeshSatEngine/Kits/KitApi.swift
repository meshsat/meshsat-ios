// Mirrors kit/KitApiClient.kt and kit/KitConnection.kt (MESHSAT-1738, iOS MESHSAT-1820): a field
// kit this phone reaches directly on the LAN, plain HTTP to port 6050, with the kit's API token as
// `Authorization: Bearer <token>` on every request when the phone holds one. A kit with no token
// set answers as before; a kit with one answers 401 to a request without it, and that 401 is what
// the kit card turns into its one-line prompt (`KitProbe`).
//
// Through the Hub relay nothing of this applies: the tunnel is the credential and no token is sent.
// The token goes on the wire and nowhere else: not in `description`, not in the log callback, not
// in an error's text. The HTTP itself is `KitHttp`, URLSession on the phone (never following a
// redirect), a fake in the tests.
import Foundation

/// One HTTP exchange with a kit. The implementation never follows a redirect.
public protocol KitHttp: Sendable {
    func request(
        method: String, url: String, headers: [String: String], body: [UInt8]?, timeoutSeconds: Double
    ) async throws -> KitApiClient.Response
}

/// Why a request to a kit did not get an answer; the text names the host and the failure, never the token.
public struct KitRequestError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public final class KitApiClient: Sendable, CustomStringConvertible {
    /// The Bridge's port.
    public static let defaultPort = 6050
    static let maxBody = 256 * 1024

    public struct Response: Sendable, Equatable {
        public let code: Int
        public let body: String
        public init(code: Int, body: String) {
            self.code = code
            self.body = body
        }
        /// The kit asks for its API token (`WWW-Authenticate: Bearer realm="meshsat"`).
        public var needsToken: Bool { code == 401 }
        public var ok: Bool { (200...299).contains(code) }
    }

    public let base: String
    private let token: String
    private let timeoutSeconds: Double
    private let http: any KitHttp
    private let log: @Sendable (String) -> Void

    public init(
        baseUrl: String, token: String = "", http: any KitHttp, timeoutSeconds: Double = 8,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.base = Self.normalizeBase(baseUrl)
        self.token = token
        self.http = http
        self.timeoutSeconds = timeoutSeconds
        self.log = log
    }

    public func get(_ path: String) async throws -> Response { try await request("GET", path, nil) }

    public func post(_ path: String, json: String?) async throws -> Response { try await request("POST", path, json) }

    private func request(_ method: String, _ path: String, _ json: String?) async throws -> Response {
        let url = base + (path.hasPrefix("/") ? path : "/" + path)
        var headers = ["Accept": "application/json", "User-Agent": "meshsat-ios-kit"]
        if let auth = Self.authHeader(token) { headers["Authorization"] = auth }
        if json != nil { headers["Content-Type"] = "application/json" }
        do {
            let r = try await http.request(
                method: method, url: url, headers: headers, body: json.map { Array($0.utf8) }, timeoutSeconds: timeoutSeconds)
            log("\(method) \(path) -> \(r.code) (token \(token.isBlank ? "not sent" : "sent"))")
            return r
        } catch {
            // The message names the host and the failure, never the header.
            let text = scrub(String(describing: error))
            log("\(method) \(path) failed: \(text)")
            throw KitRequestError(text)
        }
    }

    /// A text with the token, if it ever got in, taken out.
    public func scrub(_ s: String) -> String { token.isBlank ? s : s.replacingOccurrences(of: token, with: "<token>") }

    public var description: String { "KitApiClient(\(base), token \(token.isBlank ? "not set" : "set"))" }

    /// The header's value for `token`, or nil when there is none to send.
    public static func authHeader(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : "Bearer \(t)"
    }

    /// "192.168.1.20", "kit-a.local:6050/", "http://kit-a" become "http://192.168.1.20:6050",
    /// "http://kit-a.local:6050", "http://kit-a:6050": a scheme when none is given, the Bridge's
    /// port when none is given, no trailing slash. An https URL is kept as typed.
    public static func normalizeBase(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if u.isEmpty { return "" }
        if !u.contains("://") { u = "http://" + u }
        guard let parsed = URLComponents(string: u), let scheme = parsed.scheme, var host = parsed.host, !host.isEmpty else {
            return u
        }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        var path = parsed.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(hostPart):\(parsed.port ?? defaultPort)" + path
    }
}

/// What one request to a kit says about reaching it: the kit card's line.
public enum KitProbe {
    public enum Result: Sendable, Equatable {
        /// The kit answered; the text is a word or two from `/api/status`.
        case reachable(String)
        /// 401 with no token held: the kit asks for its API token.
        case needsToken
        /// 401 with a token held: the kit refused it.
        case wrongToken
        case unreachable(String)
    }

    public static let statusPath = "/api/status"

    /// One GET of `/api/status`. `hasToken` says whether the client was given one.
    public static func check(_ client: KitApiClient, hasToken: Bool) async -> Result {
        do {
            let r = try await client.get(statusPath)
            if r.needsToken { return hasToken ? .wrongToken : .needsToken }
            if r.ok { return .reachable(summarise(r.body)) }
            return .unreachable("HTTP \(r.code)")
        } catch {
            return .unreachable(client.scrub(String(describing: error)))
        }
    }

    /// The one line under a kit on its card.
    public static func line(_ r: Result) -> String {
        switch r {
        case .reachable(let summary): summary.isEmpty ? "Reachable." : "Reachable: \(summary)"
        case .needsToken: "This kit asks for its API token: enter it above and check again."
        case .wrongToken: "The kit refused this API token. Check it on the kit (GET /api/auth/status) and enter it again."
        case .unreachable(let reason): "Not reachable: \(reason)"
        }
    }

    /// A line is a prompt for the token when the kit asked for one.
    public static func asksForToken(_ r: Result) -> Bool { r == .needsToken || r == .wrongToken }

    static func summarise(_ body: String) -> String {
        guard let data = body.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        func field(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return [field("bridge_id"), field("version").map { "v" + $0 }, field("mode")].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A field kit this phone reaches directly, on the LAN: a name, the kit's address, and an id the API
/// token is filed under in the Keychain. The token is never part of this record, so a settings export
/// or a log line that carries it carries no secret.
public struct KitConnection: Sendable, Equatable, Hashable, Codable {
    public let id: String
    public var name: String
    /// As typed; `KitApiClient.normalizeBase` makes it a base URL.
    public var url: String

    public init(id: String, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    public var base: String { KitApiClient.normalizeBase(url) }

    public static func create(name: String = "", url: String = "") -> KitConnection {
        KitConnection(id: String(UUID().uuidString.lowercased().prefix(8)), name: name, url: url)
    }

    /// Where the kit's API token lives in the Keychain.
    public static func tokenKey(_ id: String) -> String { "kit_api_token:\(id)" }

    /// `[{"id":..,"name":..,"url":..}]`, the JSON Android writes under `kits_lan`.
    public static func encodeList(_ list: [KitConnection]) -> String {
        let objects = list.map { ["id": $0.id, "name": $0.name, "url": $0.url] }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeList(_ s: String) -> [KitConnection] {
        guard !s.isBlank, let data = s.data(using: .utf8), let a = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }
        return a.compactMap { item in
            guard let o = item as? [String: Any], let id = o["id"] as? String, !id.isEmpty else { return nil }
            return KitConnection(id: id, name: o["name"] as? String ?? "", url: o["url"] as? String ?? "")
        }
    }
}

extension String {
    fileprivate var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
