// Time as the drivers and the engine see it, so tests run their timeouts and polls on a
// virtual clock. Milliseconds since the epoch, as Android's System.currentTimeMillis().
import Foundation

public protocol DriverClock: Sendable {
    func nowMs() -> Int64
    func sleep(ms: Int64) async
}

public struct SystemDriverClock: DriverClock {
    public init() {}
    public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public func sleep(ms: Int64) async {
        try? await Task.sleep(for: .milliseconds(max(0, ms)))
    }
}
