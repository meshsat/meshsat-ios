// Mirrors satellite/PassPredictor.kt: a 60 s scan of the elevation above the observer with a
// 5 s bisection at each horizon crossing, WGS-84 observer position in TEME, IAU 1982 GMST.
// Times are UnixSeconds (MESHSAT-498: milliseconds once ran the propagator 1000x too far).
// `now` is a parameter so tests are deterministic; the app passes the clock.
import Foundation

public struct PassPrediction: Sendable, Equatable, Hashable {
    public let satellite: String
    public let aos: UnixSeconds
    public let los: UnixSeconds
    public let durationMin: Double
    public let peakElevDeg: Double
    public let peakAzimuthDeg: Double
    public let isActive: Bool

    public init(
        satellite: String, aos: UnixSeconds, los: UnixSeconds, durationMin: Double,
        peakElevDeg: Double, peakAzimuthDeg: Double, isActive: Bool
    ) {
        self.satellite = satellite
        self.aos = aos
        self.los = los
        self.durationMin = durationMin
        self.peakElevDeg = peakElevDeg
        self.peakAzimuthDeg = peakAzimuthDeg
        self.isActive = isActive
    }
}

public struct Observer: Sendable, Equatable {
    public let latDeg: Double
    public let lonDeg: Double
    public let altKm: Double
    public init(latDeg: Double, lonDeg: Double, altKm: Double = 0) {
        self.latDeg = latDeg
        self.lonDeg = lonDeg
        self.altKm = altKm
    }
}

public enum PassPredictor {
    static let deg2rad = Double.pi / 180.0
    static let rad2deg = 180.0 / Double.pi
    static let earthRadiusKm = 6378.137
    static let earthFlattening = 1.0 / 298.257223563
    static let stepSec = 60.0
    static let refineSec = 5.0

    /// All passes of one satellite in a window. Elevation is scanned every 60 s, and only passes
    /// whose peak reaches `minElevDeg` are kept.
    public static func predictPasses(
        _ tle: TleElements, observer: Observer, start: UnixSeconds, end: UnixSeconds,
        minElevDeg: Double = 5.0, now: UnixSeconds = UnixSeconds(Date())
    ) -> [PassPrediction] {
        guard let rec = Sgp4.SatRec(tle) else { return [] }
        let epoch = tle.epoch.value
        var passes = [PassPrediction]()
        var t = floor(start.value)
        var inPass = false
        var passStart = 0.0
        var peakElev = -90.0
        var peakAz = 0.0

        func elevation(at time: Double) -> (Double, Sgp4.EciPosition?) {
            let pos = rec.propagate(tsince: (time - epoch) / 60.0)
            guard let pos else { return (-90.0, nil) }
            return (elevationDeg(pos, observer: observer, unix: time), pos)
        }

        while t <= end.value {
            let (elev, pos) = elevation(at: t)
            if elev > 0.0, let pos {
                if !inPass {
                    passStart = refineAos(rec, epoch: epoch, observer: observer, before: t - stepSec, after: t)
                    inPass = true
                    peakElev = elev
                    peakAz = azimuthDeg(pos, observer: observer, unix: t)
                }
                if elev > peakElev {
                    peakElev = elev
                    peakAz = azimuthDeg(pos, observer: observer, unix: t)
                }
            } else if inPass {
                let passEnd = refineLos(rec, epoch: epoch, observer: observer, before: t - stepSec, after: t)
                if peakElev >= minElevDeg {
                    passes.append(
                        PassPrediction(
                            satellite: tle.name, aos: UnixSeconds(passStart), los: UnixSeconds(passEnd),
                            durationMin: (passEnd - passStart) / 60.0, peakElevDeg: peakElev, peakAzimuthDeg: peakAz,
                            isActive: passStart <= now.value && now.value <= passEnd
                        ))
                }
                inPass = false
                peakElev = -90.0
            }
            t += stepSec
        }

        if inPass, peakElev >= minElevDeg {
            passes.append(
                PassPrediction(
                    satellite: tle.name, aos: UnixSeconds(passStart), los: end,
                    durationMin: (end.value - passStart) / 60.0, peakElevDeg: peakElev, peakAzimuthDeg: peakAz,
                    isActive: passStart <= now.value && now.value <= end.value
                ))
        }
        return passes
    }

