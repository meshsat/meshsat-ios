// Mirrors the phone-location part of service/GatewayService.kt (startLocationUpdates, the
// LocationListener) and location/LocationFixes.kt: one CLLocationManager asking for a fix every
// 60 s or 50 m, the freshest fix kept, a coarse fix never replacing a recent accurate one. The
// gateway stores each fix under node id 0 "Phone" and the pass predictor observes from it.
import CoreLocation
import Foundation
import Logging
import MeshSatNet

/// A fix as the engine sees it (no CoreLocation type crosses the module line).
public struct PhoneFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Metres above the ellipsoid as CoreLocation reports it.
    public let altitude: Double
    public let horizontalAccuracyM: Double
    public let speedMps: Double
    public let courseDeg: Double
    public let timeMs: Int64

    public init(
        latitude: Double, longitude: Double, altitude: Double, horizontalAccuracyM: Double, speedMps: Double, courseDeg: Double,
        timeMs: Int64
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracyM = horizontalAccuracyM
        self.speedMps = speedMps
        self.courseDeg = courseDeg
        self.timeMs = timeMs
    }

    /// LocationFixes.isBetter: a fix replaces the current one unless it is much coarser and the
    /// current one is recent (a cell fix must not replace a GPS fix from a minute ago).
    public static func isBetter(_ candidate: PhoneFix, than current: PhoneFix?) -> Bool {
        guard let current else { return true }
        let recent = candidate.timeMs - current.timeMs < 2 * 60_000
        let muchCoarser = candidate.horizontalAccuracyM > current.horizontalAccuracyM * 3 && candidate.horizontalAccuracyM > 100
        return !(recent && muchCoarser)
    }
}

public final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private static let log = Logger(label: "Location")
    public static let distanceFilterM: CLLocationDistance = 50

    public let phoneLocation = StateBroadcast<PhoneFix?>(nil)
    public let authorized = StateBroadcast<Bool>(false)
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var started = false
    private var askedAlways = false
    /// Whether the significant-change service is on (the app is in the background with Always).
    private var significantOn = false
    /// iOS 17's CLBackgroundActivitySession while the gateway keeps running in the background (MESHSAT-1506);
    /// it keeps the process alive for its location work. AnyObject so the type stays out of older SDK paths.
    private var backgroundSession: AnyObject?

    override public init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = Self.distanceFilterM
        manager.pausesLocationUpdatesAutomatically = false
        // In the background a fix comes from the significant-change service, which wakes the app on
        // its own, and from the moments iOS runs the app for Bluetooth events from the node; with
        // "Keep the gateway running in the background" on and Always granted, standard updates go
        // on behind iOS's blue indicator and keep the gateway alive (MESHSAT-1506, the location
        // background mode is back since 0.5.0; App Review 2.5.4 sees it used for the gateway's
        // position reports, zones and SOS, the person's own choice).
    }

    /// Whether `start()` may put iOS's location question up by itself. The gateway turns it off
    /// while the welcome page still has to explain the permission (MESHSAT-1834); the welcome's
    /// Continue then calls `requestAuthorization()`.
    public var askOnStart = true

    /// iOS has not asked for location yet.
    public var isUndetermined: Bool { manager.authorizationStatus == .notDetermined }

    /// The "while using" question, from the welcome page or the first use.
    public func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    /// Ask for permission on first use and start updates; a no-op while not authorized (the
    /// delegate starts them once the person allows it).
    public func start() {
        lock.lock()
        started = true
        lock.unlock()
        switch manager.authorizationStatus {
        case .notDetermined:
            if askOnStart { manager.requestWhenInUseAuthorization() }
        case .authorizedAlways, .authorizedWhenInUse:
            beginUpdates()
        default:
            Self.log.info("Location not authorized; no phone fix")
        }
    }

    public func stop() {
        lock.lock()
        started = false
        lock.unlock()
        manager.stopUpdatingLocation()
    }

    private func beginUpdates() {
        authorized.send(true)
        if let last = manager.location { accept(last) }
        manager.startUpdatingLocation()
    }

    private func accept(_ location: CLLocation) {
        let fix = PhoneFix(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, altitude: location.altitude,
            horizontalAccuracyM: location.horizontalAccuracy, speedMps: max(0, location.speed), courseDeg: max(0, location.course),
            timeMs: Int64(location.timestamp.timeIntervalSince1970 * 1000))
        guard PhoneFix.isBetter(fix, than: phoneLocation.value) else { return }
        phoneLocation.send(fix)
    }

    // MARK: CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.lock()
        let wanted = started
        lock.unlock()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if wanted { beginUpdates() }
            // Once "while using" is granted, ask for "always": the gateway reports positions,
            // watches zones and the check-in timer from the background (Android asks the same).
            #if os(iOS)
            if manager.authorizationStatus == .authorizedWhenInUse, !askedAlwaysOnce() { manager.requestAlwaysAuthorization() }
            #endif
        default:
            authorized.send(false)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations where l.horizontalAccuracy >= 0 { accept(l) }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.log.warning("Location error: \(error.localizedDescription)")
    }

    private func askedAlwaysOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = askedAlways
        askedAlways = true
        return was
    }

    /// Whether location is allowed Always, which the gateway needs to keep running in the background.
    public var isAlways: Bool { manager.authorizationStatus == .authorizedAlways }

    /// The keep-running switch went on (Android asks for background location at the same moment): iOS shows
    /// its "Change to Always Allow" question once per install; after that only iOS Settings can change it.
    public func requestAlways() {
        #if os(iOS)
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        lock.lock()
        askedAlways = true
        lock.unlock()
        manager.requestAlwaysAuthorization()
        #endif
    }

    /// Whether the build declares the location background mode; without it continuous background
    /// updates are a fatal error, so the switch is hidden and nothing asks for them.
    public static var backgroundModeDeclared: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }

    /// The app went to the background: with Always granted, the significant-change service
    /// delivers a fix on a cell change or about 500 m of movement and wakes the app for it; the
    /// Hub report, the zones and an SOS use that fix. Standard updates stop with the app.
    public func beginBackgroundActivity(keepAlive: Bool = false) {
        guard manager.authorizationStatus == .authorizedAlways else { return }
        #if os(iOS)
        if keepAlive, Self.backgroundModeDeclared {
            // Continuous updates behind the blue indicator: the app keeps running (MESHSAT-1506).
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            lock.lock()
            if backgroundSession == nil, #available(iOS 17.0, *) { backgroundSession = CLBackgroundActivitySession() }
            lock.unlock()
            Self.log.info("Continuous location on: the gateway keeps running in the background")
        }
        #endif
        lock.lock()
        let start = !significantOn
        significantOn = true
        lock.unlock()
        if start {
            manager.startMonitoringSignificantLocationChanges()
            Self.log.info("Significant-change location on for the background")
        }
    }

    public func endBackgroundActivity() {
        #if os(iOS)
        if manager.allowsBackgroundLocationUpdates { manager.allowsBackgroundLocationUpdates = false }
        lock.lock()
        let session = backgroundSession
        backgroundSession = nil
        lock.unlock()
        if #available(iOS 17.0, *), let s = session as? CLBackgroundActivitySession {
            s.invalidate()
            Self.log.info("Background activity session ended")
        }
        #endif
        lock.lock()
        let stop = significantOn
        significantOn = false
        lock.unlock()
        if stop {
            manager.stopMonitoringSignificantLocationChanges()
            Self.log.info("Significant-change location off; standard updates in the foreground")
        }
    }
}
