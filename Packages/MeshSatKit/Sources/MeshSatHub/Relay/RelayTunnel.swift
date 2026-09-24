// Mirrors hub/relay/RelayTunnel.kt: the client end of a Hub WebSocket relay tunnel
// (MESHSAT-1157; contract: Hub docs/relay.md, MESHSAT-612).
//
// Opens wss://<hub>/api/relay/connect/<targetBridgeId> with HTTP Basic <ownBridgeId>:<hub MQTT
// password>. Frames on this socket are the bare payload in both directions, at most 64 KiB;
// anything the phone sends is chunked at 32 KiB.
//
// Android has two ways to use the bytes: a loopback port that RelayHttp speaks TLS+HTTP/1.1
// through, and frames straight to a listener. Only the frames mode is here: it is what
// RelayBridgeTransport carries Reticulum packets with. iOS has no loopback server socket to
// hand a URL session, so the request-through-the-tunnel probe (RelayHttp, RelayProbe,
// RelayTls) will stack TLS on the frames directly when the diagnostics screen needs it.
import Foundation
import MeshSatNet

public final class RelayTunnel: @unchecked Sendable {
    /// Largest frame the Hub accepts from either end.
    public static let maxFrame = 64 * 1024
    /// Chunk size for the stream inside the tunnel (contract: 32 KiB).
    public static let chunk = 32 * 1024
    /// Hub pings every 30 s and closes after 60 s of silence; the transport answers pings itself.
    public static let connectTimeoutSeconds: Double = 15

    public enum CloseReason: String, Sendable, Equatable {
        /// 1000: the Hub closed normally (restart, read loop ended).
        case normal
        /// 1001: the same identity opened a newer socket.
        case superseded
        /// 1003: the Hub refused a frame (not binary, too large).
        case badFrame
        /// 1008: 100 frames/minute spent for this client id.
        case budget
        /// The Hub went silent or the transport failed.
        case error
        /// This end closed: `close()` or the local side went away.
        case local
    }

    public enum RelayState: Sendable, Equatable {
        case connecting
        /// The socket is up. Android's local port is 0 here: frames mode only.
        case open
        case closed(reason: CloseReason, detail: String)
        /// The Hub answered before the upgrade: 401, 403, 429 (docs/relay.md, "Endpoints").
        case refused(httpCode: Int)

        public var isTerminal: Bool {
            switch self {
            case .closed, .refused: return true
            case .connecting, .open: return false
            }
        }
    }

    /// The Hub API base for a configured Hub. Settings hold the MQTT URL the Hub's provisioning
    /// bundle gives out (wss://mqtt-hub.meshsat.net/mqtt); the relay is on the API host. The
    /// hosted Hub names its broker mqtt-<api host>, so that prefix is dropped; a self-hosted Hub
    /// whose broker is elsewhere sets the Hub API URL explicitly (hub_relay_url), which wins
    /// whenever it is non-blank.
    public static func deriveHubApiBase(_ mqttUrl: String, explicitApiUrl: String = "") -> String {
        if !explicitApiUrl.trimmingCharacters(in: .whitespaces).isEmpty { return normalizeBase(explicitApiUrl) }
        guard let uri = URLComponents(string: mqttUrl.trimmingCharacters(in: .whitespaces)), let host = uri.host, !host.isEmpty else {
            return ""
        }
        let apiHost = host.hasPrefix("mqtt-") ? String(host.dropFirst(5)) : host
        let scheme: String
        switch uri.scheme?.lowercased() {
        case "ws", "tcp", "http": scheme = "http"
        default: scheme = "https"
        }
        return "\(scheme)://\(apiHost)"
    }

    /// https/http base with no trailing slash; ws(s) is accepted and mapped.
    public static func normalizeBase(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        let lower = u.lowercased()
        if lower.hasPrefix("wss://") { return "https://" + u.dropFirst(6) }
        if lower.hasPrefix("ws://") { return "http://" + u.dropFirst(5) }
        if u.contains("://") { return u }
        return "https://" + u
    }

    public static func connectUrl(_ hubBaseUrl: String, _ targetBridgeId: String) -> String {
        normalizeBase(hubBaseUrl) + "/api/relay/connect/" + formEncode(targetBridgeId)
    }

