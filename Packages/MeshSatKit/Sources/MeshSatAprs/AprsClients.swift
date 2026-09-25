// Mirrors aprs/KissClient.kt and aprs/AprsIsClient.kt: the KISS TCP client for a TNC such as
// Direwolf (AX.25 frames in KISS framing), and the APRS-IS client (TNC-2 text lines after a
// login). Both run on MeshSatNet's ByteStreamDialer, so the tests use a loopback. A drop
// silently ends the connection and reports the state; the InterfaceManager reconnects
// (MESHSAT-499: state, not error).
import Foundation
import MeshSatNet

public enum AprsClientState: Sendable, Equatable { case disconnected, connecting, connected, error }

public final class KissClient: @unchecked Sendable {
    public static let connectTimeoutSeconds: Double = 10
    public let state = StateBroadcast<AprsClientState>(.disconnected)
    private let dialer: any ByteStreamDialer
    private let log: @Sendable (String) -> Void
    private let link = ClientLink()
    private let lock = NSLock()
    private var onFrame: (@Sendable (Ax25Frame) -> Void)?

    public init(dialer: any ByteStreamDialer, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.dialer = dialer
        self.log = log
    }

    public func setFrameCallback(_ cb: (@Sendable (Ax25Frame) -> Void)?) {
        lock.lock()
        onFrame = cb
        lock.unlock()
    }

    private func frameCallback() -> (@Sendable (Ax25Frame) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return onFrame
    }

    public var isConnected: Bool { link.stream != nil && state.value == .connected }

    /// Connect to the KISS TCP server; returns once connected or failed.
    public func connect(host: String, port: Int) async {
        disconnect()
        let generation = link.begin()
        state.send(.connecting)
        do {
            let s = try await dialer.dial(host: host, port: port, tls: nil, timeoutSeconds: Self.connectTimeoutSeconds)
            guard link.adopt(s, generation: generation) else {
                await s.close()
                return
            }
            state.send(.connected)
            log("Connected to \(host):\(port)")
            link.reader = Task { [weak self] in
                guard let self else { return }
                await readLoop(s, generation: generation)
            }
        } catch {
            log("Connect failed: \(error)")
            state.send(.error)
        }
    }

    public func disconnect() {
        let (s, r) = link.end()
        r?.cancel()
        if let s { Task { await s.close() } }
        state.send(.disconnected)
    }

    /// Send an AX.25 frame in KISS framing. A silent drop when not connected.
    public func sendFrame(_ frame: [UInt8]) async {
        guard state.value == .connected, let s = link.stream else { return }
        try? await s.send(KissCodec.encode(frame))
    }

    private func readLoop(_ s: any ByteStream, generation: Int) async {
        var deframer = KissCodec.Deframer()
        for await bytes in s.incoming {
            for frame in deframer.feed(bytes) {
                guard let decoded = KissCodec.decode(frame), let ax25 = Ax25Codec.decode(decoded) else { continue }
                frameCallback()?(ax25)
            }
        }
        if link.dropped(generation: generation) {
            log("Connection closed")
            state.send(.disconnected)
        }
    }
}

/// The connection a client holds, behind a lock taken only in synchronous helpers (Swift 6
/// rejects NSLock inside an async function). A generation number tells a reader whose
/// connection ended, since `any ByteStream` cannot be compared by identity.
final class ClientLink: @unchecked Sendable {
    private let lock = NSLock()
    private var streamValue: (any ByteStream)?
    private var readerValue: Task<Void, Never>?
    private var generation = 0
    private var running = false

    var stream: (any ByteStream)? {
        lock.lock()
        defer { lock.unlock() }
        return streamValue
    }

    var reader: Task<Void, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return readerValue
        }
        set {
            lock.lock()
            readerValue = newValue
            lock.unlock()
        }
    }

    /// A new connection attempt: its generation.
    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        running = true
        generation += 1
        return generation
    }

    /// The dialled stream becomes the connection, unless a disconnect came meanwhile.
    func adopt(_ s: any ByteStream, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running, self.generation == generation else { return false }
        streamValue = s
        return true
    }

    /// Ends the connection: what to close and what to cancel.
    func end() -> ((any ByteStream)?, Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        running = false
        let s = streamValue
        streamValue = nil
        let r = readerValue
        readerValue = nil
        return (s, r)
    }

    /// The reader of `generation` saw its stream end: true when that was the live connection.
    func dropped(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running, self.generation == generation, streamValue != nil else { return false }
        streamValue = nil
        return true
    }
}

/// Direct TCP to the APRS Internet Service: login, then TNC-2 lines both ways.
public final class AprsIsClient: @unchecked Sendable {
    public static let connectTimeoutSeconds: Double = 15
    public static let version = "MeshSat 1.0"
    public let state = StateBroadcast<AprsClientState>(.disconnected)
    private let dialer: any ByteStreamDialer
    private let log: @Sendable (String) -> Void
    private let link = ClientLink()
    private let lock = NSLock()
    private var onPacket: (@Sendable (AprsPacket) -> Void)?
    private var bannerValue = ""
    private var verifiedValue = false

    public init(dialer: any ByteStreamDialer, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.dialer = dialer
        self.log = log
    }

    /// A TNC-2 line as the server sends it (AprsCodec.parseTnc2Line, kept here as Android has it).
    public static func parseTnc2Line(_ line: String) -> AprsPacket? { AprsCodec.parseTnc2Line(line) }

    public func setPacketCallback(_ cb: (@Sendable (AprsPacket) -> Void)?) {
        lock.lock()
        onPacket = cb
        lock.unlock()
    }

