// MeshSatMeshtastic: the platform-free half of MeshSat Android's ble/ and bt/ packages.
// ble/MeshtasticProtocol + MeshtasticProtoAdapter, ble/NodeProfile, ble/NodeBattery,
// ble/GattOpQueue, ble/IridiumPipeStreams and bt/IridiumSpp (the 9603 AT driver, here
// IridiumATDriver over a ModemLink) are ported into this module. CoreBluetooth itself is in
// Packages/MeshSatApple (MeshSatBLE).
import Foundation

public enum MeshSatMeshtastic {
    public static let module = "MeshSatMeshtastic"
}

/// Time as the drivers see it, so tests run their timeouts on a virtual clock.
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