    /// Passes for a whole element set, sorted by AOS.
    public static func predictAllPasses(
        _ tles: [TleElements], observer: Observer, start: UnixSeconds, end: UnixSeconds,
        minElevDeg: Double = 5.0, now: UnixSeconds = UnixSeconds(Date())
    ) -> [PassPrediction] {
        tles.flatMap { predictPasses($0, observer: observer, start: start, end: end, minElevDeg: minElevDeg, now: now) }
            .sorted { $0.aos < $1.aos }
    }

    private static func refineAos(_ rec: Sgp4.SatRec, epoch: Double, observer: Observer, before: Double, after: Double) -> Double {
        var lo = before
        var hi = after
        while hi - lo > refineSec {
            let mid = floor((lo + hi) / 2)
            let elev = rec.propagate(tsince: (mid - epoch) / 60.0).map { elevationDeg($0, observer: observer, unix: mid) } ?? -90.0
            if elev > 0.0 { hi = mid } else { lo = mid }
        }
        return hi
    }

    private static func refineLos(_ rec: Sgp4.SatRec, epoch: Double, observer: Observer, before: Double, after: Double) -> Double {
        var lo = before
        var hi = after
        while hi - lo > refineSec {
            let mid = floor((lo + hi) / 2)
            let elev = rec.propagate(tsince: (mid - epoch) / 60.0).map { elevationDeg($0, observer: observer, unix: mid) } ?? -90.0
            if elev > 0.0 { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Elevation of the satellite above the observer's horizon, in degrees.
    public static func elevationDeg(_ sat: Sgp4.EciPosition, observer: Observer, unix: Double) -> Double {
        let obs = observerEci(observer, unix: unix)
        let rx = sat.x - obs.x, ry = sat.y - obs.y, rz = sat.z - obs.z
        let range = sqrt(rx * rx + ry * ry + rz * rz)
        if range < 1.0 { return -90.0 }
        let obsDist = sqrt(obs.x * obs.x + obs.y * obs.y + obs.z * obs.z)
        let cosZenith = (rx * obs.x / obsDist + ry * obs.y / obsDist + rz * obs.z / obsDist) / range
        return asin(cosZenith) * rad2deg
    }

    /// Azimuth of the satellite from the observer, degrees clockwise from north.
    public static func azimuthDeg(_ sat: Sgp4.EciPosition, observer: Observer, unix: Double) -> Double {
        let lat = observer.latDeg * deg2rad
        let lst = greenwichMeanSiderealTime(unix: unix) + observer.lonDeg * deg2rad
        let obs = observerEci(Observer(latDeg: observer.latDeg, lonDeg: observer.lonDeg, altKm: 0), unix: unix)
        let rx = sat.x - obs.x, ry = sat.y - obs.y, rz = sat.z - obs.z
        let sinLat = sin(lat), cosLat = cos(lat), sinLst = sin(lst), cosLst = cos(lst)
        let south = sinLat * cosLst * rx + sinLat * sinLst * ry - cosLat * rz
        let east = -sinLst * rx + cosLst * ry
        let az = atan2(east, -south) * rad2deg
        return az < 0 ? az + 360.0 : az
    }

    static func observerEci(_ observer: Observer, unix: Double) -> Sgp4.EciPosition {
        let lat = observer.latDeg * deg2rad
        let lst = greenwichMeanSiderealTime(unix: unix) + observer.lonDeg * deg2rad
        let sinLat = sin(lat), cosLat = cos(lat)
        let e2 = earthFlattening * (2.0 - earthFlattening)
        let n = earthRadiusKm / sqrt(1.0 - e2 * sinLat * sinLat)
        let r = (n + observer.altKm) * cosLat
        let z = (n * (1.0 - e2) + observer.altKm) * sinLat
        return Sgp4.EciPosition(x: r * cos(lst), y: r * sin(lst), z: z)
    }

    /// Greenwich Mean Sidereal Time in radians (IAU 1982).
    static func greenwichMeanSiderealTime(unix: Double) -> Double {
        let jd = TleParser.unixToJd(UnixSeconds(unix))
        let t = (jd - 2_451_545.0) / 36525.0
        var gmst = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        gmst = gmst.truncatingRemainder(dividingBy: 86400.0) / 86400.0 * 2.0 * Double.pi
        if gmst < 0 { gmst += 2.0 * Double.pi }
        return gmst
    }
}
