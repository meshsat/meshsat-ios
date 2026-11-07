// Mirrors the Transmitter object inside rns/RnsStack.kt: the node's Transmitter over the app's
// RnsInterfaces. One ordered send queue per interface keeps the order the node handed packets
// over in (Kotlin's Channel(256) with one coroutine draining it); floodable interfaces are the
// online, bidirectional, unpaid ones; the LoRa mesh gets the announce cap's bit rate; a paid
// bearer (Iridium, SMS, cellular) never floods and is opened by a PaidPolicy instead.
import Foundation
import MeshSatReticulum

public final class InterfaceTransmitter: Transmitter, @unchecked Sendable {
    /// LongFast is about a kilobit a second; the 2 % announce cap works from this.
    public static let loraBitrate = 1000
    private static let paidPrefixes = ["iridium", "sms", "cellular"]

    /// Paid bearers never carry broadcast traffic: a policy opens them to named destinations.
    public static func isPaidInterface(_ id: String) -> Bool { paidPrefixes.contains { id.hasPrefix($0) } }

    private let interfaces: @Sendable () -> [String: any RnsInterface]
    private let hwMtuOverride: (@Sendable (String) -> Int?)?
    private let log: @Sendable (String) -> Void
    private let lock = NSRecursiveLock()
    private var queues: [String: AsyncStream<[UInt8]>.Continuation] = [:]
    private var drains: [String: Task<Void, Never>] = [:]
    private var stopped = false

    /// `hwMtu` overrides the interface's `mtu` for the link MTU signalling (the interop tests give TCP
    /// Python's 262144); nil falls back to `mtu`.
    public init(
        interfaces: @escaping @Sendable () -> [String: any RnsInterface], hwMtu: (@Sendable (String) -> Int?)? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.interfaces = interfaces
        hwMtuOverride = hwMtu
        self.log = log
    }

    public func transmit(ifaceId: String, raw: [UInt8]) -> Bool {
        guard let iface = interfaces()[ifaceId] else { return false }
        let q: AsyncStream<[UInt8]>.Continuation? = lock.sync {
            if stopped { return nil }
            if let q = queues[ifaceId] { return q }
            var continuation: AsyncStream<[UInt8]>.Continuation!
            let stream = AsyncStream<[UInt8]>(bufferingPolicy: .bufferingOldest(256)) { continuation = $0 }
            let q = continuation!
            queues[ifaceId] = q
            let log = self.log
            drains[ifaceId] = Task {
                for await packet in stream {
                    if let err = await iface.send(packet) { log("rns: send on \(ifaceId) failed: \(err)") }
                }
            }
            return q
        }
        guard let q else { return false }
        if case .enqueued = q.yield(raw) { return true }
        return false
    }

    public func floodable() -> [String] {
        interfaces().filter { $0.value.isOnline && $0.value.isBidirectional && !Self.isPaidInterface($0.key) }.map(\.key).sorted()
    }

    public func hwMtu(ifaceId: String) -> Int {
        if let o = hwMtuOverride?(ifaceId) { return o }
        return interfaces()[ifaceId]?.mtu ?? 0
    }

    public func bitrate(ifaceId: String) -> Int { ifaceId.hasPrefix("mesh") ? Self.loraBitrate : 0 }

    public func online(ifaceId: String) -> Bool { interfaces()[ifaceId]?.isOnline == true }

    /// Ends every queue; packets handed over afterwards are refused.
    public func stop() {
        let (qs, ds): ([AsyncStream<[UInt8]>.Continuation], [Task<Void, Never>]) = lock.sync {
            stopped = true
            let q = Array(queues.values)
            let d = Array(drains.values)
            queues = [:]
            drains = [:]
            return (q, d)
        }
        for q in qs { q.finish() }
        for d in ds { d.cancel() }
    }
}
