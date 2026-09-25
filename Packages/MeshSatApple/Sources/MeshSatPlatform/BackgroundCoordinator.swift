// The UIKit side of the background work (MESHSAT-1328): BGTaskScheduler registration and
// scheduling for the two windows the Info.plist permits, and the app lifecycle hand-offs to
// the gateway. Owned by the app delegate; registration must happen before the app finishes
// launching, so it is called from didFinishLaunching.
import Foundation
import Logging

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

public final class BackgroundCoordinator: @unchecked Sendable {
    private static let log = Logger(label: "Background")
    /// Not before 15 minutes: the OS decides the actual moment.
    public static let hubSyncEarliestSec: TimeInterval = 15 * 60
    public static let refreshEarliestSec: TimeInterval = 30 * 60

    private let gateway: GatewayController
    private let lock = NSLock()
    private var work: [String: Task<Void, Never>] = [:]

    public init(gateway: GatewayController) { self.gateway = gateway }

    /// Once, from didFinishLaunching.
    public func registerTasks() {
        #if canImport(BackgroundTasks) && os(iOS)
        let scheduler = BGTaskScheduler.shared
        let syncOk = scheduler.register(forTaskWithIdentifier: MeshSatPlatform.hubSyncTaskIdentifier, using: nil) { [weak self] task in
            self?.run(task, name: MeshSatPlatform.hubSyncTaskIdentifier) { await $0.backgroundSync() }
        }
        let refreshOk = scheduler.register(forTaskWithIdentifier: MeshSatPlatform.refreshTaskIdentifier, using: nil) { [weak self] task in
            self?.run(task, name: MeshSatPlatform.refreshTaskIdentifier) { await $0.backgroundRefresh() }
        }
        Self.log.info("Background tasks registered: hubsync=\(syncOk) refresh=\(refreshOk)")
        #endif
    }

    /// Asks for both windows; iOS keeps one request per identifier, so this is safe to repeat.
    public func scheduleAll() {
        #if canImport(BackgroundTasks) && os(iOS)
        let sync = BGProcessingTaskRequest(identifier: MeshSatPlatform.hubSyncTaskIdentifier)
        sync.requiresNetworkConnectivity = true
        sync.requiresExternalPower = false
        sync.earliestBeginDate = Date(timeIntervalSinceNow: Self.hubSyncEarliestSec)
        let refresh = BGAppRefreshTaskRequest(identifier: MeshSatPlatform.refreshTaskIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshEarliestSec)
        do {
            try BGTaskScheduler.shared.submit(sync)
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            // Unavailable on the simulator and when Background App Refresh is off: fine.
            Self.log.info("Background task scheduling: \(error)")
        }
        #endif
    }

    public func appDidEnterBackground() {
        scheduleAll()
        gateway.enteredBackground()
    }

    public func appWillEnterForeground() {
        gateway.enteredForeground()
    }

    #if canImport(BackgroundTasks) && os(iOS)
    /// BGTask is not Sendable; the box carries it into the task that completes it.
    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        init(_ task: BGTask) { self.task = task }
    }

    private func run(_ task: BGTask, name: String, _ body: @escaping @Sendable (GatewayController) async -> Bool) {
        let gateway = self.gateway
        let box = TaskBox(task)
        let job = Task { [weak self] in
            let ok = await body(gateway)
            box.task.setTaskCompleted(success: ok)
            self?.scheduleAll()
        }
        lock.lock()
        work[name] = job
        lock.unlock()
        task.expirationHandler = { [weak self] in
            self?.cancel(name)
            box.task.setTaskCompleted(success: false)
        }
    }

    private func cancel(_ name: String) {
        lock.lock()
        let job = work.removeValue(forKey: name)
        lock.unlock()
        job?.cancel()
    }
    #endif
}