    /// java.net.URLEncoder: unreserved letters, digits and .-*_ stay, a space is +, the rest %XX.
    static func formEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    public static func basicAuth(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// Map a Hub close code to a reason (docs/relay.md, "Close codes").
    public static func reasonFor(_ code: Int) -> CloseReason {
        switch code {
        case 1000: return .normal
        case 1001: return .superseded
        case 1003: return .badFrame
        case 1008: return .budget
        default: return .error
        }
    }

    public let targetBridgeId: String
    public let connectUrl: String
    public let state = StateBroadcast<RelayState>(.connecting)
    private let ownBridgeId: String
    private let password: String
    private let dialer: any WebSocketDialer
    private let frameListener: @Sendable ([UInt8]) -> Void
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var opened = false
    private var terminal = false
    private var socket: (any WebSocketTransport)?
    private var reader: Task<Void, Never>?

    public init(
        hubBaseUrl: String, targetBridgeId: String, ownBridgeId: String, password: String, dialer: any WebSocketDialer,
        frameListener: @escaping @Sendable ([UInt8]) -> Void, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.targetBridgeId = targetBridgeId
        self.connectUrl = Self.connectUrl(hubBaseUrl, targetBridgeId)
        self.ownBridgeId = ownBridgeId
        self.password = password
        self.dialer = dialer
        self.frameListener = frameListener
        self.log = log
    }

    public var isOpen: Bool { state.value == .open }

    /// Open the WebSocket. Idempotent.
    public func open() {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        opened = true
        lock.unlock()
        log("relay: connecting to \(connectUrl) as \(ownBridgeId)")
        let task = Task { [self] in await connectAndRead() }
        lock.lock()
        reader = task
        lock.unlock()
    }

    /// Close from this end. Safe to call any number of times.
    public func close() {
        finish(.closed(reason: .local, detail: "closed by client"), wsCode: 1000, wsReason: "client closing")
    }

    /// Write `payload` into the tunnel, chunked at `chunk`. False when the tunnel is not open or
    /// the transport refused a frame (its socket is closing).
    public func sendFrame(_ payload: [UInt8]) async -> Bool {
        guard let socket = currentSocket(), isOpen else { return false }
        if payload.isEmpty { return true }
        var off = 0
        while off < payload.count {
            let n = min(Self.chunk, payload.count - off)
            do {
                try await socket.send(.binary(Array(payload[off..<off + n])))
            } catch {
                return false
            }
            off += n
        }
        return true
    }

    private func currentSocket() -> (any WebSocketTransport)? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }

    private func install(_ s: any WebSocketTransport) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if terminal { return false }
        socket = s
        return true
    }

    private func connectAndRead() async {
        let s: any WebSocketTransport
        do {
            s = try await dialer.dial(
                connectUrl, headers: ["Authorization": Self.basicAuth(ownBridgeId, password)], timeoutSeconds: Self.connectTimeoutSeconds)
        } catch WebSocketDialError.refused(let code) {
            log("relay: refused before upgrade with HTTP \(code)")
            finish(.refused(httpCode: code), wsCode: 1000, wsReason: nil)
            return
        } catch {
            log("relay: failed: \(error)")
            finish(.closed(reason: .error, detail: "\(error)"), wsCode: 1000, wsReason: nil)
            return
        }
        guard install(s) else {
            await s.close(code: 1000, reason: "client closing")
            return
        }
        log("relay: open to \(targetBridgeId)")
        state.send(.open)
        var sawClose = false
        for await frame in s.incoming {
            switch frame {
            case .binary(let bytes):
                frameListener(bytes)
            case .text(let text):
                // The Hub never sends text; a text frame is a protocol error on either side.
                log("relay: text frame from Hub ignored (\(text.count) chars)")
            case .close(let code, let reason):
                sawClose = true
                log("relay: Hub closing \(code) \(reason.isEmpty ? "(no reason)" : reason)")
                finish(.closed(reason: Self.reasonFor(Int(code)), detail: reason), wsCode: 1000, wsReason: nil)
            }
        }
        if !sawClose { finish(.closed(reason: .error, detail: "connection lost"), wsCode: 1000, wsReason: nil) }
    }

    /// Enter a terminal state exactly once, releasing the socket. Later calls (the transport's
    /// own close after ours) are ignored so the first reason is the one reported.
    private func finish(_ s: RelayState, wsCode: UInt16, wsReason: String?) {
        lock.lock()
        if terminal {
            lock.unlock()
            return
        }
        terminal = true
        let sock = socket
        socket = nil
        lock.unlock()
        state.send(s)
        if let sock {
            Task { await sock.close(code: wsCode, reason: wsReason ?? "") }
        }
    }
}
