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
/// applied. Only a phone with none pinned takes it once from `GET /api/relay/directory-key` over
/// HTTPS, with the key hashing to its id; after that only a rotation record signed by the pinned
/// key moves it. `http` must not follow redirects: any 3xx is refused here.
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

    /// Pin the key a provisioning bundle carries. The bundle came from the Hub over HTTPS with a
    /// single-use claim, so it outranks a key fetched on its own; a different key than the pinned
    /// one starts the directory over (a new provisioning can be another tenant).
    @discardableResult
    public func pinFromBundle(_ pkix: [UInt8]) throws -> DirectoryState {
        _ = try DirectoryEnvelope.p256(pkix)
        let b64 = Data(pkix).base64EncodedString()
        return try store.update { s in
            if s.pinnedKey == b64 {
                var same = s
                if same.pinSource == "https" { same.pinSource = "bundle" }
                return same
            }
            var fresh = DirectoryState()
            fresh.pinnedKey = b64
            fresh.pinSource = "bundle"
            return fresh
        }
    }

    /// Take the Hub's key over HTTPS, only while none is pinned.
    public func bootstrap(hubApiBase: String) async throws {
        if !store.current.pinnedKey.isEmpty { return }
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
        // A bundle that landed meanwhile wins: this only fills an empty pin.
        try store.update { s in
            guard s.pinnedKey.isEmpty else { return s }
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
            let path = "/api/relay/directory?since=\(held.version)&key_id=" + RelayTunnel.formEncode(held.keyId)
            var hdrs = headers()
            hdrs["Authorization"] = RelayTunnel.basicAuth(bridgeId, password)
            let resp = try await http.get(try endpoint(hubApiBase, path), headers: hdrs, timeoutSeconds: timeoutSeconds)
            switch resp.status {
            case 304:
                let t = now()
                try store.update { s in
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
                    let r = DirectoryApply.answer(s, answer, now: t)
                    result = r
                    var next = r.state
                    next.checkedAt = t
                    return next
                }
                guard let r = result else { return .failed("not applied") }
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
