// The phone's own figures for the Hub's health report (HubReporter.getBatteryLevel,
// getMemoryUsage, getDiskUsage on Android): battery from UIDevice, memory from the process
// info, disk from the file system, the model identifier from uname.
import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DeviceMetrics {
    static func batteryPct() -> Double {
        #if canImport(UIKit) && !os(watchOS)
        return MainActor.assumeIsolatedIfPossible {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            return level >= 0 ? Double(level) * 100 : 0
        }
        #else
        return 0
        #endif
    }

    static func memPct() -> Double {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        #if os(iOS)
        let available = Double(os_proc_available_memory())
        return max(0, min(100, (1 - available / total) * 100))
        #else
        return 0
        #endif
    }

    static func diskPct() -> Double {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let total = (attrs[.systemSize] as? NSNumber)?.doubleValue, let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue,
            total > 0
        else { return 0 }
        return (total - free) / total * 100
    }

    /// "iPhone15,2", as Android reports Build.MODEL.
    static func model() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return machine.isEmpty ? "iPhone" : machine
    }
}

extension MainActor {
    /// UIDevice is main-actor bound; the health loop is not. Run the read on the main actor
    /// when we are not already there, synchronously.
    static func assumeIsolatedIfPossible<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