    private func packetCallback() -> (@Sendable (AprsPacket) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return onPacket
    }

    /// The server's greeting, once logged in.
    public var serverBanner: String {
        lock.lock()
        defer { lock.unlock() }
        return bannerValue
    }

    /// Whether the server accepted the passcode.
    public var verified: Bool {
        lock.lock()
        defer { lock.unlock() }
        return verifiedValue
    }

    private func setLogin(banner: String, verified: Bool) {
        lock.lock()
        bannerValue = banner
        verifiedValue = verified
        lock.unlock()
    }

    public var isConnected: Bool { link.stream != nil && state.value == .connected }

    /// The login line: `user CALL-SSID pass PASSCODE vers MeshSat 1.0 filter r/LAT/LON/RANGE`.
    public static func loginLine(callsign: String, passcode: String, filterLat: Double, filterLon: Double, filterRange: Int) -> String {
        let filter =
            filterLat != 0 || filterLon != 0
            ? String(format: " filter r/%.1f/%.1f/%d", locale: Locale(identifier: "en_US_POSIX"), filterLat, filterLon, filterRange) : ""
        return "user \(callsign) pass \(passcode) vers \(version)\(filter)"
    }

    /// Connect and log in; returns once the login was answered or the connection failed.
    public func connect(
        server: String, port: Int = 14580, callsign: String, passcode: String = "-1", filterLat: Double = 0, filterLon: Double = 0,
        filterRange: Int = 100
    ) async {
        disconnect()
        let generation = link.begin()
        state.send(.connecting)
        do {
            let s = try await dialer.dial(host: server, port: port, tls: nil, timeoutSeconds: Self.connectTimeoutSeconds)
            var lines = LineReader()
            let banner = try await lines.readLine(from: s)
            log("Server: \(banner)")
            let login = Self.loginLine(
                callsign: callsign, passcode: passcode, filterLat: filterLat, filterLon: filterLon, filterRange: filterRange)
            try await s.send(Array((login + "\r\n").utf8))
            log("Login sent: user \(callsign) pass *** vers \(Self.version)")
            let response = try await lines.readLine(from: s)
            let verified = response.lowercased().contains("verified") && !response.lowercased().contains("unverified")
            setLogin(banner: banner, verified: verified)
            log("Login response: \(response) (verified=\(verified))")
            guard link.adopt(s, generation: generation) else {
                await s.close()
                return
            }
            state.send(.connected)
            let reader = lines
            link.reader = Task { [weak self] in
                guard let self else { return }
                await readLoop(s, reader, generation: generation)
            }
        } catch {
            log("Connect failed: \(error)")
            state.send(.error)
        }
    }

    public func disconnect() {
        let (s, r) = link.end()
        r?.cancel()
        if let s { Task { await s.close() } }
        state.send(.disconnected)
    }

    /// A raw TNC-2 line: SOURCE>DEST,PATH:payload. A silent drop when not connected.
    public func sendRaw(_ line: String) async {
        guard state.value == .connected, let s = link.stream else { return }
        try? await s.send(Array((line + "\r\n").utf8))
        log("TX: \(line)")
    }

    public func sendPosition(
        callsign: String, lat: Double, lon: Double, symbolTable: Character = "/", symbolCode: Character = "-", comment: String = ""
    ) async {
        let pos = String(
            decoding: AprsCodec.encodePosition(lat: lat, lon: lon, symbolTable: symbolTable, symbolCode: symbolCode, comment: comment),
            as: UTF8.self)
        await sendRaw("\(callsign)>APMSHT,TCPIP*:\(pos)")
    }

    public func sendMessage(callsign: String, to: String, text: String, msgId: String = "") async {
        let msg = String(decoding: AprsCodec.encodeMessage(to: to, text: text, msgId: msgId), as: UTF8.self)
        await sendRaw("\(callsign)>APMSHT,TCPIP*:\(msg)")
    }

    public func sendAck(callsign: String, to: String, msgId: String) async {
        let padded = to.padding(toLength: max(9, to.count), withPad: " ", startingAt: 0)
        await sendRaw("\(callsign)>APMSHT,TCPIP*::\(padded):ack\(msgId)")
    }

    private func readLoop(_ s: any ByteStream, _ reader: LineReader, generation: Int) async {
        var lines = reader
        for await bytes in s.incoming {
            for line in lines.feed(bytes) {
                if line.hasPrefix("#") { continue }  // server comments
                guard let pkt = AprsCodec.parseTnc2Line(line) else { continue }
                packetCallback()?(pkt)
            }
        }
        if link.dropped(generation: generation) {
            log("Connection closed by server")
            state.send(.disconnected)
        }
    }
}

/// Lines out of a byte stream, CR/LF stripped; keeps what has not ended in a line yet.
struct LineReader: Sendable {
    private var buffer: [UInt8] = []
    private var pending: [String] = []

    mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer += bytes
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = Array(buffer[..<nl])
            if line.last == 0x0D { line.removeLast() }
            out.append(String(decoding: line, as: UTF8.self))
            buffer.removeFirst(nl + 1)
        }
        return out
    }

    /// The next line, reading the stream as needed.
    mutating func readLine(from s: any ByteStream) async throws -> String {
        if !pending.isEmpty { return pending.removeFirst() }
        for await bytes in s.incoming {
            let lines = feed(bytes)
            if let first = lines.first {
                pending += lines.dropFirst()
                return first
            }
        }
        throw ByteStreamError.closed
    }
}
