// Mirrors hub/relay/RelayBridgeTransport.kt: a Reticulum interface over a Hub relay tunnel to
// one bridge (MESHSAT-1157). The fallback below LAN and RNS TCP: when the kit cannot be reached
// directly, the phone opens a relay tunnel to it through the Hub and carries Reticulum packets
// as bare frames, one packet per frame, so nothing is re-framed on the far side.
//
// Reconnects by itself. The Hub's budget is 100 frames per calendar minute per client id,
// counting connect attempts, so a 1008 (budget) or an HTTP 429 waits out the minute; a 401/403
// is a configuration problem and is retried slowly.
import Foundation
import MeshSatNet
import MeshSatReticulum

public final class RelayBridgeTransport: RnsInterface, @unchecked Sendable {
    public static let interfaceId = "hub_relay"
    public static let retryMinMs: Int64 = 5_000
    public static let retryMaxMs: Int64 = 60_000
    /// A spent budget resets on the calendar minute; wait a whole one plus slack.
    public static let retryBudgetMs: Int64 = 65_000
    /// Bad credentials or a bridge that is not ours: someone has to fix settings.
    public static let retryRefusedMs: Int64 = 300_000

    public struct Config: Sendable, Equatable {
        public var hubApiBase: String
        public var targetBridgeId: String
        public var ownBridgeId: String
        public var password: String
        public init(hubApiBase: String, targetBridgeId: String, ownBridgeId: String, password: String) {
            self.hubApiBase = hubApiBase
            self.targetBridgeId = targetBridgeId
            self.ownBridgeId = ownBridgeId
            self.password = password
        }
    }

    public let interfaceId: String
    public let name = "Hub relay"
    public let mtu = RnsConstants.mtu
    public let costCents = 0
    public let latencyMs = 300
    public let isBidirectional = true
    /// The current tunnel's state; drives the InterfaceManager entry for `interfaceId`.
    public let state = StateBroadcast<RelayTunnel.RelayState>(.closed(reason: .local, detail: "not started"))
    public var isOnline: Bool { state.value == .open }

    /// How long to wait after a tunnel ended, from the way it ended (pure, tested).
    public static func retryDelayMs(after end: RelayTunnel.RelayState, backoff: Int64) -> Int64 {
        switch end {
        case .refused(let code):
            switch code {
            case 429: return retryBudgetMs
            case 400, 401, 403: return retryRefusedMs
            default: return backoff
            }
        case .closed(let reason, _):
            switch reason {
            case .budget: return retryBudgetMs
            case .superseded: return retryMaxMs
            default: return backoff
            }
        case .connecting, .open:
            return backoff
        }
    }

    private let config: Config
    private let dialer: any WebSocketDialer
    private let sleep: @Sendable (Int64) async throws -> Void
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var receiveCallback: RnsReceiveCallback?
    private var tunnel: RelayTunnel?
    private var running = false
    private var loop: Task<Void, Never>?

    public init(
        config: Config, dialer: any WebSocketDialer, interfaceId: String = RelayBridgeTransport.interfaceId,
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.dialer = dialer
        self.interfaceId = interfaceId
        self.sleep = sleep
        self.log = log
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    public func start() async { startNow() }

    /// The synchronous start: the lock cannot be taken inside an async function.
    public func startNow() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        // Connecting before the loop is scheduled, so nobody reads the pre-start Closed.
        state.send(.connecting)
        let task = Task { [self] in await connectionLoop() }
        lock.lock()
        loop = task
        lock.unlock()
    }

    public func stop() async { shutdown() }

    /// Non-suspending stop for the gateway's teardown.
    public func shutdown() {
        lock.lock()
        running = false
        let l = loop
        loop = nil
        let t = tunnel
        tunnel = nil
        lock.unlock()
        l?.cancel()
        t?.close()
        state.send(.closed(reason: .local, detail: "stopped"))
    }

    public func send(_ packet: [UInt8]) async -> String? {
        if packet.count > RelayTunnel.maxFrame { return "hub relay: packet larger than a frame" }
        guard let t = currentTunnel(), t.isOpen else { return "hub relay offline" }
        return await t.sendFrame(packet) ? nil : "hub relay send failed"
    }

    private func currentTunnel() -> RelayTunnel? {
        lock.lock()
        defer { lock.unlock() }
        return tunnel
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func setTunnel(_ t: RelayTunnel?) {
        lock.lock()
        tunnel = t
        lock.unlock()
    }

    private func deliver(_ frame: [UInt8]) {
        lock.lock()
        let cb = receiveCallback
        lock.unlock()
        cb?(interfaceId, frame)
    }

    private func connectionLoop() async {
        var backoff = Self.retryMinMs
        while isRunning(), !Task.isCancelled {
            let t = RelayTunnel(
                hubBaseUrl: config.hubApiBase, targetBridgeId: config.targetBridgeId, ownBridgeId: config.ownBridgeId,
                password: config.password, dialer: dialer, frameListener: { [weak self] frame in self?.deliver(frame) }, log: log)
            setTunnel(t)
            state.send(.connecting)
            // The tunnel's states become ours while we run; after shutdown() the "stopped" it
            // set must not be overwritten by the tunnel's own close (seen under parallel tests).
            let mirror = Task { [weak self] in
                for await s in t.state.subscribe() {
                    guard let self, self.isRunning() else { return }
                    self.state.send(s)
                    if s.isTerminal { return }
                }
            }
            t.open()
            // Wait for the tunnel to end, whichever way.
            var end: RelayTunnel.RelayState = .closed(reason: .error, detail: "no state")
            for await s in t.state.subscribe() where s.isTerminal {
                end = s
                break
            }
            await mirror.value
            if !isRunning() { break }
            state.send(end)
            setTunnel(nil)
            let wait = Self.retryDelayMs(after: end, backoff: backoff)
            if case .closed(.normal, _) = end { backoff = Self.retryMinMs } else { backoff = min(backoff * 2, Self.retryMaxMs) }
            log("relay to \(config.targetBridgeId) ended (\(end)); retry in \(wait / 1000)s")
            do { try await sleep(wait) } catch { break }
        }
    }
}
