// The phone's own figures for the Hub's health report (HubReporter.getBatteryLevel,
// getMemoryUsage, getDiskUsage on Android): battery from UIDevice, memory from the process
// info, disk from the file system, the model identifier from uname.
import Foundation
import MeshSatEngine

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

    /// "iOS 27.0", as Android reports Build.VERSION.RELEASE.
    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// The process's memory footprint, the figure Xcode's gauge shows (TelemetryLogger.recordHeap
    /// on Android samples the Dalvik and native heaps).
    static func heapSample() -> (message: String, detail: [String: TelemetryValue]) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var footprint: Int64 = 0
        var resident: Int64 = 0
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            footprint = Int64(info.phys_footprint)
            resident = Int64(info.resident_size)
        }
        #endif
        #if os(iOS)
        let available = Int64(os_proc_available_memory())
        #else
        let available: Int64 = 0
        #endif
        return (
            "Footprint \(footprint / 1_048_576)/\(total / 1_048_576) MB, \(available / 1_048_576) MB left for the app",
            [
                "physFootprint": .int(footprint), "residentSize": .int(resident), "physicalMemory": .int(total),
                "availableToApp": .int(available),
            ]
        )
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
