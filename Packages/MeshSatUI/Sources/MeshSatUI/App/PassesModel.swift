// Mirrors the state of ui/screens/PassPredictorScreen.kt: the window and the elevation floor,
// the predicted passes from the phone's own TLE cache, the past half of the window's signal
// readings and satellite sessions, the countdown to the next pass, and the bookkeeping (where
// the position and the orbit data came from). One object per visit of the screen; `run` is the
// screen's task and ends with it.
import Foundation
import MeshSatEngine
import MeshSatPlatform
import MeshSatSatellite
import MeshSatStore
import Observation

/// Elevation environment presets matching the Go web frontend.
public struct ElevPreset: Sendable, Equatable, Identifiable {
    public let value: Int
    public let label: String
    public let desc: String
    public var id: Int { value }
}

@Observable
@MainActor
public final class PassesModel {
    public static let elevPresets: [ElevPreset] = [
        ElevPreset(value: 5, label: "Open", desc: "Open field or rooftop"),
        ElevPreset(value: 20, label: "Trees", desc: "Some trees or low buildings"),
        ElevPreset(value: 40, label: "City", desc: "Tall buildings, narrow streets"),
        ElevPreset(value: 60, label: "Canyon", desc: "Deep valley or dense city"),
    ]
    // 72 h is gone: on a phone its passes are hairlines (MESHSAT-1300). 12 h is the default for the same reason.
    public static let windowOptions = [6, 12, 24, 48]

    public private(set) var passes: [PassPrediction] = []
    public private(set) var loading = false
    public private(set) var refreshing = false
    public private(set) var cacheAgeSec: Int64 = -1
    public private(set) var tleSource: TleSource = .none
    public var windowHours = 12 {
        didSet { if windowHours != oldValue { changed() } }
    }
    public var minElevDeg = 5 {
        didSet { if minElevDeg != oldValue { changed() } }
    }
    public private(set) var skySignals: [SkySignal] = []
    public private(set) var skySessions: [SkySession] = []
    public private(set) var errorMsg: String?
    public var expandedPassList = false
    public private(set) var lat = 0.0
    public private(set) var lon = 0.0
    public private(set) var hasLocation = false
    public private(set) var countdownText = ""
    public private(set) var nowSec: Int64 = Int64(Date().timeIntervalSince1970)

    private var gateway: GatewayController?
    private var computeTask: Task<Void, Never>?
    private var signalsTask: Task<Void, Never>?

    public init() {}

    public var nextPass: PassPrediction? { passes.first { Int64($0.aos.value) > nowSec } }
    public var activePass: PassPrediction? { passes.first { Int64($0.aos.value) <= nowSec && Int64($0.los.value) >= nowSec } }
    public var startSec: Int64 { nowSec - Int64(windowHours) * 3600 / 2 }
    public var endSec: Int64 { nowSec + Int64(windowHours) * 3600 / 2 }

    /// The screen's task: the position, the readings, the countdown. Ends when the task is cancelled.
    public func run(gateway: GatewayController) async {
        self.gateway = gateway
        signalsTask?.cancel()
        signalsTask = Task { [weak self] in await self?.pollSignals(gateway) }
        let fixes = gateway.location.phoneLocation.subscribe()
        let locationTask = Task { [weak self] in
            for await fix in fixes {
                guard let self, let fix else { continue }
                let first = !hasLocation
                lat = fix.latitude
                lon = fix.longitude
                hasLocation = true
                if first { computePasses() }
            }
        }
        defer {
            locationTask.cancel()
            signalsTask?.cancel()
            computeTask?.cancel()
        }
        // Countdown ticker (every second)
        while !Task.isCancelled {
            nowSec = Int64(Date().timeIntervalSince1970)
            if let next = nextPass {
                countdownText = Self.formatCountdown(Int64(next.aos.value) - nowSec)
            } else {
                countdownText = ""
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func changed() {
        signalsTask?.cancel()
        if let gateway {
            signalsTask = Task { [weak self] in await self?.pollSignals(gateway) }
        }
        if hasLocation { computePasses() }
    }

    // The past half of the window: what the modem actually heard, and its sessions.
    private func pollSignals(_ gateway: GatewayController) async {
        while !Task.isCancelled {
            let since = Int64(Date().timeIntervalSince1970 * 1000) - Int64(windowHours) * 3_600_000 / 2
            if let s = try? await gateway.db.signals.fetchSince(source: "iridium", since: since) {
                skySignals = s.map { SkySignal(atSec: $0.timestamp / 1000, bars: $0.value) }
            }
            if let s = try? await gateway.db.signals.fetchSince(source: "gss", since: since) {
                skySessions = s.map { SkySession(atSec: $0.timestamp / 1000, ok: $0.value >= 1) }
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    // Compute passes when location or params change
    public func computePasses() {
        guard hasLocation, let fetcher = gateway?.tleFetcher else { return }
        computeTask?.cancel()
        loading = true
        errorMsg = nil
        let lat = lat
        let lon = lon
        let windowHours = windowHours
        let minElev = Double(minElevDeg)
        computeTask = Task { [weak self] in
            // Offline first: the last download or the snapshot shipped in the app.
            let set = await fetcher.localTles()
            guard let self, !Task.isCancelled else { return }
            cacheAgeSec = Int64(set.ageSec())
            tleSource = set.source
            if set.tles.isEmpty {
                errorMsg = "No orbit data. Tap Refresh TLEs when online."
                loading = false
                return
            }
            let nowUnix = Int64(Date().timeIntervalSince1970)
            let start = UnixSeconds(Double(nowUnix - Int64(windowHours) * 3600 / 2))
            let end = UnixSeconds(Double(nowUnix + Int64(windowHours) * 3600 / 2))
            let tles = set.tles
            let computed = await Task.detached(priority: .userInitiated) {
                PassPredictor.predictAllPasses(
                    tles, observer: Observer(latDeg: lat, lonDeg: lon, altKm: 0), start: start, end: end, minElevDeg: minElev)
            }.value
            guard !Task.isCancelled else { return }
            passes = computed
            loading = false
        }
    }

    /// The Update button: a download, then the passes again. False when nothing new was downloaded.
    public func refresh() async -> Bool {
        guard let fetcher = gateway?.tleFetcher, !refreshing else { return true }
        refreshing = true
        let got = await fetcher.refreshFromNetwork()
        refreshing = false
        computePasses()
        return got != nil
    }

    public var tleSourceText: String {
        switch tleSource {
        case .none: "No data"
        case .downloaded: "downloaded, \(Self.formatCacheAge(cacheAgeSec))"
        case .bundled: "built-in, \(Self.formatCacheAge(cacheAgeSec))"
        }
    }

    static func formatCountdown(_ seconds: Int64) -> String {
        if seconds <= 0 { return "00:00" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func formatCacheAge(_ sec: Int64) -> String {
        if sec < 0 { return "No data" }
        if sec < 3600 { return "\(sec / 60)m old" }
        if sec < 86400 { return "\(sec / 3600)h old" }
        return "\(sec / 86400)d old"
    }

    static func formatDurationMin(_ min: Double) -> String {
        let m = Int(min.rounded())
        return m >= 60 ? "\(m / 60)h\(m % 60)m" : "\(m)m"
    }

    nonisolated static let utcTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated static let utcDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func formatTimeUtc(_ unix: Int64) -> String { utcTime.string(from: Date(timeIntervalSince1970: Double(unix))) }
    static func formatDateShort(_ unix: Int64) -> String { utcDate.string(from: Date(timeIntervalSince1970: Double(unix))) }
}
