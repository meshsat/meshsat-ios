// What the gateway does around iOS's background limits (MESHSAT-1328). Android's
// GatewayService is a foreground service and simply keeps running; iOS gives the app the
// Bluetooth and location background modes while their sessions are live, and two scheduled
// windows (BGTaskScheduler) for the rest. Everything here is idempotent and short.
import Foundation
import MeshSatEngine
import MeshSatSatellite

extension GatewayController {
    /// The app left the screen: the location session keeps the process alive when Always is
    /// granted, and the telemetry records the transition.
    public func enteredBackground() {
        location.beginBackgroundActivity()
        telemetryLogger?.recordEvent(tag: "GatewayController", message: "Entered background")
    }

    public func enteredForeground() {
        location.endBackgroundActivity()
        telemetryLogger?.recordEvent(tag: "GatewayController", message: "Entered foreground")
    }

    /// The hub sync window (BGProcessingTask net.meshsat.ios.hubsync): what waits for the Hub
    /// and the satellite goes, the position is reported, stale TLEs are refreshed. True when
    /// it ran to the end.
    public func backgroundSync() async -> Bool {
        var sent = 0
        if let disp = dispatcher {
            sent += await disp.drainNow(channelId: "hub_0", reason: "background sync")
            if await driver.state == .connected { sent += await disp.drainNow(channelId: "iridium_0", reason: "background sync") }
        }
        if let fix = location.phoneLocation.value { await publishPositionToHub(fix) }
        if let fetcher = tleFetcher, await fetcher.isCacheStale() { _ = await fetcher.refreshFromNetwork() }
        telemetryLogger?.recordEvent(tag: "Background", message: "Hub sync window", detail: ["deliveries": .int(Int64(sent))])
        Self.log.info("Background sync: \(sent) deliveries drained")
        return true
    }

    /// The refresh window (BGAppRefreshTask net.meshsat.ios.refresh): fresh pass predictions.
    public func backgroundRefresh() async -> Bool {
        await recomputePasses()
        telemetryLogger?.recordEvent(tag: "Background", message: "Refresh window", detail: ["passes": .int(Int64(passes.value.count))])
        return true
    }

    /// The pass predictions from the stored TLEs and the last fix: three hours back, six ahead.
    func recomputePasses() async {
        guard let loc = location.phoneLocation.value, let fetcher = tleFetcher else { return }
        let set = await fetcher.localTles()
        let nowSec = Double(clock.nowMs()) / 1000
        let observer = Observer(latDeg: loc.latitude, lonDeg: loc.longitude, altKm: loc.altitude / 1000)
        let all = PassPredictor.predictAllPasses(
            set.tles, observer: observer, start: UnixSeconds(nowSec - 3 * 3600), end: UnixSeconds(nowSec + 6 * 3600),
            now: UnixSeconds(nowSec))
        Self.log.info("Pass prediction: \(set.tles.count) TLEs (\(set.source)), \(all.count) passes")
        passCache.replace(all, atMs: clock.nowMs())
        passes.send(all)
    }
}
