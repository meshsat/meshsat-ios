// What the gateway does around iOS's background limits (MESHSAT-1328). Android's
// GatewayService is a foreground service and simply keeps running; iOS gives the app the
// Bluetooth background mode while the node link is live, the significant-change location
// service (no location background mode since build 23, App Review guideline 2.5.4), and two
// scheduled windows (BGTaskScheduler) for the rest. Everything here is idempotent and short.
import Foundation
import MeshSatEngine
import MeshSatSatellite

extension GatewayController {
    /// The app left the screen: significant-change location takes over when Always is granted,
    /// and the telemetry records the transition.
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
            if await driver.state == .connected {
                sent += await disp.drainNow(channelId: "iridium_0", reason: "background sync")
            } else if imt.parked, imt.state == .ready {
                // The node's 9704 carries iridium_0 (MESHSAT-1631): its worker runs while parked.
                disp.startWorker("iridium_0")
                sent += await disp.drainNow(channelId: "iridium_0", reason: "background sync")
            }
        }
        if let fix = location.phoneLocation.value { await publishPositionToHub(fix) }
        // Orbit data only once a satellite modem is there (MESHSAT-1752): nothing goes online unasked.
        if central.iridiumPipe.value != nil, let fetcher = tleFetcher, await fetcher.isCacheStale() {
            _ = await fetcher.refreshFromNetwork()
        }
        telemetryLogger?.recordEvent(tag: "Background", message: "Hub sync window", detail: ["deliveries": .int(Int64(sent))])
        Self.log.info("Background sync: \(sent) deliveries drained")
        return true
    }

    /// Orbit data is downloaded only once a satellite modem is set up, as Android's
    /// startTleRefreshOnceModemSetUp (MESHSAT-1752, F-Droid's device test of 29 Oct 2026): until then
    /// the passes come from the stored or bundled copy, and only Update on the passes screen goes
    /// online. iOS stores no 9704 address (the 9704 is reached through the node), so the node's
    /// Iridium pipe is the one sign. Then the stored copy is checked every hour and refreshed when it
    /// is stale, at most every 12 hours.
    func startTleRefreshOnceModemSetUp(_ fetcher: TleFetcher) {
        keep(
            Task { [self] in
                if central.iridiumPipe.value == nil {
                    for await pipe in central.iridiumPipe.subscribe() where pipe != nil { break }
                }
                guard !Task.isCancelled else { return }
                Self.log.info("Satellite modem set up: orbit data is kept fresh from now on")
                var lastAttemptMs: Int64 = 0
                while !Task.isCancelled {
                    let now = clock.nowMs()
                    if now - lastAttemptMs >= Self.tleRefreshEveryMs, await fetcher.isCacheStale() {
                        lastAttemptMs = now
                        _ = await fetcher.refreshFromNetwork()
                    }
                    await clock.sleep(ms: 3_600_000)
                }
            })
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
        await writePassWindows()
    }
}
