// Mirrors hub/directory/HubDirectoryStore.kt and HubDirectoryClient.kt (MESHSAT-1643).
import Foundation
import MeshSatNet

/// The directory as one JSON file, written whole and atomically, so a crash leaves the last
/// state or the new one, never half of each. The file is Android's format.
public final class HubDirectoryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var state: DirectoryState
    /// Every state saved, the current one first to each new subscriber (the screen that shows it).
    public let changes: StateBroadcast<DirectoryState>

    public init(url: URL) {
        self.url = url
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DirectoryState.self, from: $0) } ?? DirectoryState()
        state = loaded
        changes = StateBroadcast(loaded)
    }

    public var current: DirectoryState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func save(_ s: DirectoryState) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(s)
    }

    /// Apply `f` to the current state and save what it returns, as one step.
    @discardableResult
    public func update(_ f: (DirectoryState) -> DirectoryState) throws -> DirectoryState {
        lock.lock()
        defer { lock.unlock() }
        let next = f(state)
        if next != state { try write(next) }
        return next
    }

    private func write(_ s: DirectoryState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
        state = s
        changes.send(s)
    }
}

/// The phone's side of the Hub's signed directory (HeMB-NG C9.5): the Hub pushes nothing to a
/// phone, so it reads `GET /api/relay/directory` with its own bridge credentials and applies the
/// answer the way a Bridge applies a push (meshsat-hub docs/bridge-hub-protocol.md, "The phones
/// read it").
///
/// The key: the one in the provisioning bundle (`dir_sign_pub`) is pinned when the bundle is
/// applied (applyProvisioning, which also sets the context the directory belongs to). Only a phone
/// with none pinned takes it once from `GET /api/relay/directory-key` over HTTPS, with the key
/// hashing to its id; after that only a rotation record signed by the pinned key, or a new
/// provisioning, moves it. `http` must not follow redirects: any 3xx is refused here.
public struct HubDirectoryClient: Sendable {
    public enum Outcome: Equatable, Sendable {
        case notModified
        case applied(DirectoryApply.Result)
        case refused(DirectoryApply.Result)
        case failed(String)
    }

    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// A directory of a few thousand contacts; anything larger is refused.
    public static let maxBody = 4 * 1024 * 1024

    let store: HubDirectoryStore
    let http: any HttpGetter
    let now: @Sendable () -> Int64
    let requireHttps: Bool
    let timeoutSeconds: Double

    /// `requireHttps` is false only in tests.
    public init(
        store: HubDirectoryStore, http: any HttpGetter,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        requireHttps: Bool = true, timeoutSeconds: Double = 15
    ) {
        self.store = store
        self.http = http
        self.now = now
        self.requireHttps = requireHttps
        self.timeoutSeconds = timeoutSeconds
    }

    /// A provisioning bundle was applied (r40 review R40-R3). Scanning a provisioning code is a
    /// deliberate act with a single-use claim over HTTPS, so it sets the context the directory
    /// belongs to. A new `context` (another broker, bridge id, topic root or tenant) starts the
    /// directory over even when the signing key is the same, as every tenant of a Hub shares it:
    /// the held contacts, versions and tenant go, the bundle's key is pinned, or none when the
    /// bundle has none (the HTTPS bootstrap then fetches the new Hub's once), and only snapshots of
    /// `tenant` are taken. The same context keeps the directory, and pins the bundle's key when none
    /// is pinned; a different key in the same context starts over too.
    @discardableResult
    public func applyProvisioning(context: String, tenant: String, pkix: [UInt8]?) throws -> DirectoryState {
        if let pkix { _ = try DirectoryEnvelope.p256(pkix) }
        let b64 = pkix.map { Data($0).base64EncodedString() }
        return try store.update { s in
            let sameContext = s.context == context && s.expectedTenant == tenant
            if sameContext && (b64 == nil || s.pinnedKey == b64) { return s }
            if sameContext && s.pinnedKey.isEmpty, let b64 {
                var next = s
                next.pinnedKey = b64
                next.pinSource = "bundle"
                return next
            }
            var fresh = DirectoryState()
            fresh.context = context
            fresh.expectedTenant = tenant
            fresh.pinnedKey = b64 ?? ""
            fresh.pinSource = b64 == nil ? "" : "bundle"
            return fresh
        }
    }

