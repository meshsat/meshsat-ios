// Mirrors GatewayService.passWindowsForNode (MESHSAT-1378): the pass windows the node gets over
// PASS, from the app's own predictions. Here rather than in the gateway so the Linux tests
// cover it; the predictions are handed in as (aos, los, peak elevation) so this module does not
// depend on MeshSatSatellite.

public enum PassWindowsForNode {
    /// One prediction as this needs it: acquisition and loss of signal in Unix seconds, peak
    /// elevation in degrees.
    public struct Pass: Sendable, Equatable {
        public let aosUnix: Int64
        public let losUnix: Int64
        public let peakElevDeg: Double
        public init(aosUnix: Int64, losUnix: Int64, peakElevDeg: Double) {
            self.aosUnix = aosUnix
            self.losUnix = losUnix
            self.peakElevDeg = peakElevDeg
        }
    }

    /// Passes not yet over at `nowSec`, soonest first, at most `passListMax`. The predictor's
    /// own elevation mask (5 degrees) already applies; the node needs no lower one.
    public static func windows(_ passes: [Pass], nowSec: Int64) -> [IridiumPipeContract.PassWindow] {
        passes
            .filter { $0.losUnix > nowSec && $0.losUnix > $0.aosUnix }
            .sorted { $0.aosUnix < $1.aosUnix }
            .prefix(IridiumPipeContract.passListMax)
            .map { p in
                let duration = min(p.losUnix - p.aosUnix, Int64(UInt16.max))
                let elevation = min(max(Int(p.peakElevDeg), 0), 90)
                return IridiumPipeContract.PassWindow(
                    startEpochS: UInt32(truncatingIfNeeded: p.aosUnix), durationS: UInt16(duration), maxElevationDeg: UInt8(elevation))
            }
    }
}
