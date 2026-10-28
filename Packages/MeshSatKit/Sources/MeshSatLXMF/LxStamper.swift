// Mirrors lxmf/LxStamper.kt (the Bridge's internal/lxmf/stamper.go): LXMF stamps
// (LXMF/LXStamper.py), proof of work a receiver can demand. The workblock is 3000 HKDF
// expansions of the message id, each salted with SHA-256(id || msgpack(n)); a stamp is 32
// random bytes such that SHA-256(workblock || stamp) has at least `cost` leading zero bits.
import Crypto
import Foundation
import MeshSatReticulum
import MeshSatRns

public enum LxStamper {
    public static let workblockExpandRounds = 3000
    /// A propagation stamp (over the transient id, for a propagation node) expands 1000 rounds.
    public static let workblockExpandRoundsPN = 1000
    public static let stampSize = 32

    public static func workblock(_ messageId: [UInt8], expandRounds: Int = workblockExpandRounds) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expandRounds * 256)
        for n in 0..<expandRounds {
            let salt = Rns.sha256(messageId, Msgpack.pack(.int(Int64(n))))
            out += RnsHkdf.derive(length: 256, from: messageId, salt: salt)
        }
        return out
    }

    /// The number of leading zero bits of SHA-256(workblock || stamp).
    public static func stampValue(workblock: [UInt8], stamp: [UInt8]) -> Int {
        var h = SHA256()
        h.update(data: workblock)
        h.update(data: stamp)
        return leadingZeroBits(Array(h.finalize()))
    }

    private static func leadingZeroBits(_ h: [UInt8]) -> Int {
        var value = 0
        for b in h {
            if b == 0 {
                value += 8
                continue
            }
            value += b.leadingZeroBitCount
            break
        }
        return value
    }

    public static func stampValid(workblock: [UInt8], stamp: [UInt8], cost: Int) -> Bool {
        guard cost > 0, cost < 256, !stamp.isEmpty else { return false }
        return stampValue(workblock: workblock, stamp: stamp) >= cost
    }

    /// Searches random stamps until one meets `cost`, on every core, or returns nil when
    /// `cancelled` says so first. Returns the stamp and its value. Synchronous: call it off the
    /// main actor.
    public static func generateStamp(
        messageId: [UInt8], cost: Int, cancelled: @Sendable () -> Bool = { false }, expandRounds: Int = workblockExpandRounds
    ) -> (stamp: [UInt8], value: Int)? {
        guard cost > 0 else { return nil }
        let wb = workblock(messageId, expandRounds: expandRounds)
        let found = Found()
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var stamp = [UInt8](repeating: 0, count: stampSize)
            var i = 0
            while !found.isSet {
                if i % 64 == 0, cancelled() { return }
                i += 1
                for j in stamp.indices { stamp[j] = UInt8.random(in: 0...255) }
                var h = SHA256()
                h.update(data: wb)
                h.update(data: stamp)
                if leadingZeroBits(Array(h.finalize())) >= cost {
                    found.set(stamp)
                    return
                }
            }
        }
        guard let s = found.stamp else { return nil }
        return (s, stampValue(workblock: wb, stamp: s))
    }

    /// The first stamp found, shared by the workers of one search.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [UInt8]?

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value != nil
        }

        var stamp: [UInt8]? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ stamp: [UInt8]) {
            lock.lock()
            if value == nil { value = stamp }
            lock.unlock()
        }
    }
}