    /// The context a provisioning bundle sets: the broker, the bridge id, the topic root and the
    /// tenant. A change in any of them is another directory (r40 review R40-R3).
    public static func provisioningContext(mqttUrl: String, bridgeId: String, topicPrefix: String, tenant: String) -> String {
        [mqttUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), bridgeId, topicPrefix, tenant].joined(separator: "|")
    }

    /// Take the Hub's key over HTTPS, only while none is pinned.
    public func bootstrap(hubApiBase: String) async throws {
        if !store.current.pinnedKey.isEmpty { return }
        let context = store.current.context
        let resp = try await http.get(
            try endpoint(hubApiBase, "/api/relay/directory-key"), headers: headers(), timeoutSeconds: timeoutSeconds)
        guard resp.status == 200 else { throw Failure("GET /api/relay/directory-key answered HTTP \(resp.status)") }
        guard let k = DirectoryEnvelope.object(try capped(resp.body)), let pkix = DirectoryEnvelope.bytes(k, "pkix") else {
            throw Failure("directory key: no pkix")
        }
        guard k["alg"] as? String == DirectoryEnvelope.alg, DirectoryEnvelope.keyId(pkix) == k["key_id"] as? String ?? "" else {
            throw Failure("directory key: the key does not hash to its id")
        }
        _ = try DirectoryEnvelope.p256(pkix)
        let b64 = Data(pkix).base64EncodedString()
        // A bundle that landed meanwhile wins: this only fills an empty pin, in the context the
        // fetch started in.
        try store.update { s in
            guard s.pinnedKey.isEmpty, s.context == context else { return s }
            var next = s
            next.pinnedKey = b64
            next.pinSource = "https"
            return next
        }
    }

    /// One read of the tenant's directory; bootstraps the key first when none is pinned.
    public func poll(hubApiBase: String, bridgeId: String, password: String) async -> Outcome {
        do {
            try await bootstrap(hubApiBase: hubApiBase)
            let held = store.current
            if held.pinnedKey.isEmpty { return .failed("no directory key") }
            // The answer applies only to the context it was asked in: a provisioning that lands
            // while it is out starts the directory over, and nothing of the old one comes back.
            let context = held.context
            let path = "/api/relay/directory?since=\(held.version)&key_id=" + RelayTunnel.formEncode(held.keyId)
            var hdrs = headers()
            hdrs["Authorization"] = RelayTunnel.basicAuth(bridgeId, password)
            let resp = try await http.get(try endpoint(hubApiBase, path), headers: hdrs, timeoutSeconds: timeoutSeconds)
            switch resp.status {
            case 304:
                let t = now()
                try store.update { s in
                    guard s.context == context else { return s }
                    var next = s
                    next.checkedAt = t
                    return next
                }
                return .notModified
            case 200:
                guard let answer = DirectoryEnvelope.object(try capped(resp.body)) else {
                    return .failed("the directory answer is not JSON")
                }
                let t = now()
                var result: DirectoryApply.Result?
                try store.update { s in
                    guard s.context == context else { return s }
                    let r = DirectoryApply.answer(s, answer, now: t)
                    result = r
                    var next = r.state
                    next.checkedAt = t
                    return next
                }
                guard let r = result else { return .failed("the provisioning changed while the directory was read; answer dropped") }
                return r.reason.isEmpty ? .applied(r) : .refused(r)
            default:
                return .failed("GET /api/relay/directory answered HTTP \(resp.status)")
            }
        } catch let e as Failure {
            return .failed(e.message)
        } catch let e as DirectoryEnvelope.Refused {
            return .failed(e.description)
        } catch {
            return .failed("\(error)")
        }
    }

    func endpoint(_ hubApiBase: String, _ path: String) throws -> String {
        let base = RelayTunnel.normalizeBase(hubApiBase)
        guard let c = URLComponents(string: base), let host = c.host, !host.isEmpty, c.user == nil,
            !requireHttps || c.scheme?.lowercased() == "https"
        else { throw Failure("the Hub API URL \(base) is not an https URL") }
        return base + path
    }

    func headers() -> [String: String] { ["Accept": "application/json", "User-Agent": "meshsat-ios-directory"] }

    func capped(_ body: [UInt8]) throws -> [UInt8] {
        guard body.count <= Self.maxBody else { throw Failure("the directory answer is over \(Self.maxBody / 1024) KiB") }
        return body
    }
}
